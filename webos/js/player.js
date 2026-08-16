/* Reproductor del televisor: precarga, reconexión y seguimiento del capítulo.
 *
 * Diferencia importante con la app de escritorio: un televisor LG tiene **un
 * solo pipeline de medios**. Abrir un segundo <video> para comprobar qué hay
 * al otro lado mataría el que se está viendo. Por eso, mientras se reproduce,
 * el vigilante solo hace sondeos baratos (¿responde el servidor?) y la
 * identidad del archivo se averigua con el propio elemento que ya está en uso,
 * al recargarlo.
 *
 * Funciona porque el servidor real se cae entre capítulos: medido con un
 * monitor, entre 8 y 28 segundos. Esa caída es la señal.
 *
 * Diferencias con la versión anterior:
 *
 *   1. Reconexión no destructiva: ante un micro-corte se intenta reanudar
 *      con play() sin destruir el búfer. Solo se recarga src si play() falla.
 *   2. Seek robusto: se verifica seekable, se usa debounce para toques
 *      rápidos del mando, y se da feedback visual inmediato.
 *   3. Precarga mejorada: el readyState es la señal principal, no
 *      bufferedAhead() que falla silenciosamente en algunos webOS.
 *   4. Pipeline hints: en webOS se piden más opciones de búfer al pipeline
 *      nativo de LG a través del atributo mediaOption. */
