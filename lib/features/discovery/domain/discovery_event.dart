import 'stream_candidate.dart';

/// Etapas por las que pasa una búsqueda, en orden.
enum ScanPhase {
  idle,
  detectingNetwork,
  checkingKnown,
  quickScan,
  findingHosts,
  wideScan,
  done,
  cancelled,
  noNetwork;

  bool get isRunning => switch (this) {
        ScanPhase.detectingNetwork ||
        ScanPhase.checkingKnown ||
        ScanPhase.quickScan ||
        ScanPhase.findingHosts ||
        ScanPhase.wideScan =>
          true,
        _ => false,
      };

  String get label => switch (this) {
        ScanPhase.idle => 'Listo',
        ScanPhase.detectingNetwork => 'Detectando tu red…',
        ScanPhase.checkingKnown => 'Probando servidores conocidos…',
        ScanPhase.quickScan => 'Buscando en los puertos habituales…',
        ScanPhase.findingHosts => 'Localizando dispositivos activos…',
        ScanPhase.wideScan => 'Búsqueda amplia en los dispositivos activos…',
        ScanPhase.done => 'Búsqueda completada',
        ScanPhase.cancelled => 'Búsqueda detenida',
        ScanPhase.noNetwork => 'Sin red local',
      };
}

sealed class DiscoveryEvent {
  const DiscoveryEvent();
}

class PhaseChanged extends DiscoveryEvent {
  const PhaseChanged(this.phase, {this.detail});
  final ScanPhase phase;
  final String? detail;
}

class ScanProgressed extends DiscoveryEvent {
  const ScanProgressed(this.done, this.total);
  final int done;
  final int total;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0, 1).toDouble();
}

class CandidateFound extends DiscoveryEvent {
  const CandidateFound(this.candidate);
  final StreamCandidate candidate;
}

/// Las métricas llegan después del hallazgo: primero enseñamos el stream,
/// luego rellenamos su velocidad.
class CandidateMeasured extends DiscoveryEvent {
  const CandidateMeasured(this.candidate);
  final StreamCandidate candidate;
}

class ScanFailed extends DiscoveryEvent {
  const ScanFailed(this.message);
  final String message;
}
