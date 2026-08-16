import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/discovery_repository.dart';
import '../data/known_hosts_store.dart';
import '../domain/discovery_event.dart';
import '../domain/lan_subnet.dart';
import '../domain/stream_candidate.dart';

final discoveryRepositoryProvider = Provider<DiscoveryRepository>((ref) {
  final repository = DiscoveryRepository();
  ref.onDispose(repository.dispose);
  return repository;
});

class DiscoveryState {
  const DiscoveryState({
    this.phase = ScanPhase.idle,
    this.detail,
    this.progress = 0,
    this.candidates = const [],
    this.subnets = const [],
    this.selectedSubnet,
    this.message,
    this.manualError,
    this.checkingManual = false,
  });

  final ScanPhase phase;
  final String? detail;
  final double progress;
  final List<StreamCandidate> candidates;
  final List<LanSubnet> subnets;
  final LanSubnet? selectedSubnet;

  /// Aviso informativo (no fatal) sobre la última búsqueda.
  final String? message;
  final String? manualError;
  final bool checkingManual;

  bool get isScanning => phase.isRunning;
  bool get isEmpty => candidates.isEmpty;

  /// Se ofrece la entrada manual en cuanto una búsqueda termina sin resultados:
  /// es la vía de escape prometida cuando el barrido no llega.
  bool get shouldOfferManual =>
      candidates.isEmpty &&
      (phase == ScanPhase.done ||
          phase == ScanPhase.cancelled ||
          phase == ScanPhase.noNetwork);

  StreamCandidate? get best => candidates.isEmpty ? null : candidates.first;

  DiscoveryState copyWith({
    ScanPhase? phase,
    String? detail,
    double? progress,
    List<StreamCandidate>? candidates,
    List<LanSubnet>? subnets,
    LanSubnet? selectedSubnet,
    String? message,
    String? manualError,
    bool? checkingManual,
    bool clearMessage = false,
    bool clearManualError = false,
  }) {
    return DiscoveryState(
      phase: phase ?? this.phase,
      detail: detail ?? this.detail,
      progress: progress ?? this.progress,
      candidates: candidates ?? this.candidates,
      subnets: subnets ?? this.subnets,
      selectedSubnet: selectedSubnet ?? this.selectedSubnet,
      message: clearMessage ? null : (message ?? this.message),
      manualError: clearManualError ? null : (manualError ?? this.manualError),
      checkingManual: checkingManual ?? this.checkingManual,
    );
  }
}

class DiscoveryController extends Notifier<DiscoveryState> {
  StreamSubscription<DiscoveryEvent>? _subscription;

  @override
  DiscoveryState build() {
    ref.onDispose(() => _subscription?.cancel());
    unawaited(loadSubnets());
    return const DiscoveryState();
  }

  DiscoveryRepository get _repository => ref.read(discoveryRepositoryProvider);

  Future<void> loadSubnets() async {
    final subnets = await _repository.availableSubnets();
    if (!ref.mounted) return;
    final preferred = state.selectedSubnet ??
        subnets.where((s) => !s.isVirtual).firstOrNull ??
        subnets.firstOrNull;
    state = state.copyWith(subnets: subnets, selectedSubnet: preferred);
  }

  void selectSubnet(LanSubnet subnet) {
    state = state.copyWith(selectedSubnet: subnet);
    unawaited(start());
  }

  /// Lanza una búsqueda. [exhaustive] fuerza también la fase amplia aunque la
  /// rápida haya encontrado algo.
  Future<void> start({bool exhaustive = false}) async {
    await _subscription?.cancel();
    _subscription = null;

    state = state.copyWith(
      phase: ScanPhase.detectingNetwork,
      progress: 0,
      candidates: const [],
      clearMessage: true,
      clearManualError: true,
    );

    final stream = _repository.scan(
      subnet: state.selectedSubnet,
      exhaustive: exhaustive,
    );

    _subscription = stream.listen(
      _onEvent,
      onDone: () {
        if (!ref.mounted) return;
        if (state.phase.isRunning) {
          state = state.copyWith(phase: ScanPhase.done, progress: 1);
        }
      },
      onError: (Object error) {
        if (!ref.mounted) return;
        state = state.copyWith(
          phase: ScanPhase.done,
          message: 'La búsqueda falló: $error',
        );
      },
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!ref.mounted) return;
    state = state.copyWith(phase: ScanPhase.cancelled);
  }

