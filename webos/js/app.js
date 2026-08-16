/* Orquestación de la app en el televisor: vistas, mando y pegamento entre el
 * descubrimiento y el reproductor.
 *
 * Toda la navegación es por cruceta. No hay ratón que valga: el foco se lleva
 * a mano en dos zonas (resultados y botones) porque el orden natural del DOM
 * no coincide con lo que espera alguien apuntando con un mando. */
(function () {
  'use strict';

  var KEY = {
    ENTER: 13, LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40,
    BACK: 461, ESC: 27,
    PLAY: 415, PAUSE: 19, PLAYPAUSE: 10252, STOP: 413,
    FF: 417, RW: 412
  };

  var el = {};
  var view = 'search';
  var search = null;
  var player = null;
  var candidates = [];
  var autoPlayed = false;
  var controlsTimer = null;
  var bannerTimer = null;

  /* Zonas de foco de la vista de búsqueda. */
  var zone = 'actions';
  var cardIndex = 0;
  var actionIndex = 0;
  var manualIndex = 0;
  var errorIndex = 0;

  function byId(id) { return document.getElementById(id); }

  function init() {
    el.viewSearch = byId('view-search');
    el.viewManual = byId('view-manual');
    el.viewPlayer = byId('view-player');
    el.status = byId('search-status');
    el.bar = byId('search-bar');
    el.warning = byId('search-warning');
    el.results = byId('results');
    el.empty = byId('empty');
    el.btnSearch = byId('btn-search');
    el.btnManual = byId('btn-manual');
    el.manualInput = byId('manual-input');
    el.manualError = byId('manual-error');
    el.btnConnect = byId('btn-connect');
    el.btnManualBack = byId('btn-manual-back');
    el.video = byId('video');
    el.banner = byId('banner');
    el.prepare = byId('prepare');
    el.prepareTitle = byId('prepare-title');
    el.prepareNote = byId('prepare-note');
    el.controls = byId('controls');
    el.playerTitle = byId('player-title');
    el.playerAddress = byId('player-address');
    el.seekBuffer = byId('seek-buffer');
    el.seekPlayed = byId('seek-played');
    el.seekKnob = byId('seek-knob');
    el.timeNow = byId('time-now');
    el.timeTotal = byId('time-total');
    el.followHint = byId('follow-hint');
    el.playerError = byId('player-error');
    el.playerErrorText = byId('player-error-text');
    el.btnRetry = byId('btn-retry');
    el.btnPlayerBack = byId('btn-player-back');

    el.btnSearch.onclick = startSearch;
    el.btnManual.onclick = function () { showView('manual'); };
    el.btnConnect.onclick = connectManual;
    el.btnManualBack.onclick = function () { showView('search'); };
    el.btnRetry.onclick = function () { hideError(); if (player) { player.retry(); } };
    el.btnPlayerBack.onclick = leavePlayer;

    document.addEventListener('keydown', onKey, false);

    /* --- Ciclo de vida de webOS ------------------------------------------- */
    /* webOS mata las apps que llevan un rato sin interacción visible. Para
     * evitarlo hay que llamar a window.webOSSystem.keepAlive(true) y
     * mantener un heartbeat. Además, al pasar a segundo plano (el usuario
     * abre otra app o el Launcher), se pausa el video para liberar el
     * pipeline de medios; al volver, se reanuda. */
    setupLifecycle();

    startSearch();
  }

  /* --- Lifecycle de webOS ----------------------------------------------- */

  var keepAliveTimer = null;
  var screenSaverDisabled = false;

  function setupLifecycle() {
    /* keepAlive impide que webOS cierre la app tras ~15 minutos de
     * inactividad. Requiere "keepAlive": true en appinfo.json para
     * que tenga efecto — sin esa línea en el manifiesto, esta llamada
     * no hace nada y el sistema mata la app igual. */
    requestKeepAlive(true);

    /* Heartbeat: cada 4 minutos se vuelve a pedir keepAlive. Algunos
     * firmwares lo revocan pasado un rato y esto lo renueva. */
    keepAliveTimer = setInterval(function () {
      requestKeepAlive(true);
    }, 240000);

    /* Visibilidad: webOS lanza el evento estándar de visibilidad cuando la
     * app pasa a background (usuario abre el Launcher, otra app, etc.). */
    document.addEventListener('visibilitychange', onVisibilityChange, false);
    document.addEventListener('webOSRelaunch', onRelaunch, false);
  }

  function requestKeepAlive(value) {
    /* webOS 3+ expone window.webOSSystem */
    if (window.webOSSystem && typeof webOSSystem.keepAlive === 'function') {
      try { webOSSystem.keepAlive(value); } catch (e) { /* modelo sin soporte */ }
    }
    /* PalmSystem es el nombre legacy (webOS 1-3). */
    if (window.PalmSystem && typeof PalmSystem.keepAlive === 'function') {
      try { PalmSystem.keepAlive(value); } catch (e) { /* ídem */ }
    }
  }

  /* --- Screensaver / Power Management ---------------------------------- */

  /* webOS apaga la pantalla tras un rato sin input del mando (no del video,
   * del mando). Esto es lo que hace que "se apague la tele" mientras estás
   * viendo algo: el TV no detecta actividad del usuario y activa el
   * screensaver → suspensión → apagado.
   *
   * Para evitarlo hay que llamar al servicio Luna de power management y
   * deshabilitar el screensaver mientras se reproduce video. Es lo mismo que
   * hacen Netflix, YouTube y cualquier app de streaming de la LG Store.
   *
   * Se rehabilita al salir del reproductor para no mantener la pantalla
   * encendida indefinidamente si el usuario deja la app en búsqueda. */

  function setScreenSaver(enabled) {
    if (!window.PalmServiceBridge) { return; }
    screenSaverDisabled = !enabled;

    var bridge;
    try { bridge = new window.PalmServiceBridge(); } catch (e) { return; }

    bridge.onservicecallback = function () { /* respuesta ignorada */ };

    /* Método principal: TVPower → setScreenState. Funciona en webOS 3+. */
    try {
      if (!enabled) {
        /* Pedir que la pantalla se quede activa. */
        bridge.call(
          'luna://com.webos.service.tvpower/power/turnOnScreenSaver',
          JSON.stringify({ block: true })
        );
      } else {
        bridge.call(
          'luna://com.webos.service.tvpower/power/turnOnScreenSaver',
          JSON.stringify({ block: false })
        );
      }
    } catch (e) { /* servicio no disponible en este modelo */ }

    /* Método alternativo para modelos más nuevos (webOS 6+):
     * com.webos.service.power2 */
    try {
      var bridge2 = new window.PalmServiceBridge();
      bridge2.onservicecallback = function () {};
      bridge2.call(
        'luna://com.webos.service.power2/display/setState',
        JSON.stringify({
          state: enabled ? 'ActiveStandby' : 'Active',
          reason: 'com.alessandro.flux'
        })
      );
    } catch (e2) { /* ídem */ }
  }

  /* Inyectar actividad artificial del usuario. Algunos modelos ignoran el
   * bloqueo de screensaver pero respetan la actividad del usuario. Un
   * "toque fantasma" cada 3 minutos es la red de seguridad. */
  var activityTimer = null;

  function startActivityHeartbeat() {
    stopActivityHeartbeat();
    activityTimer = setInterval(function () {
      if (!window.PalmServiceBridge) { return; }
      try {
        var bridge = new window.PalmServiceBridge();
        bridge.onservicecallback = function () {};
        /* Reportar actividad de media: evita que el power manager considere
         * que el TV está idle. */
        bridge.call(
          'luna://com.webos.service.tvpower/power/turnOnScreen',
          JSON.stringify({ reason: 'remoteKey' })
        );
      } catch (e) { /* silencioso */ }
    }, 180000); /* cada 3 minutos */
  }

  function stopActivityHeartbeat() {
    if (activityTimer) { clearInterval(activityTimer); activityTimer = null; }
  }

  var wasPlayingBeforeHide = false;

  function onVisibilityChange() {
    if (document.hidden) {
      /* La app pasó a background. Se pausa el video para liberar el
       * pipeline de medios del televisor — si no se hace, algunos modelos
       * cierran la app a la fuerza. */
      if (el.video && !el.video.paused) {
        wasPlayingBeforeHide = true;
        try { el.video.pause(); } catch (e) { /* sin video activo */ }
      } else {
        wasPlayingBeforeHide = false;
      }
      /* Rehabilitar screensaver: la app no está visible. */
      setScreenSaver(true);
      stopActivityHeartbeat();
    } else {
      /* La app volvió a primer plano. Se reanuda si estaba reproduciendo. */
      requestKeepAlive(true);
      if (wasPlayingBeforeHide && el.video) {
        setScreenSaver(false);
        startActivityHeartbeat();
        try { el.video.play(); } catch (e) { /* el usuario reanudará */ }
        wasPlayingBeforeHide = false;
      }
    }
  }

  function onRelaunch() {
    /* webOSRelaunch se dispara cuando el usuario vuelve a abrir la app
     * desde el Launcher sin que se haya cerrado. Se renueva keepAlive y
     * se asegura la vista correcta. */
    requestKeepAlive(true);
  }

  /* --- Vistas ------------------------------------------------------------ */

  function showView(name) {
    view = name;
    el.viewSearch.className = 'view' + (name === 'search' ? ' is-active' : '');
    el.viewManual.className = 'view' + (name === 'manual' ? ' is-active' : '');
    el.viewPlayer.className = 'view view-player' + (name === 'player' ? ' is-active' : '');

    if (name === 'search') {
      zone = candidates.length ? 'results' : 'actions';
      applyFocus();
    } else if (name === 'manual') {
      manualIndex = 0;
      el.manualError.innerHTML = '';
      applyFocus();
    }
  }

  /* --- Búsqueda ---------------------------------------------------------- */

  function startSearch() {
    if (search) { search.cancel(); }
    candidates = [];
    cardIndex = 0;
    el.results.innerHTML = '';
    el.empty.className = 'empty';
    el.warning.innerHTML = '';
    setProgress(0, 0);
    setStatus('Detectando la red del televisor…');
    showView('search');

    search = FluxDiscovery.search({
      onPhase: function (name, detail) {
        var labels = {
          conocidos: 'Probando servidores conocidos…',
          rapido: 'Buscando en la red…',
          amplio: 'Buscando en otros puertos…',
          validando: 'Comprobando qué es cada uno…'
        };
        setStatus((labels[name] || name) + (detail ? '  ·  ' + detail : ''));
        setProgress(0, 0);
      },
      onProgress: setProgress,
      onFound: function (candidate) {
        candidates.push(candidate);
        renderCards();
        if (!autoPlayed) {
          autoPlayed = true;
          // Igual que en la app de escritorio: se abre solo el primero que
          // aparece, una única vez por arranque. Después, manda el usuario.
          setTimeout(function () {
            if (view === 'search') { openPlayer(candidate); }
          }, 700);
        }
      },
      onWarning: function (message) { el.warning.innerHTML = escape(message); },
      onDone: function (total) {
        setStatus(total > 0
          ? 'Búsqueda completada  ·  ' + total + (total === 1 ? ' emisión' : ' emisiones')
          : 'No se encontró ninguna emisión');
        setProgress(1, 1);
        el.empty.className = 'empty' + (total === 0 ? ' is-visible' : '');
        if (total === 0) { zone = 'actions'; applyFocus(); }
      }
    });
  }

  function setStatus(text) { el.status.innerHTML = escape(text); }

  function setProgress(done, total) {
    var pct = total > 0 ? Math.round((done / total) * 100) : 0;
    el.bar.style.width = pct + '%';
  }

  function renderCards() {
    el.results.innerHTML = '';
    for (var i = 0; i < candidates.length; i++) {
      el.results.appendChild(buildCard(candidates[i], i));
    }
    if (zone !== 'results') { zone = 'results'; }
    applyFocus();
  }

  function buildCard(candidate, index) {
    var card = document.createElement('div');
    card.className = 'card';
    card.tabIndex = -1;
    card.setAttribute('data-index', index);

    var tags = '';
    if (candidate.duration) {
      tags += '<span class="tag">' + formatTime(candidate.duration) + '</span>';
    }
    if (candidate.size) {
      tags += '<span class="tag">' + formatSize(candidate.size) + '</span>';
    }
    if (candidate.width) {
      tags += '<span class="tag">' + candidate.width + '×' + candidate.height + '</span>';
    }
    tags += candidate.seekable
      ? '<span class="tag">Con avance</span>'
      : '<span class="tag tag-warn">Sin avance</span>';
    if (candidate.source === 'conocido') {
      tags += '<span class="tag">Conocido</span>';
    }

    card.innerHTML =
      '<p class="card-title">' + escape(candidate.title) + '</p>' +
      '<p class="card-meta">' + escape(candidate.address) + '</p>' +
      '<p class="card-tags">' + tags + '</p>';

    card.onclick = function () { openPlayer(candidate); };
    return card;
  }

  /* --- Dirección a mano --------------------------------------------------- */

  function connectManual() {
    var parsed = FluxDiscovery.parseAddress(el.manualInput.value);
    if (!parsed) {
      el.manualError.innerHTML =
        'Dirección no válida. Usa una IP de tu red local, por ejemplo 192.168.1.5:4445';
      return;
    }
    el.manualError.innerHTML = 'Comprobando…';
    FluxNet.inspect(parsed.host, parsed.port, function (raw) {
      if (!raw) {
        el.manualError.innerHTML =
          'No hay ningún video en ' + parsed.host + ':' + parsed.port +
          '. Comprueba que la transmisión esté activa.';
        return;
      }
      el.manualError.innerHTML = '';
      openPlayer(FluxDiscovery.candidateFrom(raw, 'manual'));
    });
  }

  /* --- Reproductor -------------------------------------------------------- */

  function openPlayer(candidate) {
    /* Se corta la búsqueda antes de arrancar el video.
     *
     * El barrido enseña lo que encuentra sin esperar a terminar, así que al
     * abrir el reproductor puede seguir habiendo decenas de sondeos en vuelo
     * contra el resto de la red. En un PC no se nota; en un televisor esos
     * sockets compiten con el pipeline de medios justo en el momento más
     * delicado, el arranque de la reproducción. */
    if (search) { search.cancel(); search = null; }

    FluxDiscovery.remember(candidate.host, candidate.port);
    showView('player');
    hideError();
    el.playerTitle.innerHTML = escape(candidate.title);
    el.playerAddress.innerHTML = escape(candidate.address);
    showControls();

    /* Deshabilitar el screensaver y reportar actividad mientras se reproduce
     * para evitar que el televisor se suspenda y apague. */
    setScreenSaver(false);
    startActivityHeartbeat();

    if (player) { player.destroy(); }
    player = new FluxPlayer(el.video, {
      onPreparing: function (info) {
        el.prepareTitle.innerHTML = escape(info.candidate.title);
        el.prepareNote.innerHTML = info.resuming
          ? 'Recuperando donde ibas…'
          : 'Precargando…';
        el.prepare.className = 'prepare is-visible';
      },
      onReady: function () { el.prepare.className = 'prepare'; },
      onMeta: function (info) {
        el.timeTotal.innerHTML = formatTime(info.duration);
        // Sin cabeceras, la resolución es lo único que identifica lo que estás
        // viendo, y hasta que no cargan los metadatos no se conoce.
        if (player && player.candidate() && !player.candidate().fileName && info.width) {
          el.playerTitle.innerHTML = escape('Emisión ' + info.width + '×' + info.height);
        }
      },
      onTime: updateSeek,
      onBuffer: updateSeek,
      /* Feedback visual inmediato al hacer seek con debounce: la barra de
       * progreso y el tiempo se actualizan ya, sin esperar a que el pipeline
       * realmente salte. El usuario ve la respuesta al instante aunque el
       * seek tarde 200-500 ms en ejecutarse. */
      onSeekPreview: function (targetSeconds) {
        var duration = el.video.duration;
        if (!duration || !isFinite(duration)) { return; }
        var pct = (targetSeconds / duration) * 100;
        el.seekPlayed.style.width = pct + '%';
        el.seekKnob.style.left = pct + '%';
        el.timeNow.innerHTML = formatTime(targetSeconds);
      },
      onPlaying: function () { hideError(); },
      onWaiting: function () { /* el propio televisor muestra su indicador */ },
      onReconnecting: function (attempt) {
        showBanner('Se cortó la emisión. Reintentando (' + attempt + ')…', true);
      },
      onLost: function () {
        showBanner('La emisión se detuvo. Esperando al capítulo siguiente…', true);
      },
      onRestored: function () { showBanner('Emisión recuperada'); },
      onChanged: function (candidate2) {
        el.playerTitle.innerHTML = escape(candidate2.title);
        el.playerAddress.innerHTML = escape(candidate2.address);
        showBanner('Capítulo nuevo detectado');
        showControls();
      },
      onStalled: function () { showBanner('La imagen se quedó parada. Recuperando…', true); },
      onEnded: function () { showBanner('Terminó. Esperando a lo siguiente…'); },
      onFatal: function (message) { showError(message); }
    });
    player.start(candidate);
    updateFollowHint();
  }

  function leavePlayer() {
    if (player) { player.destroy(); player = null; }
    hideError();
    el.prepare.className = 'prepare';
    hideBanner();

    /* Rehabilitar el screensaver al salir: si el usuario deja la app en
     * la pantalla de búsqueda y se va, el televisor debe poder suspenderse. */
    setScreenSaver(true);
    stopActivityHeartbeat();

    showView('search');
  }

  function updateSeek() {
    var duration = el.video.duration;
    if (!duration || !isFinite(duration)) { return; }
    var played = el.video.currentTime / duration;
    el.seekPlayed.style.width = (played * 100) + '%';
    el.seekKnob.style.left = (played * 100) + '%';
    el.timeNow.innerHTML = formatTime(el.video.currentTime);
    try {
      if (el.video.buffered && el.video.buffered.length) {
        var end = el.video.buffered.end(el.video.buffered.length - 1);
        el.seekBuffer.style.width = ((end / duration) * 100) + '%';
      }
    } catch (e) { /* algunos televisores no exponen buffered al principio */ }
  }

  function showControls() {
    el.controls.className = 'controls is-visible';
    clearTimeout(controlsTimer);
    controlsTimer = setTimeout(function () {
      if (!el.video.paused) { el.controls.className = 'controls'; }
    }, 4000);
  }

  function toggleControls() {
    if (el.controls.className.indexOf('is-visible') >= 0) {
      el.controls.className = 'controls';
    } else {
      showControls();
    }
  }

  function updateFollowHint() {
    el.followHint.innerHTML = (player && player.isFollowing())
      ? 'seguimiento activo'
      : 'seguimiento apagado';
  }

  function showBanner(message, warning) {
    el.banner.innerHTML = escape(message);
    el.banner.className = 'banner is-visible' + (warning ? ' is-warning' : '');
    clearTimeout(bannerTimer);
    if (warning) { return; }
    bannerTimer = setTimeout(hideBanner, 4000);
  }

  function hideBanner() { el.banner.className = 'banner'; }

  function showError(message) {
    el.prepare.className = 'prepare';
    el.playerErrorText.innerHTML = escape(message);
    el.playerError.className = 'player-error is-visible';
    errorIndex = 0;
    applyFocus();
  }

  function hideError() { el.playerError.className = 'player-error'; }

  function errorVisible() {
    return el.playerError.className.indexOf('is-visible') >= 0;
  }

  /* --- Mando -------------------------------------------------------------- */

  function onKey(event) {
    var code = event.keyCode;
    if (view === 'player') { onPlayerKey(code, event); return; }
    if (view === 'manual') { onManualKey(code, event); return; }
    onSearchKey(code, event);
  }

  function onSearchKey(code, event) {
    if (code === KEY.LEFT || code === KEY.RIGHT) {
      var step = code === KEY.RIGHT ? 1 : -1;
      if (zone === 'results') {
        cardIndex = clamp(cardIndex + step, 0, candidates.length - 1);
      } else {
        actionIndex = clamp(actionIndex + step, 0, 1);
      }
      applyFocus();
      event.preventDefault();
    } else if (code === KEY.UP || code === KEY.DOWN) {
      if (candidates.length) {
        zone = code === KEY.UP ? 'results' : 'actions';
        applyFocus();
      }
      event.preventDefault();
    } else if (code === KEY.ENTER) {
      if (zone === 'results' && candidates[cardIndex]) {
        openPlayer(candidates[cardIndex]);
      } else if (actionIndex === 0) {
        startSearch();
      } else {
        showView('manual');
      }
      event.preventDefault();
    } else if (code === KEY.BACK || code === KEY.ESC) {
      // En la pantalla inicial, ATRÁS cierra la app: es lo que espera
      // cualquiera que use un televisor.
      if (window.webOS && window.webOS.platformBack) {
        window.webOS.platformBack();
      } else {
        window.close();
      }
    }
  }

  function onManualKey(code, event) {
    if (code === KEY.BACK || code === KEY.ESC) {
      showView('search');
      event.preventDefault();
      return;
    }
    if (code === KEY.ENTER && manualIndex === 0) {
      // Con el foco en el campo, OK abre el teclado del televisor; solo
      // interceptamos si ya hay algo escrito.
      if (el.manualInput.value) { connectManual(); event.preventDefault(); }
      return;
    }
    if (code === KEY.UP || code === KEY.DOWN) {
      manualIndex = clamp(manualIndex + (code === KEY.DOWN ? 1 : -1), 0, 2);
      applyFocus();
      event.preventDefault();
    } else if (code === KEY.LEFT || code === KEY.RIGHT) {
      if (manualIndex > 0) {
        manualIndex = clamp(manualIndex + (code === KEY.RIGHT ? 1 : -1), 1, 2);
        applyFocus();
        event.preventDefault();
      }
    } else if (code === KEY.ENTER) {
      if (manualIndex === 1) { connectManual(); } else { showView('search'); }
      event.preventDefault();
    }
  }

  function onPlayerKey(code, event) {
    if (errorVisible()) {
      if (code === KEY.LEFT || code === KEY.RIGHT) {
        errorIndex = clamp(errorIndex + (code === KEY.RIGHT ? 1 : -1), 0, 1);
        applyFocus();
      } else if (code === KEY.ENTER) {
        if (errorIndex === 0) { hideError(); if (player) { player.retry(); } }
        else { leavePlayer(); }
      } else if (code === KEY.BACK || code === KEY.ESC) {
        leavePlayer();
      }
      event.preventDefault();
      return;
    }

    switch (code) {
      case KEY.ENTER:
      case KEY.PLAYPAUSE:
        if (player) { player.playPause(); }
        showControls();
        break;
      case KEY.PLAY:
        el.video.play();
        showControls();
        break;
      case KEY.PAUSE:
        el.video.pause();
        showControls();
        break;
      case KEY.LEFT:
      case KEY.RW:
        if (player) { player.seekBy(-FluxConfig.seekStepSeconds); }
        showControls();
        break;
      case KEY.RIGHT:
      case KEY.FF:
        if (player) { player.seekBy(FluxConfig.seekStepSeconds); }
        showControls();
        break;
      case KEY.UP:
        if (player) { player.seekBy(FluxConfig.bigSeekStepSeconds); }
        showControls();
        break;
      case KEY.DOWN:
        if (player) { player.seekBy(-FluxConfig.bigSeekStepSeconds); }
        showControls();
        break;
      case KEY.STOP:
      case KEY.BACK:
      case KEY.ESC:
        leavePlayer();
        break;
      default:
        toggleControls();
        return;
    }
    event.preventDefault();
  }

  /* Lleva el foco real del navegador donde toca. Se usa focus() de verdad y no
   * solo una clase CSS para que el puntero del mando mágico y la cruceta no se
   * contradigan. */
  function applyFocus() {
    var target = null;
    if (view === 'search') {
      if (zone === 'results' && candidates.length) {
        target = el.results.childNodes[clamp(cardIndex, 0, candidates.length - 1)];
      } else {
        target = actionIndex === 0 ? el.btnSearch : el.btnManual;
      }
    } else if (view === 'manual') {
      target = [el.manualInput, el.btnConnect, el.btnManualBack][manualIndex];
    } else if (view === 'player' && errorVisible()) {
      target = errorIndex === 0 ? el.btnRetry : el.btnPlayerBack;
    }
    if (target && target.focus) {
      try { target.focus(); } catch (e) { /* elemento recién creado */ }
    }
  }

  /* --- Utilidades --------------------------------------------------------- */

  function clamp(value, min, max) {
    if (value < min) { return min; }
    if (value > max) { return max; }
    return value;
  }

  function formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) { return '--:--'; }
    var total = Math.floor(seconds);
    var hours = Math.floor(total / 3600);
    var minutes = Math.floor((total % 3600) / 60);
    var secs = total % 60;
    var mm = (minutes < 10 ? '0' : '') + minutes;
    var ss = (secs < 10 ? '0' : '') + secs;
    return hours > 0 ? hours + ':' + mm + ':' + ss : mm + ':' + ss;
  }

  function formatSize(bytes) {
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
    return (unit === 0 ? size : size.toFixed(1)) + ' ' + units[unit];
  }

  /* El nombre del archivo llega de un servidor de la red: se escapa siempre
   * antes de meterlo en el DOM. */
  function escape(text) {
    return String(text === null || text === undefined ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  if (document.readyState === 'complete' || document.readyState === 'interactive') {
    setTimeout(init, 0);
  } else {
    document.addEventListener('DOMContentLoaded', init, false);
  }
}());
