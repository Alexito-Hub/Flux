/* Capa de red del televisor.
 *
 * En un navegador no hay sockets crudos, así que el escáner tipo nmap de la
 * app de escritorio no se puede portar. Y el servidor de Movie Plus no manda
 * `Access-Control-Allow-Origin`, con lo que tampoco se pueden leer sus
 * cabeceras por la vía normal.
 *
 * De ahí que el sondeo tenga tres niveles, de más informativo a más tozudo:
 *
 *   1. HEAD leyendo cabeceras — da nombre, tamaño y fecha. Solo funciona si el
 *      runtime del televisor no aplica CORS a las apps empaquetadas. Se
 *      comprueba en caliente en vez de darlo por supuesto.
 *   2. fetch en modo `no-cors` — la respuesta viene opaca y no se puede leer,
 *      pero *que resuelva* ya prueba que algo contestó por HTTP. Sirve para
 *      barrer puertos.
 *   3. Un <video> oculto — reproducir no está sujeto a CORS. Si dispara
 *      `loadedmetadata`, ahí hay un video de verdad; y su duración exacta
 *      sirve de huella para saber si el capítulo ha cambiado.
 */
var FluxNet = (function () {
  'use strict';

  var hasFetch = typeof window.fetch === 'function';
  var hasAbort = typeof window.AbortController === 'function';

  /* Se descubre una vez, con el primer servidor que responda, y a partir de
   * ahí se sabe si podemos permitirnos el nivel 1. */
  var corsAllowed = null;

  /* Sondeos en vuelo. Cancelar el barrido solo deja de lanzar peticiones
   * nuevas; las que ya salieron seguirían ocupando socket hasta agotar su
   * plazo. En un televisor eso importa: cuando se abre el reproductor hay que
   * dejarle el ancho de banda y las conexiones libres al pipeline de medios. */
  var inFlight = [];

  function track(controller) {
    if (controller) { inFlight.push(controller); }
  }

  function untrack(controller) {
    if (!controller) { return; }
    var i = inFlight.indexOf(controller);
    if (i >= 0) { inFlight.splice(i, 1); }
  }

  /* Sondeos de nivel 3 en curso, cada uno con su propio <video>. Se guardan
   * sus funciones de cierre para poder soltar el pipeline de medios al vuelo. */
  var probesInFlight = [];

  function trackProbe(finish) { probesInFlight.push(finish); }

  function untrackProbe(finish) {
    var i = probesInFlight.indexOf(finish);
    if (i >= 0) { probesInFlight.splice(i, 1); }
  }

  function abortAll() {
    var pending = inFlight;
    inFlight = [];
    for (var i = 0; i < pending.length; i++) {
      try { pending[i].abort(); } catch (e) { /* ya terminada */ }
    }
    var probes = probesInFlight.slice();
    for (var j = 0; j < probes.length; j++) {
      try { probes[j](null); } catch (e) { /* ya terminado */ }
    }
  }

  function url(host, port) {
    return 'http://' + host + ':' + port + '/';
  }

  /* --- Nivel 1: cabeceras completas ------------------------------------- */

  function probeMeta(host, port, timeout, cb) {
    var request = new XMLHttpRequest();
    var done = false;

    function finish(result) {
      if (done) { return; }
      done = true;
      cb(result);
    }

    try {
      request.open('HEAD', url(host, port), true);
    } catch (e) {
      finish(null);
      return;
    }
    request.timeout = timeout;
    request.onload = function () {
      if (request.status !== 200 && request.status !== 206) {
        finish(null);
        return;
      }
      var type = (request.getResponseHeader('Content-Type') || '').toLowerCase();
      var disposition = request.getResponseHeader('Content-Disposition');
      // Si las cabeceras vienen vacías es que CORS sí se aplica: hubo
      // respuesta pero el navegador nos la ha tapado.
      if (!type && !disposition) {
        corsAllowed = false;
        finish(null);
        return;
      }
      corsAllowed = true;
      finish({
        host: host,
        port: port,
        url: url(host, port),
        fileName: fileNameFrom(disposition),
        contentType: type,
        size: parseInt(request.getResponseHeader('Content-Length'), 10) || null,
        lastModified: request.getResponseHeader('Last-Modified') || null,
        seekable: (request.getResponseHeader('Accept-Ranges') || '')
          .toLowerCase().indexOf('bytes') >= 0,
        source: 'headers'
      });
    };
    request.onerror = function () { finish(null); };
    request.ontimeout = function () { finish(null); };
    try {
      request.send();
    } catch (e2) {
      finish(null);
    }
  }

  /* Mismo formato que en la app de escritorio: `inline; filename="X.mkv"` y
   * también el `filename*=UTF-8''...` de RFC 5987. */
  function fileNameFrom(disposition) {
    if (!disposition) { return null; }
    var extended = /filename\*\s*=\s*[^']*'[^']*'([^;]+)/i.exec(disposition);
    if (extended) {
      try { return decodeURIComponent(trim(extended[1])); } catch (e) { /* sigue */ }
    }
    var simple = /filename\s*=\s*"?([^";]+)"?/i.exec(disposition);
    if (!simple) { return null; }
    var name = trim(simple[1]);
    return name.length ? name : null;
  }

  function trim(text) {
    return String(text).replace(/^\s+|\s+$/g, '');
  }

  /* --- Nivel 2: ¿hay alguien ahí? --------------------------------------- */

  function probeReachable(host, port, timeout, cb) {
    if (!hasFetch) {
      // webOS 3 no tiene fetch y XHR no distingue "bloqueado por CORS" de
      // "no hay nadie": ambos llegan como error con status 0. Sin esa
      // distinción no se puede barrer, así que en ese caso el barrido no está
      // disponible y solo queda la dirección manual.
      cb(false);
      return;
    }

    var done = false;
    var controller = hasAbort ? new AbortController() : null;

    /* HEAD, no GET.
     *
     * Esto costó que la app se cerrara sola en el televisor. Con GET, la
     * respuesta llega opaca y no se puede leer... pero el navegador **sí** se
     * descarga el cuerpo. Y el cuerpo aquí es la película entera. Medido
     * contra un servidor de prueba: un solo sondeo que decía "listo" en 17 ms
     * se dejaba 59,3 MB en memoria por detrás. El vigilante sondea cada cinco
     * segundos mientras reproduces, así que en un minuto son unos 700 MB. Un
     * PC lo aguanta y por eso no se vio en las pruebas de escritorio; un
     * televisor no, y webOS mata la app.
     *
     * HEAD no trae cuerpo, así que no hay nada que descargar. El servidor de
     * Movie Plus lo admite: se comprobó al principio de todo, responde 200 con
     * las cabeceras completas. Y si algún servidor contestara 405, la
     * respuesta opaca resuelve igual, que es lo único que necesitamos saber
     * aquí: que hay alguien al otro lado. */
    var options = { method: 'HEAD', mode: 'no-cors', cache: 'no-store' };
    if (controller) { options.signal = controller.signal; }

    track(controller);

    function stop() {
      untrack(controller);
      if (!controller) { return; }
      try { controller.abort(); } catch (e) { /* da igual */ }
    }

    var timer = setTimeout(function () {
      if (done) { return; }
      done = true;
      stop();
      cb(false);
    }, timeout);

    window.fetch(url(host, port), options).then(function () {
      if (done) { return; }
      done = true;
      clearTimeout(timer);
      // Cinturón y tirantes: aunque HEAD no deba traer cuerpo, se corta la
      // conexión igualmente en cuanto sabemos lo que queríamos saber.
      stop();
      // Respuesta opaca: no se puede leer nada de ella, pero llegar hasta aquí
      // significa que alguien habló HTTP en ese puerto.
      cb(true);
    })['catch'](function () {
      if (done) { return; }
      done = true;
      clearTimeout(timer);
      untrack(controller);
      cb(false);
    });
  }

  /* --- Nivel 3: que lo diga el propio reproductor ----------------------- */

  function probeVideo(host, port, timeout, cb) {
    var video = document.createElement('video');
    var done = false;
    var timer;

    function finish(result) {
      if (done) { return; }
      done = true;
      clearTimeout(timer);
      untrackProbe(finish);
      video.onloadedmetadata = null;
      video.onerror = null;
      try {
        video.removeAttribute('src');
        video.load();
      } catch (e) { /* el elemento se descarta igualmente */ }
      // Fuera del DOM en cuanto termina, no cuando venza el plazo: en un
      // televisor con un único pipeline de medios, un <video> de sondeo que
      // sigue vivo le disputa el decodificador al que quiere reproducir.
      if (video.parentNode) { video.parentNode.removeChild(video); }
      cb(result);
    }

    trackProbe(finish);

    video.preload = 'metadata';
    video.muted = true;
    video.style.display = 'none';
    video.onloadedmetadata = function () {
      finish({
        host: host,
        port: port,
        url: url(host, port),
        fileName: null,
        contentType: null,
        size: null,
        lastModified: null,
        seekable: video.seekable && video.seekable.length > 0,
        // La duración exacta es la huella del contenido cuando CORS nos deja
        // sin cabeceras: dos capítulos distintos no duran lo mismo al
        // milisegundo.
        duration: video.duration,
        width: video.videoWidth,
        height: video.videoHeight,
        source: 'video'
      });
    };
    video.onerror = function () { finish(null); };

    timer = setTimeout(function () { finish(null); }, timeout);
    document.body.appendChild(video);
    video.src = url(host, port);
  }

  /* --- Sondeo completo de un candidato ---------------------------------- */

  /* Intenta el mejor nivel disponible y cae al siguiente. Devuelve `null` si
   * en esa dirección no hay nada reproducible. */
  function inspect(host, port, cb) {
    if (corsAllowed === false) {
      probeVideo(host, port, FluxConfig.videoProbeTimeout, cb);
      return;
    }
    probeMeta(host, port, FluxConfig.probeTimeout * 4, function (meta) {
      if (meta && looksLikeVideo(meta)) {
        cb(meta);
        return;
      }
      probeVideo(host, port, FluxConfig.videoProbeTimeout, cb);
    });
  }

  function looksLikeVideo(meta) {
    var type = meta.contentType || '';
    if (type.indexOf('video/') === 0 || type.indexOf('matroska') >= 0) { return true; }
    if (type.indexOf('audio/') === 0) { return true; }
    if (type.indexOf('octet-stream') >= 0 && meta.fileName) {
      return /\.(mkv|mp4|m4v|avi|mov|webm|ts|m2ts|mpg|mpeg|flv|wmv|3gp)$/i
        .test(meta.fileName);
    }
    return false;
  }

  /* --- Ejecutor con concurrencia limitada -------------------------------- */

  function pool(items, limit, worker, onProgress, done) {
    var index = 0;
    var active = 0;
    var completed = 0;
    var cancelled = false;

    function next() {
      if (cancelled) { return; }
      while (active < limit && index < items.length) {
        var item = items[index++];
        active++;
        /* jshint loopfunc:true */
        worker(item, function () {
          active--;
          completed++;
          if (onProgress) { onProgress(completed, items.length); }
          if (cancelled) { return; }
          if (completed === items.length) { done(); } else { next(); }
        });
      }
      if (items.length === 0) { done(); }
    }

    next();
    return { cancel: function () { cancelled = true; } };
  }

  /* --- Dirección del propio televisor ------------------------------------ */

  /* Sin esto no se sabe qué subred barrer. En un navegador normal no hay forma
   * de averiguarlo; en webOS sí, preguntándole al gestor de conexiones del
   * sistema a través del puente de servicios Luna. */
  function detectLocalIp(cb) {
    if (!window.PalmServiceBridge) {
      cb(null);
      return;
    }
    var answered = false;
    var bridge;
    try {
      bridge = new window.PalmServiceBridge();
    } catch (e) {
      cb(null);
      return;
    }

    var timer = setTimeout(function () {
      if (answered) { return; }
      answered = true;
      cb(null);
    }, 3000);

    bridge.onservicecallback = function (raw) {
      if (answered) { return; }
      answered = true;
      clearTimeout(timer);
      var reply;
      try {
        reply = JSON.parse(raw);
      } catch (e) {
        cb(null);
        return;
      }
      cb(pickIp(reply));
    };

    try {
      bridge.call(
        'luna://com.webos.service.connectionmanager/getStatus',
        JSON.stringify({})
      );
    } catch (e2) {
      clearTimeout(timer);
      cb(null);
    }
  }

  /* El televisor puede estar por cable y por Wi-Fi a la vez. Se prefiere la
   * que esté realmente conectada, y el cable antes que la Wi-Fi. */
  function pickIp(status) {
    var candidates = [status.wired, status.wifi, status.wifiDirect];
    for (var i = 0; i < candidates.length; i++) {
      var link = candidates[i];
      if (link && link.state === 'connected' && link.ipAddress) {
        return link.ipAddress;
      }
    }
    return null;
  }

  /* Solo se habla con direcciones IPv4 privadas. Misma frontera que en la app
   * de escritorio, aplicada antes de cualquier petición. */
  function isPrivateIp(ip) {
    var parts = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip || '');
    if (!parts) { return false; }
    var a = +parts[1], b = +parts[2], c = +parts[3], d = +parts[4];
    if (a > 255 || b > 255 || c > 255 || d > 255) { return false; }
    if (a === 169 && b === 254) { return false; }
    if (a === 10) { return true; }
    if (a === 172 && b >= 16 && b <= 31) { return true; }
    if (a === 192 && b === 168) { return true; }
    return false;
  }

  function prefixOf(ip) {
    var parts = ip.split('.');
    return parts[0] + '.' + parts[1] + '.' + parts[2];
  }

  return {
    url: url,
    inspect: inspect,
    probeMeta: probeMeta,
    probeReachable: probeReachable,
    probeVideo: probeVideo,
    pool: pool,
    abortAll: abortAll,
    detectLocalIp: detectLocalIp,
    isPrivateIp: isPrivateIp,
    prefixOf: prefixOf,
    fileNameFrom: fileNameFrom,
    canSweep: function () { return hasFetch; },
    concurrency: function () {
      return hasAbort ? FluxConfig.concurrencyWithAbort : FluxConfig.concurrency;
    },
    corsAllowed: function () { return corsAllowed; }
  };
}());