function FluxPlayer(video, handlers) {
  'use strict';

  var self = this;
  var candidate = null;
  var lastFingerprint = null;
  var resumeAt = 0;
  var attempt = 0;
  var generation = 0;

  var watchTimer = null;
  var stallTimer = null;
  var reconnectTimer = null;
  var misses = 0;
  var lost = false;
  var checking = false;
  var following = true;
  var preparing = false;
  var destroyed = false;
  var lastProgressAt = Date.now();

  /* --- Seek con debounce ------------------------------------------------- */

  var seekDebounceTimer = null;
  var seekPending = null;
  var seeking = false;

  function emit(name, payload) {
    if (destroyed) { return; }
    if (handlers[name]) { handlers[name](payload); }
  }

  /* --- Pipeline hints de webOS ------------------------------------------- */

  /* webOS permite pasar opciones al pipeline nativo de LG a través de un
   * atributo `mediaOption` en el elemento <video>. Se usa para pedir más
   * búfer del que el navegador da por defecto (~2-4 s).
   *
   * No todos los modelos lo soportan: si no funciona, el reproductor sigue
   * con los valores por defecto del pipeline. */
  function applyPipelineHints() {
    try {
      var opts = {
        option: {
          /* Pedir al pipeline nativo de webOS que mantenga un búfer más
           * grande. Los nombres de las opciones varían entre versiones de
           * webOS, así que se ponen varios para cubrir el rango. */
          bufferControl: {
            minBufferTime: 8,       /* segundos mínimos antes de reproducir */
            maxBufferTime: 30,      /* búfer máximo que acumula el pipeline */
            bufferMaxByte: 48 * 1024 * 1024  /* tope en bytes (~48 MB) */
          }
        },
        /* mediaTransportType: 'URI' es el default para HTTP, pero
         * explicitarlo previene que webOS elija un path subóptimo. */
        mediaTransportType: 'URI'
      };
      video.setAttribute('mediaOption', JSON.stringify(opts));
    } catch (e) {
      /* Modelo sin soporte: silencioso. */
    }
  }

  /* --- Carga con precarga ------------------------------------------------ */

  this.load = function (next, options) {
    if (destroyed) { return; }
    var opts = options || {};
    generation++;
    var mine = generation;

    candidate = next;
    attempt = 0;
    misses = 0;
    lost = false;
    preparing = true;
    seeking = false;
    seekPending = null;
    clearTimeout(seekDebounceTimer);
    resumeAt = opts.resumeAt || 0;
    lastProgressAt = Date.now();
    emit('onPreparing', { candidate: candidate, resuming: resumeAt > 0 });

    applyPipelineHints();
    video.autoplay = false;
    video.preload = 'auto';
    video.src = opts.bustCache
      ? candidate.url + '?flux=' + Date.now()
      : candidate.url;

    try {
      video.load();
    } catch (e) { /* algunos webOS antiguos no exponen load() */ }

    /* Techo de espera: más vale empezar con poco búfer que dejar la pantalla
     * en negro indefinidamente.
     *
     * La señal principal es readyState, no bufferedAhead(). En algunos webOS
     * la API buffered lanza excepciones o devuelve rangos vacíos hasta que el
     * pipeline se asienta, así que confiar en ella causaba esperas innecesarias
     * de 8 s. readyState >= 3 (HAVE_FUTURE_DATA) o >= 4 (HAVE_ENOUGH_DATA)
     * es fiable en todos los modelos. */
    var deadline = Date.now() + 8000;

    (function waitForBuffer() {
      if (destroyed || mine !== generation) { return; }
      if (ready() || Date.now() > deadline) {
        preparing = false;
        if (resumeAt > 0 && video.duration && resumeAt < video.duration) {
          safeSeek(resumeAt);
        }
        emit('onReady', candidate);
        play();
        return;
      }
      setTimeout(waitForBuffer, 200);
    }());
  };

  /* HAVE_FUTURE_DATA basta para arrancar. Se intenta también con
   * bufferedAhead como señal secundaria, pero si falla (como pasa en
   * webOS 4), readyState manda. */
  function ready() {
    if (video.readyState >= 4) { return true; }
    if (video.readyState >= 3) {
      /* Si bufferedAhead funciona y hay 4+ segundos, perfecto.
       * Si falla, readyState >= 3 ya es suficiente para empezar
       * sin tirones visibles. */
      var ahead = bufferedAhead();
      return ahead >= 4 || ahead === 0; /* 0 = la API no funciona, confiar en readyState */
    }
    return false;
  }

  function bufferedAhead() {
    try {
      if (!video.buffered || !video.buffered.length) { return 0; }
      var end = video.buffered.end(video.buffered.length - 1);
      return Math.max(0, end - video.currentTime);
    } catch (e) {
      return 0;
    }
  }
  this.bufferedAhead = bufferedAhead;

  function play() {
    try {
      var promise = video.play();
      if (promise && promise['catch']) {
        promise['catch'](function () { /* el usuario pulsará reproducir */ });
      }
    } catch (e) { /* ídem */ }
  }

  /* --- Control ----------------------------------------------------------- */

  this.playPause = function () {
    if (video.paused) { play(); } else { video.pause(); }
  };

  /* Seek robusto con debounce.
   *
   * En el mando, pulsar izquierda/derecha/arriba/abajo rápido genera ráfagas
   * de seekBy. Sin debounce, cada toque es un seek HTTP independiente que:
   * - cancela el búfer en curso
   * - fuerza una nueva petición Range al servidor
   * - en webOS puede bloquear el pipeline de medios
   *
   * Con debounce se acumulan las pulsaciones en 150 ms y se lanza un solo
   * seek al destino final. El feedback visual (posición en la barra) se
   * actualiza inmediatamente para que la UI responda al instante. */
  this.seekBy = function (seconds) {
    if (!video.duration || !isFinite(video.duration)) { return; }
    /* Calcular la posición de partida: si hay un seek pendiente, partir de
     * ahí; si no, de la posición actual del video. */
    var base = seekPending !== null ? seekPending : video.currentTime;
    var target = base + seconds;
    if (target < 0) { target = 0; }
    if (target > video.duration - 1) { target = video.duration - 1; }

    seekPending = target;
    lastProgressAt = Date.now();
    /* Feedback visual inmediato: mover la barra ya, antes de que el seek
     * realmente ocurra. */
    emit('onSeekPreview', target);

    clearTimeout(seekDebounceTimer);
    seekDebounceTimer = setTimeout(function () {
      var finalTarget = seekPending;
      seekPending = null;
      if (finalTarget !== null) {
        safeSeek(finalTarget);
      }
    }, 150);
  };

  this.seekTo = function (seconds) {
    seekPending = null;
    clearTimeout(seekDebounceTimer);
    safeSeek(seconds);
  };

  /* Seek seguro: verifica que el video sea seekable antes de saltar. En webOS
   * asignar currentTime a un video no seekable puede congelar el pipeline. */
  function safeSeek(seconds) {
    lastProgressAt = Date.now();

    /* Verificar seekable: el servidor anuncia Accept-Ranges: bytes, pero si
     * CORS lo oculta, el <video> no lo sabe y seekable puede estar vacío.
     * En ese caso se intenta de todas formas (try/catch). */
    try {
      if (video.seekable && video.seekable.length > 0) {
        /* Acotar al rango seekable real del pipeline. */
        var start = video.seekable.start(0);
        var end = video.seekable.end(video.seekable.length - 1);
        if (seconds < start) { seconds = start; }
        if (seconds > end) { seconds = end; }
      }
      seeking = true;
      video.currentTime = seconds;
    } catch (e) {
      seeking = false;
      /* El pipeline no admite salto todavía. */
    }
  }

  this.candidate = function () { return candidate; };
  this.isPreparing = function () { return preparing; };
  this.isFollowing = function () { return following; };

  this.setFollowing = function (value) {
    following = !!value;
    if (following) { startWatching(); } else { stopWatching(); }
  };

  /* --- Reconexión -------------------------------------------------------- */

  /* La diferencia clave con la versión anterior: antes, reconectar siempre
   * destruía el búfer (cambiando video.src). Ahora primero se intenta
   * reanudar con play() sobre el src existente. Solo si eso falla se hace
   * reload completo. Esto es lo más parecido al reconnect_streamed de
   * FFmpeg que se puede hacer con el <video> del navegador. */

  function scheduleReconnect() {
    if (destroyed || preparing) { return; }
    if (attempt >= FluxConfig.maxReconnectAttempts) {
      emit('onFatal', 'Se perdió la conexión con el servidor y no se pudo ' +
        'recuperar tras ' + attempt + ' intentos.');
      return;
    }
    attempt++;
    emit('onReconnecting', attempt);
    var delay = Math.min(FluxConfig.maxBackoffMs, 1000 * Math.pow(2, attempt - 1));
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(reconnectNow, delay);
  }

  function reconnectNow() {
    if (destroyed || !candidate) { return; }
    var saved = video.currentTime || resumeAt;

    /* Paso 1: intentar play() sin tocar el src. Si el pipeline de webOS
     * tiene datos en búfer y el servidor vuelve, esto es instantáneo y no
     * hay interrupción visible. */
    try {
      var promise = video.play();
      if (promise && promise.then) {
        promise.then(function () {
          /* play() funcionó: el pipeline tenía datos suficientes. */
          if (destroyed) { return; }
          lastProgressAt = Date.now();
          /* No resetear attempt aquí: se resetea en onTimeUpdate cuando
           * la posición realmente avanza. */
        })['catch'](function () {
          if (destroyed) { return; }
          /* play() falló: el pipeline está vacío o muerto. Reload. */
          fullReload(saved);
        });
        return;
      }
    } catch (e) {
      /* Sin promesas (webOS muy antiguo): ir directo al reload. */
    }
    fullReload(saved);
  }

  /* Reload completo: cambia src y recarga. Es el fallback cuando play()
   * no consigue reanudar. */
  function fullReload(savedPosition) {
    self.load(candidate, { resumeAt: savedPosition, bustCache: true });
  }

  this.retry = function () {
    attempt = 0;
    reconnectNow();
  };

  /* --- Vigilancia de la emisión ------------------------------------------ */

  function startWatching() {
    stopWatching();
    if (!following) { return; }
    watchTimer = setInterval(check, FluxConfig.watchInterval);
    stallTimer = setInterval(function () {
      if (destroyed || preparing || video.paused || video.ended) { return; }
      /* El stall timeout se toma de la config. Es menos agresivo que antes
       * porque la reconexión ya no es destructiva: un atasco corto se resuelve
       * con play() sin perder el búfer. */
      if (Date.now() - lastProgressAt > FluxConfig.stallTimeout) {
        emit('onStalled');
        check();
        scheduleReconnect();
      }
    }, 5000);
  }

  function stopWatching() {
    clearInterval(watchTimer);
    clearInterval(stallTimer);
    watchTimer = null;
    stallTimer = null;
  }

  function retune() {
    if (!following || destroyed) { return; }
    clearInterval(watchTimer);
    var interval = (misses > 0 || lost)
      ? FluxConfig.watchRecoveryInterval
      : FluxConfig.watchInterval;
    watchTimer = setInterval(check, interval);
  }

  /* Sondeo barato: solo pregunta si el servidor sigue en pie. Nunca abre un
   * segundo elemento de video. */
  function check() {
    if (destroyed || checking || !candidate || !following) { return; }
    checking = true;

    FluxNet.probeReachable(
      candidate.host,
      candidate.port,
      FluxConfig.probeTimeout,
      function (alive) {
        checking = false;
        if (destroyed) { return; }

        if (!alive) {
          misses++;
          if (misses >= FluxConfig.missesBeforeLost && !lost) {
            lost = true;
            emit('onLost');
          }
          retune();
          return;
        }

        misses = 0;
        if (lost) {
          lost = false;
          retune();
          // Volvió a haber servidor. Cuál sea el archivo lo dirá el propio
          // reproductor al recargar: si dura lo mismo es el capítulo de antes
          // y se reanuda; si dura otra cosa, has cambiado de capítulo.
          reloadAndIdentify();
        } else {
          retune();
        }
      }
    );
  }
  this.check = check;

  function reloadAndIdentify() {
    if (!candidate) { return; }
    var previous = lastFingerprint;
    var resume = video.currentTime || resumeAt;

    var mine = ++generation;
    preparing = true;
    seeking = false;
    seekPending = null;
    emit('onPreparing', { candidate: candidate, resuming: true });

    applyPipelineHints();
    video.preload = 'auto';
    video.src = candidate.url + '?flux=' + Date.now();
    try { video.load(); } catch (e) { /* ídem */ }

    var deadline = Date.now() + 12000;
    (function waitMeta() {
      if (destroyed || mine !== generation) { return; }
      if (video.readyState >= 1 && video.duration && isFinite(video.duration)) {
        var current = 'dur:' + video.duration.toFixed(3);
        var isSame = previous !== null && previous === current;
        lastFingerprint = current;
        preparing = false;
        attempt = 0;

        if (isSame) {
          if (resume > 0 && resume < video.duration) {
            safeSeek(resume);
          }
          emit('onRestored', candidate);
        } else {
          resumeAt = 0;
          candidate.duration = video.duration;
          candidate.fingerprint = current;
          emit('onChanged', candidate);
        }
        play();
        return;
      }
      if (Date.now() > deadline) {
        preparing = false;
        scheduleReconnect();
        return;
      }
      setTimeout(waitMeta, 200);
    }());
  }

  /* --- Eventos del elemento ---------------------------------------------- */

  function onMeta() {
    if (video.duration && isFinite(video.duration)) {
      var print = 'dur:' + video.duration.toFixed(3);
      if (lastFingerprint === null) { lastFingerprint = print; }
    }
    emit('onMeta', {
      duration: video.duration,
      width: video.videoWidth,
      height: video.videoHeight
    });
  }

  function onTimeUpdate() {
    lastProgressAt = Date.now();
    if (video.currentTime > 0) {
      resumeAt = video.currentTime;
      if (attempt > 0) { attempt = 0; }
    }
    emit('onTime', video.currentTime);
  }

  function onSeeked() {
    seeking = false;
    lastProgressAt = Date.now();
    emit('onTime', video.currentTime);
  }

  function onError() {
    if (destroyed) { return; }
    // Un error es la señal más rápida de que el emisor cambió de archivo:
    // se comprueba en el acto, sin esperar al siguiente ciclo.
    check();
    scheduleReconnect();
  }

  video.addEventListener('loadedmetadata', onMeta, false);
  video.addEventListener('timeupdate', onTimeUpdate, false);
  video.addEventListener('seeked', onSeeked, false);
  video.addEventListener('progress', function () { emit('onBuffer'); }, false);
  video.addEventListener('waiting', function () { emit('onWaiting'); }, false);
  video.addEventListener('playing', function () {
    lastProgressAt = Date.now();
    emit('onPlaying');
  }, false);
  video.addEventListener('pause', function () { emit('onPaused'); }, false);
  video.addEventListener('ended', function () {
    // Terminar también puede significar que el emisor pasó al siguiente.
    emit('onEnded');
    check();
  }, false);
  video.addEventListener('error', onError, false);

  this.start = function (initial) {
    lastFingerprint = initial.fingerprint &&
      initial.fingerprint.indexOf('dur:') === 0 ? initial.fingerprint : null;
    self.load(initial, {});
    startWatching();
  };

  this.destroy = function () {
    destroyed = true;
    stopWatching();
    clearTimeout(reconnectTimer);
    clearTimeout(seekDebounceTimer);
    seekPending = null;
    video.removeEventListener('loadedmetadata', onMeta, false);
    video.removeEventListener('timeupdate', onTimeUpdate, false);
    video.removeEventListener('seeked', onSeeked, false);
    video.removeEventListener('error', onError, false);
    try {
      video.pause();
      video.removeAttribute('src');
      video.load();
    } catch (e) { /* se descarta igualmente */ }
  };
}
