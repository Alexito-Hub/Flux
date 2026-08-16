/* Descubrimiento de emisiones en la red local, adaptado a lo que un televisor
 * puede hacer de verdad.
 *
 * La app de escritorio barre 254 hosts × 22 puertos porque abre sockets TCP
 * crudos. Aquí cada sondeo pasa por el navegador, así que el orden importa
 * mucho más: primero lo que ya funcionó, luego el puerto de Movie Plus en toda
 * la red, y solo si eso falla se prueban otros puertos. */
var FluxDiscovery = (function () {
  'use strict';

  function candidateFrom(raw, source) {
    var fileName = raw.fileName || null;
    return {
      host: raw.host,
      port: raw.port,
      url: raw.url,
      fileName: fileName,
      contentType: raw.contentType || null,
      size: raw.size || null,
      lastModified: raw.lastModified || null,
      duration: typeof raw.duration === 'number' ? raw.duration : null,
      width: raw.width || null,
      height: raw.height || null,
      seekable: !!raw.seekable,
      probe: raw.source,
      source: source,
      address: raw.host + ':' + raw.port,
      title: displayTitle(raw, fileName),
      fingerprint: fingerprintOf(raw)
    };
  }

  /* Sin CORS no hay nombre de archivo, así que el título tiene que salir de lo
   * que sí sabemos. Repetir la dirección — que ya se enseña justo debajo — no
   * aporta nada; la resolución al menos dice qué estás a punto de ver. */
  function displayTitle(raw, fileName) {
    if (fileName) { return prettyTitle(fileName); }
    if (raw.width && raw.height) { return 'Emisión ' + raw.width + '×' + raw.height; }
    return 'Emisión en directo';
  }

  /* Identifica el archivo, no la dirección.
   *
   * Con cabeceras se usa nombre + tamaño + fecha, igual que en escritorio. Sin
   * ellas queda la duración que reporta el propio reproductor, que es
   * sorprendentemente buena huella: dos capítulos no duran lo mismo al
   * milisegundo. */
  function fingerprintOf(raw) {
    if (raw.fileName || raw.size || raw.lastModified) {
      return [raw.fileName || '', raw.size || 0, raw.lastModified || ''].join('|');
    }
    if (typeof raw.duration === 'number' && isFinite(raw.duration)) {
      return 'dur:' + raw.duration.toFixed(3);
    }
    return 'desconocido';
  }

  function prettyTitle(fileName) {
    var name = String(fileName);
    var dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 5) { name = name.substring(0, dot); }
    return name.replace(/[._]+/g, ' ').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
  }

  function loadKnown() {
    try {
      var raw = window.localStorage.getItem(FluxConfig.storageKey);
      return raw ? JSON.parse(raw) : [];
    } catch (e) {
      return [];
    }
  }

  function remember(host, port) {
    if (!FluxNet.isPrivateIp(host)) { return; }
    try {
      var list = loadKnown();
      var entry = host + ':' + port;
      var filtered = [entry];
      for (var i = 0; i < list.length && filtered.length < 8; i++) {
        if (list[i] !== entry) { filtered.push(list[i]); }
      }
      window.localStorage.setItem(FluxConfig.storageKey, JSON.stringify(filtered));
    } catch (e) { /* sin almacenamiento se sigue funcionando, solo más lento */ }
  }

  /* Acepta lo que se teclee con el mando: `192.168.1.5:4445`, con esquema, con
   * ruta, o solo la IP (se asume el 4445). */
  function parseAddress(text) {
    var input = String(text || '').replace(/^\s+|\s+$/g, '');
    if (!input) { return null; }
    input = input.replace(/^https?:\/\//i, '');
    input = input.split('/')[0];
    var parts = input.split(':');
    var host = parts[0];
    var port = parts.length > 1 ? parseInt(parts[1], 10) : FluxConfig.primaryPort;
    if (!FluxNet.isPrivateIp(host)) { return null; }
    if (!port || port < 1 || port > 65535) { return null; }
    return { host: host, port: port };
  }

  /* --- Búsqueda ---------------------------------------------------------- */

  function search(handlers) {
    var seen = {};
    var found = 0;
    var cancelled = false;
    var running = null;

    function emitFound(raw, source) {
      if (cancelled || !raw) { return; }
      var key = raw.host + ':' + raw.port;
      if (seen[key]) { return; }
      seen[key] = true;
      found++;
      handlers.onFound(candidateFrom(raw, source));
    }

    function phase(name, detail) {
      if (!cancelled) { handlers.onPhase(name, detail); }
    }

    function finish() {
      if (!cancelled) { handlers.onDone(found); }
    }

    /* Fase 1: lo que ya funcionó otras veces. */
    function checkKnown(next) {
      var known = loadKnown();
      if (!known.length) { next(); return; }
      phase('conocidos', known.length + ' recordadas');

      var pending = known.length;
      for (var i = 0; i < known.length; i++) {
        var parsed = parseAddress(known[i]);
        if (!parsed) {
          if (--pending === 0) { next(); }
          continue;
        }
        /* jshint loopfunc:true */
        FluxNet.inspect(parsed.host, parsed.port, function (result) {
          emitFound(result, 'conocido');
          if (--pending === 0) { next(); }
        });
      }
    }

    /* Fase 2: el puerto de Movie Plus en toda la subred. */
    function sweepPrimary(prefix, next) {
      if (!FluxNet.canSweep()) {
        handlers.onWarning(
          'Este televisor es demasiado antiguo para barrer la red. ' +
          'Escribe la dirección a mano.'
        );
        next();
        return;
      }
      phase('rapido', prefix + '.0/24 · puerto ' + FluxConfig.primaryPort);
      sweepPorts(prefix, [FluxConfig.primaryPort], next);
    }

    /* Fase 3: otros puertos habituales, solo si hizo falta. */
    function sweepSecondary(prefix, next) {
      if (found > 0 || !FluxNet.canSweep()) { next(); return; }
      phase('amplio', 'otros ' + FluxConfig.secondaryPorts.length + ' puertos');
      sweepPorts(prefix, FluxConfig.secondaryPorts, next);
    }

    /* El barrido no espera a terminar para enseñar lo que encuentra.
     *
     * Recorrer los 254 hosts lleva unos 15 segundos, pero el teléfono suele
     * estar en una IP baja y aparece en el primer segundo. Validar sobre la
     * marcha significa que ya puedes estar viendo el capítulo mientras el
     * resto de la red se sigue barriendo por detrás. */
    function sweepPorts(prefix, ports, next) {
      var targets = [];
      var order = FluxConfig.hostOrder();
      // Orden puerto-mayor, igual que en escritorio: así el puerto más
      // probable se prueba en toda la red antes de pasar al siguiente.
      for (var p = 0; p < ports.length; p++) {
        for (var h = 0; h < order.length; h++) {
          targets.push({ host: prefix + '.' + order[h], port: ports[p] });
        }
      }

      var queue = [];
      var validating = false;
      var sweepDone = false;

      /* Las validaciones van de una en una: cada una puede acabar abriendo el
       * pipeline de medios del televisor, y ese recurso no se comparte. */
      function pump() {
        if (validating || cancelled) { return; }
        if (!queue.length) {
          if (sweepDone) { next(); }
          return;
        }
        validating = true;
        var target = queue.shift();
        FluxNet.inspect(target.host, target.port, function (result) {
          emitFound(result, 'busqueda');
          validating = false;
          pump();
        });
      }

      running = FluxNet.pool(
        targets,
        FluxNet.concurrency(),
        function (target, done) {
          if (cancelled) { done(); return; }
          FluxNet.probeReachable(
            target.host,
            target.port,
            FluxConfig.probeTimeout,
            function (reachable) {
              if (reachable) {
                queue.push(target);
                pump();
              }
              done();
            }
          );
        },
        function (completed, total) { handlers.onProgress(completed, total); },
        function () {
          if (cancelled) { return; }
          sweepDone = true;
          pump();
        }
      );
    }

    /* Arranque: hace falta saber en qué red está el televisor. */
    FluxNet.detectLocalIp(function (ip) {
      if (cancelled) { return; }
      checkKnown(function () {
        if (cancelled) { return; }
        if (!ip || !FluxNet.isPrivateIp(ip)) {
          handlers.onWarning(
            'No se pudo averiguar la dirección del televisor. ' +
            'Puedes escribir la del teléfono a mano.'
          );
          finish();
          return;
        }
        var prefix = FluxNet.prefixOf(ip);
        sweepPrimary(prefix, function () {
          sweepSecondary(prefix, finish);
        });
      });
    });

    return {
      cancel: function () {
        cancelled = true;
        if (running) { running.cancel(); }
        // Además de dejar de lanzar peticiones, se cortan las que ya iban en
        // vuelo: el reproductor necesita las conexiones libres.
        FluxNet.abortAll();
      }
    };
  }

  return {
    search: search,
    remember: remember,
    parseAddress: parseAddress,
    candidateFrom: candidateFrom,
    prettyTitle: prettyTitle
  };
}());
