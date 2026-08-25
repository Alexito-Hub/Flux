import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/net/lan_guard.dart';

/// Envuelve el motor de reproducción y añade lo que un stream de LAN necesita
/// para no cortarse: reintentos con memoria de posición, detección de atascos
/// y precarga al cambiar de fuente.
///
/// La posición y el búfer viven en [ValueNotifier] propios en lugar de en
/// `notifyListeners()` porque cambian varias veces por segundo: si tiraran de
/// toda la UI, los controles se reconstruirían 10 veces por segundo sin
/// necesidad.
class PlayerController extends ChangeNotifier {
  PlayerController({required Uri uri, this.startVolume = 100}) : _uri = uri;

  Uri _uri;
  final double startVolume;

  Uri get uri => _uri;

  /// Se avisa cuando algo huele a que la fuente ha cambiado (error o atasco),
  /// para que el vigilante lo compruebe al instante en vez de esperar a su
  /// siguiente ciclo.
  VoidCallback? onSourceSuspect;

  /// Seis intentos con tope de 10 s cubren ~35 s de caída. No es un número
  /// redondo por gusto: el servidor real se cae hasta medio minuto entre
  /// capítulos, y rendirse antes significaba mostrar un error justo cuando la
  /// emisión estaba a punto de volver.
  static const _maxReconnectAttempts = 6;
  static const _maxBackoffSeconds = 10;

  /// Si el reproductor lleva este tiempo sin avanzar ni un fotograma, damos la
  /// conexión por muerta aunque nadie haya lanzado un error: es exactamente lo
  /// que pasa cuando el teléfono que emite se va a dormir.
  static const _stallTimeout = Duration(seconds: 22);

  /// Cuánto vídeo se acumula antes de empezar a reproducir tras un cambio.
  static const _prebufferTarget = Duration(seconds: 6);
  static const _prebufferMaxWait = Duration(seconds: 8);

  late final Player player = Player(
    configuration: PlayerConfiguration(
      title: 'Flux',
      // Búfer grande: en Wi-Fi doméstico un pico de latencia de 2 s es normal,
      // y este colchón evita que se traduzca en un corte visible.
      bufferSize: 64 * 1024 * 1024,
      // Frontera de seguridad también en el motor: sin `file`, un servidor
      // malicioso no puede colar una ruta local en una lista de reproducción.
      protocolWhitelist: const ['http', 'https', 'tcp', 'tls', 'crypto'],
      logLevel: MPVLogLevel.error,
    ),
  );

  late final VideoController video = VideoController(
    player,
    configuration: const VideoControllerConfiguration(
      enableHardwareAcceleration: true,
    ),
  );

  final position = ValueNotifier<Duration>(Duration.zero);
  final buffer = ValueNotifier<Duration>(Duration.zero);

  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  bool _completed = false;
  double _rate = 1;
  double _volume = 100;
  Tracks _tracks = const Tracks();
  Track _current = const Track();
  String? _fatalError;
  bool _reconnecting = false;
  bool _preparing = false;
  int _attempt = 0;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _stallTimer;
  Timer? _reconnectTimer;
  Timer? _progressTimer;
  DateTime _lastProgress = DateTime.now();
  Duration _resumeAt = Duration.zero;
  bool _disposed = false;

  /// Cambia con cada carga nueva. Sirve para que una operación lenta que ya
  /// estaba en marcha (un reintento programado, una precarga a medias) se dé
  /// cuenta de que ha quedado obsoleta y se retire sin tocar nada.
  ///
  /// Sin esto hay una carrera real: al cambiar de capítulo el servidor se cae
  /// unos segundos, el reconector se programa y, si dispara justo después del
  /// cambio, reabriría la fuente nueva saltando a la posición de la vieja.
  int _generation = 0;

