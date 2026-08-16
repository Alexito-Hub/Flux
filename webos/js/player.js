
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

  var seekDebounceTimer = null;
  var seekPending = null;
  var seeking = false;

  function emit(name, payload) {
    if (destroyed) { return; }
    if (handlers[name]) { handlers[name](payload); }
  }

  function applyPipelineHints() {
    try {
      var opts = {
        option: {
          
          bufferControl: {
            minBufferTime: 8,       
            maxBufferTime: 30,      
            bufferMaxByte: 48 * 1024 * 1024  
          }
        },
        
        mediaTransportType: 'URI'
      };
      video.setAttribute('mediaOption', JSON.stringify(opts));
    } catch (e) {
      
    }
  }

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
    } catch (e) {  }

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

  function ready() {
    if (video.readyState >= 4) { return true; }
    if (video.readyState >= 3) {
      
      var ahead = bufferedAhead();
      return ahead >= 4 || ahead === 0; 
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
        promise['catch'](function () {  });
      }
    } catch (e) {  }
  }

  this.playPause = function () {
    if (video.paused) { play(); } else { video.pause(); }
  };

  this.seekBy = function (seconds) {
    if (!video.duration || !isFinite(video.duration)) { return; }
    
    var base = seekPending !== null ? seekPending : video.currentTime;
    var target = base + seconds;
    if (target < 0) { target = 0; }
    if (target > video.duration - 1) { target = video.duration - 1; }

    seekPending = target;
    lastProgressAt = Date.now();
    
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

  function safeSeek(seconds) {
    lastProgressAt = Date.now();

    try {
      if (video.seekable && video.seekable.length > 0) {
        
        var start = video.seekable.start(0);
        var end = video.seekable.end(video.seekable.length - 1);
        if (seconds < start) { seconds = start; }
        if (seconds > end) { seconds = end; }
      }
      seeking = true;
      video.currentTime = seconds;
    } catch (e) {
      seeking = false;
      
    }
  }

  this.candidate = function () { return candidate; };
  this.isPreparing = function () { return preparing; };
  this.isFollowing = function () { return following; };

  this.setFollowing = function (value) {
    following = !!value;
    if (following) { startWatching(); } else { stopWatching(); }
  };

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

    try {
      var promise = video.play();
      if (promise && promise.then) {
        promise.then(function () {
          
          if (destroyed) { return; }
          lastProgressAt = Date.now();
          
        })['catch'](function () {
          if (destroyed) { return; }
          
          fullReload(saved);
        });
        return;
      }
    } catch (e) {
      
    }
    fullReload(saved);
  }

  function fullReload(savedPosition) {
    self.load(candidate, { resumeAt: savedPosition, bustCache: true });
  }

  this.retry = function () {
    attempt = 0;
    reconnectNow();
  };

  function startWatching() {
    stopWatching();
    if (!following) { return; }
    watchTimer = setInterval(check, FluxConfig.watchInterval);
    stallTimer = setInterval(function () {
      if (destroyed || preparing || video.paused || video.ended) { return; }
      
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
    try { video.load(); } catch (e) {  }

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
    } catch (e) {  }
  };
}
