import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/stream_candidate.dart';
import 'port_scanner.dart';
import 'scan_config.dart';
import 'stream_prober.dart';

/// Lo que le puede pasar a la emisión mientras la estás viendo.
sealed class WatchEvent {
  const WatchEvent();
}

/// Detrás de la misma dirección hay otro archivo: has cambiado de capítulo.
class SourceChanged extends WatchEvent {
  const SourceChanged(this.candidate, {this.recovered = false});
  final StreamCandidate candidate;

  /// `true` si además hubo que volver a buscarlo porque cambió de puerto.
  final bool recovered;
}

/// El servidor dejó de responder. Puede ser el hueco entre dos capítulos.
class SourceLost extends WatchEvent {
  const SourceLost();
}

/// Volvió el mismo archivo de antes tras una caída pasajera.
class SourceRestored extends WatchEvent {
  const SourceRestored(this.candidate);
  final StreamCandidate candidate;
}

/// Pregunta si sigue habiendo un video servible en esa dirección.
typedef ProbeSource = Future<StreamCandidate?> Function(String host, int port);

/// Rebusca la emisión en otros puertos del mismo dispositivo.
typedef RescanHost = Future<StreamCandidate?> Function(String host);

/// Vigila la emisión que se está reproduciendo y avisa cuando cambia.
///
/// El caso a resolver: cambias de capítulo en Movie Plus y la dirección sigue
/// siendo `192.168.1.5:4445`, pero el archivo es otro. Sin esto, la
/// reconexión automática de FFmpeg intentaría continuar por el mismo offset de
/// bytes sobre un archivo distinto — y eso no da el capítulo nuevo, da basura.
///
/// El sondeo es un `HEAD` cada pocos segundos. Comprobado contra el servidor
/// real: acepta conexiones concurrentes y responde 200 mientras sirve el video
/// a 8 MB/s, así que vigilar no le quita ancho de banda a lo que estás viendo.
class StreamWatcher {
  StreamWatcher({
    required ProbeSource probe,
    RescanHost? rescan,
    this.interval = const Duration(seconds: 5),
    this.recoveryInterval = const Duration(milliseconds: 1200),
    this.missesBeforeLost = 2,
  })  : _probe = probe,
        _rescan = rescan;

  /// Construcción normal a partir de las piezas reales de red.
  factory StreamWatcher.of(
    StreamProber prober, {
    PortScanner scanner = const PortScanner(),
    Duration interval = const Duration(seconds: 5),
  }) {
    return StreamWatcher(
      interval: interval,
      probe: (host, port) =>
          prober.probe(host, port, source: DiscoverySource.quickScan),
      rescan: (host) => _rescanWith(prober, scanner, host),
    );
  }

  final ProbeSource _probe;
  final RescanHost? _rescan;

  /// Cada cuánto se pregunta "¿sigues siendo el mismo archivo?".
  final Duration interval;

  /// Ritmo de sondeo cuando algo va mal.
  ///
  /// Medido sobre el servidor real: al cambiar de capítulo se cae durante unos
  /// 8 segundos. Sondear cada 5 s durante ese hueco desperdiciaría media
  /// ventana; en cuanto falla un sondeo se pasa a mirar cada 1,2 s para
  /// enganchar el capítulo nuevo en cuanto asome.
  final Duration recoveryInterval;

  /// Cuántos sondeos fallidos seguidos hacen falta para dar la emisión por
  /// caída. Uno solo no basta: el servidor tarda hasta 1,4 s en contestar y un
  /// pico de Wi-Fi provocaría falsas alarmas.
  final int missesBeforeLost;

  final _controller = StreamController<WatchEvent>.broadcast();
  Timer? _timer;
  Duration? _currentInterval;
  StreamCandidate? _current;
  bool _checking = false;
  bool _lost = false;
  int _misses = 0;
  bool _disposed = false;

  Stream<WatchEvent> get events => _controller.stream;
  StreamCandidate? get current => _current;
  bool get isLost => _lost;

  void start(StreamCandidate initial) {
    _current = initial;
    _misses = 0;
    _lost = false;
    _retune();
  }

  /// Ajusta el ritmo del sondeo al estado actual. Solo recrea el temporizador
  /// si el ritmo cambia de verdad.
  void _retune() {
    if (_disposed) return;
    final wanted = (_misses > 0 || _lost) ? recoveryInterval : interval;
    if (_timer != null && _currentInterval == wanted) return;
    _currentInterval = wanted;
    _timer?.cancel();
    _timer = Timer.periodic(wanted, (_) => unawaited(check()));
  }

  /// Comprobación inmediata, sin esperar al siguiente ciclo.
  ///
  /// La llama el reproductor en cuanto detecta un error o un atasco: si la
  /// causa fue un cambio de capítulo, así se reacciona al instante en vez de
  /// dentro de cinco segundos.
  void poke() => unawaited(check());

  Future<void> check() async {
    if (_disposed || _checking) return;
    final current = _current;
    if (current == null) return;

    _checking = true;
    try {
      final probe = await _probe(current.host, current.port);

      if (probe == null) {
        await _handleMiss(current);
        return;
      }

      _misses = 0;
      if (_lost) {
        _lost = false;
        // Volvió algo por el mismo puerto: puede ser lo mismo de antes o ya el
        // capítulo siguiente.
        _current = probe;
        _emit(probe.isSameContentAs(current)
            ? SourceRestored(probe)
            : SourceChanged(probe, recovered: true));
        return;
      }

      if (!probe.isSameContentAs(current)) {
        _current = probe;
        _emit(SourceChanged(probe));
      }
    } on Object catch (error) {
      debugPrint('[Flux] fallo vigilando la emisión: $error');
    } finally {
      _checking = false;
      _retune();
    }
  }

  Future<void> _handleMiss(StreamCandidate current) async {
    _misses++;
    if (_misses < missesBeforeLost || _lost) return;

    _lost = true;
    _emit(const SourceLost());

    // Movie Plus podría haber levantado el capítulo nuevo en otro puerto. Un
    // barrido de los puertos habituales sobre un único host son 22 conexiones:
    // termina antes de que dé tiempo a preguntarse qué pasa.
    final found = await _rescan?.call(current.host);
    if (found != null && !_disposed) {
      _current = found;
      _lost = false;
      _misses = 0;
      _emit(SourceChanged(found, recovered: true));
    }
  }

  static Future<StreamCandidate?> _rescanWith(
    StreamProber prober,
    PortScanner scanner,
    String host,
  ) async {
    try {
      final open = await scanner
          .sweepHostMajor(
            hosts: [host],
            ports: ScanConfig.quickPorts,
            timeout: const Duration(milliseconds: 400),
            concurrency: 24,
          )
          .toList();

      for (final port in open) {
        final candidate = await prober.probe(
          port.host,
          port.port,
          source: DiscoverySource.quickScan,
        );
        if (candidate != null) return candidate;
      }
    } on Object catch (error) {
      debugPrint('[Flux] no se pudo rebuscar la emisión: $error');
    }
    return null;
  }

  void _emit(WatchEvent event) {
    if (!_disposed && !_controller.isClosed) _controller.add(event);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_controller.close());
  }
}