  Duration get duration => _duration;
  bool get playing => _playing;
  bool get buffering => _buffering;
  bool get completed => _completed;
  double get rate => _rate;
  double get volume => _volume;
  Tracks get tracks => _tracks;
  Track get currentTrack => _current;
  String? get fatalError => _fatalError;
  bool get reconnecting => _reconnecting;
  int get reconnectAttempt => _attempt;

  /// Cargando y llenando el búfer antes de empezar. Es el estado en el que se
  /// está durante la precarga de un capítulo nuevo.
  bool get preparing => _preparing;

  bool get hasDuration => _duration > Duration.zero;

  Future<void> initialize() async {
    if (!_guard(_uri)) return;
    _listen();
    await _tuneNetworkBehaviour();
    await player.setVolume(startVolume);
    _startStallWatchdog();
    _startProgressWatchdog();
    await _load(play: true);
  }

  /// Cambia a otra emisión precargándola antes de mostrarla.
  ///
  /// Es lo que ocurre al pasar de capítulo en el teléfono: se abre el archivo
  /// nuevo en pausa, se deja que el búfer se llene unos segundos y solo
  /// entonces se reproduce. Así el capítulo siguiente arranca ya fluido en vez
  /// de dar el tirón de los primeros segundos.
  Future<void> switchTo(Uri next) async {
    if (_disposed || !_guard(next)) return;
    // Guardamos el progreso del vídeo actual antes de cambiar
    unawaited(_saveProgress());
    _generation++;
    _uri = next;
    _resumeAt = Duration.zero;
    _attempt = 0;
    _fatalError = null;
    _completed = false;
    _reconnecting = false;
    _reconnectTimer?.cancel();
    position.value = Duration.zero;
    buffer.value = Duration.zero;
    await _load(play: true);
  }

  bool _guard(Uri candidate) {
    if (LanGuard.isAllowedUri(candidate)) return true;
    _fatalError =
        'Dirección no permitida: Flux solo reproduce desde tu red local.';
    notifyListeners();
    return false;
  }

  Future<void> _load({required bool play}) async {
    final generation = _generation;
    _preparing = true;
    _lastProgress = DateTime.now();
    notifyListeners();
    try {
      // `play: false` es lo que hace posible la precarga: mpv abre el archivo
      // y empieza a llenar su caché sin mostrar nada todavía.
      await player.open(Media(_uri.toString()), play: false);
      if (_isStale(generation)) return;
      await _restoreProgress();
      await _prebuffer(generation);
    } on Object catch (error) {
      debugPrint('[Flux] no se pudo abrir la fuente: $error');
      if (_isStale(generation)) return;
      _preparing = false;
      notifyListeners();
      _scheduleReconnect();
      return;
    }
    if (_isStale(generation)) return;
    _preparing = false;
    _lastProgress = DateTime.now();
    notifyListeners();
    if (play) await player.play();
  }

  bool _isStale(int generation) => _disposed || generation != _generation;