  void _onEvent(DiscoveryEvent event) {
    if (!ref.mounted) return;
    switch (event) {
      case PhaseChanged(:final phase, :final detail):
        state = state.copyWith(
          phase: phase,
          detail: detail,
          progress: phase == ScanPhase.done ? 1 : 0,
        );
      case ScanProgressed():
        state = state.copyWith(progress: event.fraction);
      case CandidateFound(:final candidate):
        state = state.copyWith(candidates: _merge(candidate));
      case CandidateMeasured(:final candidate):
        state = state.copyWith(candidates: _merge(candidate));
      case ScanFailed(:final message):
        state = state.copyWith(message: message);
    }
  }

  /// Inserta o actualiza un candidato y reordena por calidad.
  List<StreamCandidate> _merge(StreamCandidate candidate) {
    final list = List.of(state.candidates);
    final index = list.indexWhere((c) => c.id == candidate.id);
    if (index >= 0) {
      // Conservamos las métricas ya medidas si el evento nuevo no las trae.
      final existing = list[index];
      list[index] = candidate.metrics == null && existing.metrics != null
          ? candidate.copyWith(metrics: existing.metrics)
          : candidate;
    } else {
      list.add(candidate);
    }
    list.sort(_byQuality);
    return list;
  }

  /// Orden: primero lo medido y rápido, luego lo medido y lento, y al final lo
  /// que aún no tiene medición. Dentro de un empate, lo que ya conocíamos.
  static int _byQuality(StreamCandidate a, StreamCandidate b) {
    final scoreA = a.metrics?.score;
    final scoreB = b.metrics?.score;
    if (scoreA != null && scoreB != null && scoreA != scoreB) {
      return scoreB.compareTo(scoreA);
    }
    if (scoreA != null && scoreB == null) return -1;
    if (scoreA == null && scoreB != null) return 1;
    final rank = _sourceRank(a.source).compareTo(_sourceRank(b.source));
    if (rank != 0) return rank;
    return a.address.compareTo(b.address);
  }

  static int _sourceRank(DiscoverySource source) => switch (source) {
        DiscoverySource.manual => 0,
        DiscoverySource.remembered => 1,
        DiscoverySource.quickScan => 2,
        DiscoverySource.wideScan => 3,
      };

  /// Añade una dirección escrita a mano. Devuelve el candidato si es válido.
  Future<StreamCandidate?> addManual(String input) async {
    final parsed = KnownHostsStore.parseAddress(input);
    if (parsed == null) {
      state = state.copyWith(
        manualError: 'Dirección no válida. Usa una IP de tu red local, '
            'por ejemplo 192.168.1.5:4445',
        checkingManual: false,
      );
      return null;
    }

    state = state.copyWith(checkingManual: true, clearManualError: true);
    final candidate = await _repository.probeManual(parsed.host, parsed.port);
    if (!ref.mounted) return null;

    if (candidate == null) {
      state = state.copyWith(
        checkingManual: false,
        manualError: 'No hay ningún video en ${parsed.host}:${parsed.port}. '
            'Comprueba que la transmisión esté activa.',
      );
      return null;
    }

    state = state.copyWith(
      checkingManual: false,
      candidates: _merge(candidate),
      clearManualError: true,
    );
    unawaited(_measure(candidate));
    return candidate;
  }

  Future<void> _measure(StreamCandidate candidate) async {
    final metrics = await _repository.measure(candidate);
    if (!ref.mounted || metrics == null) return;
    state = state.copyWith(candidates: _merge(candidate.copyWith(metrics: metrics)));
  }

  /// Vuelve a medir un stream concreto (botón de la tarjeta).
  Future<void> remeasure(StreamCandidate candidate) => _measure(candidate);

  /// Se llama al reproducir con éxito: así la próxima búsqueda lo encuentra en
  /// 200 ms en vez de barrer toda la red.
  Future<void> remember(StreamCandidate candidate) =>
      _repository.remember(candidate);

  void clearManualError() =>
      state = state.copyWith(clearManualError: true);
}

final discoveryControllerProvider =
    NotifierProvider<DiscoveryController, DiscoveryState>(
  DiscoveryController.new,
);