  /// Espera a tener colchón suficiente, con techo de tiempo: más vale empezar
  /// con poco búfer que dejar al usuario mirando una pantalla negra.
  Future<void> _prebuffer(int generation) async {
    final deadline = DateTime.now().add(_prebufferMaxWait);
    while (!_isStale(generation) && DateTime.now().isBefore(deadline)) {
      if (buffer.value >= _prebufferTarget) return;
      // Un archivo más corto que el objetivo de precarga nunca lo alcanzará.
      if (hasDuration && _duration <= _prebufferTarget && !_buffering) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Ajustes de libmpv específicos para servir video por HTTP en una LAN.
  Future<void> _tuneNetworkBehaviour() async {
    if (kIsWeb) return;
    final platform = player.platform as dynamic;
    Future<void> set(String key, String value) async {
      try {
        await platform.setProperty(key, value);
      } on Object {
        // Una propiedad no soportada en una versión de mpv no debe impedir
        // reproducir.
      }
    }

    await set('cache', 'yes');
    await set('cache-secs', '30');
    await set('demuxer-max-bytes', '64MiB');
    await set('demuxer-max-back-bytes', '32MiB');
    await set('demuxer-readahead-secs', '20');
    await set('network-timeout', '20');
    // Reconexión a nivel de FFmpeg: recupera cortes de red sin que el
    // reproductor llegue a enterarse.
    await set(
      'stream-lavf-o',
      'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,'
          'reconnect_delay_max=5,rw_timeout=15000000',
    );
    // El servidor anuncia `Accept-Ranges: bytes`, así que forzamos el seek
    // aunque mpv dude por tratarse de un stream.
    await set('force-seekable', 'yes');
    await set('hr-seek', 'yes');
  }

  void _listen() {
    void bind<T>(Stream<T> stream, void Function(T) handler) {
      _subscriptions.add(stream.listen(handler, onError: (Object _) {}));
    }

    bind(player.stream.position, (value) {
      if (value > Duration.zero) {
        _resumeAt = value;
        _lastProgress = DateTime.now();
        // Avanzar de verdad es la única prueba de que la reconexión funcionó,
        // así que es aquí donde se perdona el historial de intentos. Si no,
        // cinco cortes esporádicos a lo largo de una película acabarían
        // agotando el contador y rindiéndose sin motivo.
        if (_attempt > 0 && !_reconnecting) {
          _attempt = 0;
          notifyListeners();
        }
      }
      position.value = value;
    });
    bind(player.stream.buffer, (value) => buffer.value = value);
    bind(player.stream.duration, (value) {
      _duration = value;
      notifyListeners();
    });
    bind(player.stream.playing, (value) {
      _playing = value;
      _lastProgress = DateTime.now();
      // La pantalla se mantiene encendida solo mientras algo se reproduce; en
      // pausa el móvil vuelve a comportarse con normalidad.
      unawaited(WakelockPlus.toggle(enable: value));
      notifyListeners();
    });
    bind(player.stream.buffering, (value) {
      _buffering = value;
      if (!value) _lastProgress = DateTime.now();
      notifyListeners();
    });
    bind(player.stream.completed, (value) {
      _completed = value;
      notifyListeners();
      // Un archivo que termina también puede significar que el emisor pasó al
      // siguiente capítulo: merece una comprobación.
      if (value) onSourceSuspect?.call();
    });
    bind(player.stream.rate, (value) {
      _rate = value;
      notifyListeners();
    });
    bind(player.stream.volume, (value) {
      _volume = value;
      notifyListeners();
    });
    bind(player.stream.tracks, (value) {
      _tracks = value;
      notifyListeners();
    });
    bind(player.stream.track, (value) {
      _current = value;
      notifyListeners();
    });
    bind(player.stream.error, _onEngineError);
  }

  void _onEngineError(String message) {
    if (_disposed) return;
    debugPrint('[Flux] error de reproducción: $message');
    // Antes de reintentar por nuestra cuenta, que alguien mire si lo que hay
    // al otro lado sigue siendo el mismo archivo.
    onSourceSuspect?.call();
    _scheduleReconnect();
  }

  /// Vigila que la reproducción avance de verdad. mpv no siempre emite un
  /// error cuando el otro extremo deja de enviar datos: simplemente se queda
  /// en "buffering" para siempre.
  void _startStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed || _reconnecting || _preparing || !_playing || _completed) {
        return;
      }
      final stalledFor = DateTime.now().difference(_lastProgress);
      if (stalledFor > _stallTimeout) {
        debugPrint('[Flux] atasco detectado (${stalledFor.inSeconds}s)');
        onSourceSuspect?.call();
        _scheduleReconnect();
      }
    });
  }

  void _startProgressWatchdog() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
  }

  Future<void> _saveProgress() async {
    if (_disposed || !hasDuration) return;
    
    final currentPos = position.value;
    // Consideramos finalizada si llegamos al 95% o el flag _completed es true
    final isFinished = _completed || (currentPos.inSeconds > 0 && currentPos >= _duration * 0.95);
    
    final prefs = await SharedPreferences.getInstance();
    final key = 'flux_progress_${_uri.toString()}';

    if (isFinished) {
      await prefs.remove(key);
    } else if (currentPos.inSeconds > 10) {
      await prefs.setInt(key, currentPos.inSeconds);
    }
  }

  Future<void> _restoreProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'flux_progress_${_uri.toString()}';
    final savedSeconds = prefs.getInt(key);
    
    if (savedSeconds != null && savedSeconds > 0) {
      final restorePos = Duration(seconds: savedSeconds);
      position.value = restorePos;
      // Actualizamos para que el reconector sepa desde dónde continuar
      _resumeAt = restorePos; 
      await player.seek(restorePos);
    }
  }

  /// Reintento con espera creciente (1, 2, 4, 8, 10, 10 s), reanudando en el
  /// segundo exacto donde se cortó.
  void _scheduleReconnect() {
    if (_disposed || _reconnecting || _preparing) return;
    if (_attempt >= _maxReconnectAttempts) {
      _fatalError = 'Se perdió la conexión con el servidor y no se pudo '
          'recuperar tras $_attempt intentos.';
      _reconnecting = false;
      notifyListeners();
      return;
    }

    _reconnecting = true;
    _attempt++;
    _fatalError = null;
    notifyListeners();

    final delay =
        Duration(seconds: math.min(_maxBackoffSeconds, 1 << (_attempt - 1)));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _reconnectNow);
  }

  Future<void> _reconnectNow() async {
    if (_disposed) return;
    // Si mientras esperábamos el turno el vigilante cambió de capítulo, este
    // reintento pertenece a una película que ya nadie está viendo.
    final generation = _generation;
    final resume = _resumeAt;
    try {
      await player.open(Media(_uri.toString()));
      if (_isStale(generation)) return;
      if (resume > Duration.zero) await player.seek(resume);
      await player.play();
      if (_isStale(generation)) return;
      _reconnecting = false;
      _lastProgress = DateTime.now();
      // El contador solo se reinicia cuando la reproducción vuelve a avanzar
      // (lo hace el listener de posición), no aquí: abrir sin recibir datos no
      // es éxito.
      notifyListeners();
    } on Object catch (error) {
      if (_isStale(generation)) return;
      debugPrint('[Flux] reintento fallido: $error');
      _reconnecting = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  /// Reintento manual desde la pantalla de error.
  Future<void> retry() async {
    _attempt = 0;
    _fatalError = null;
    notifyListeners();
    await _reconnectNow();
  }

  Future<void> playOrPause() async {
    _lastProgress = DateTime.now();
    await player.playOrPause();
  }

  /// Salto relativo, acotado a los límites del archivo para que un doble toque
  /// al final no lo dé por terminado.
  Future<void> seekBy(Duration delta) async {
    final target = position.value + delta;
    final max = _duration - const Duration(milliseconds: 500);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (hasDuration && target > max ? max : target);
    position.value = clamped; // respuesta inmediata en la barra
    _lastProgress = DateTime.now();
    await player.seek(clamped);
  }

  Future<void> seekTo(Duration target) async {
    position.value = target;
    _lastProgress = DateTime.now();
    await player.seek(target);
  }

  Future<void> setVolume(double value) =>
      player.setVolume(value.clamp(0, 100).toDouble());

  Future<void> setRate(double value) => player.setRate(value);

  Future<void> setAudioTrack(AudioTrack track) => player.setAudioTrack(track);

  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      player.setSubtitleTrack(track);

  @override
  void dispose() {
    _disposed = true;
    unawaited(_saveProgress()); // Un último intento de guardar al cerrar
    _stallTimer?.cancel();
    _reconnectTimer?.cancel();
    _progressTimer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    position.dispose();
    buffer.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(player.dispose());
    super.dispose();
  }
}
