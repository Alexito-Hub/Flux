import 'dart:async';

import '../domain/discovery_event.dart';
import '../domain/lan_subnet.dart';
import '../domain/stream_candidate.dart';
import 'external_links_store.dart';
import 'known_hosts_store.dart';
import 'parallel.dart';
import 'port_scanner.dart';
import 'scan_config.dart';
import 'stream_prober.dart';
import 'subnet_detector.dart';

/// Orquesta el descubrimiento completo, de más barato a más caro:
///
/// 1. **Conocidos** — los `host:puerto` que ya funcionaron. ~200 ms.
/// 2. **Rápido** — 254 hosts × 22 puertos habituales, orden puerto-mayor.
/// 3. **Vivos** — si lo anterior no dio nada, detecta qué IPs existen.
/// 4. **Amplio** — ~400 puertos, pero solo sobre los pocos hosts vivos.
///
/// Cada fase se salta si la anterior ya encontró algo, salvo que se pida
/// [exhaustive].
class DiscoveryRepository {
  DiscoveryRepository({
    this.config = const ScanConfig(),
    SubnetDetector? detector,
    PortScanner? scanner,
    StreamProber? prober,
    KnownHostsStore? knownHosts,
    ExternalLinksStore? externalLinks,
  })  : _detector = detector ?? const SubnetDetector(),
        _scanner = scanner ?? PortScanner(config: config),
        _prober = prober ?? StreamProber(config: config),
        _knownHosts = knownHosts ?? KnownHostsStore(),
        _externalLinks = externalLinks ?? ExternalLinksStore();

  final ScanConfig config;
  final SubnetDetector _detector;
  final PortScanner _scanner;
  final StreamProber _prober;
  final KnownHostsStore _knownHosts;
  final ExternalLinksStore _externalLinks;

  late final Semaphore _probeGate = Semaphore(config.probeConcurrency);
  late final Semaphore _benchGate = Semaphore(config.benchmarkConcurrency);

  Future<List<LanSubnet>> availableSubnets() => _detector.detect();

  void dispose() => _prober.dispose();

  /// Comprueba una dirección escrita a mano. Es la vía de escape cuando el
  /// barrido no encuentra nada (router con aislamiento de clientes, subred
  /// distinta, puerto exótico).
  Future<StreamCandidate?> probeManual(String host, int port) =>
      _prober.probe(host, port, source: DiscoverySource.manual);

  /// Comprueba una URL de Internet (ej. enlace pegado por el usuario).
  Future<StreamCandidate?> probeExternalLink(
          ({String host, int port, Uri uri}) parsed,
          {Map<String, String>? httpHeaders}) =>
      _prober.probeExternal(parsed.uri, source: DiscoverySource.directLink, httpHeaders: httpHeaders);

  Future<StreamMetrics?> measure(StreamCandidate candidate) =>
      _benchGate.run(() => _prober.benchmark(candidate));

  Future<void> remember(StreamCandidate candidate) =>
      _knownHosts.remember(candidate.host, candidate.port);

  Future<void> rememberExternal(StreamCandidate candidate) =>
      _externalLinks.remember(candidate);

  Stream<DiscoveryEvent> scan({LanSubnet? subnet, bool exhaustive = false}) {
    final session = _ScanSession();
    late final StreamController<DiscoveryEvent> controller;

    controller = StreamController<DiscoveryEvent>(
      onListen: () => _run(controller, session, subnet, exhaustive),
      onCancel: () async {
        session.cancel();
        await session.disposeSubscriptions();
      },
    );
    return controller.stream;
  }

  Future<void> _run(
    StreamController<DiscoveryEvent> out,
    _ScanSession session,
    LanSubnet? requested,
    bool exhaustive,
  ) async {
    void emit(DiscoveryEvent event) {
      if (!session.cancelled && !out.isClosed) out.add(event);
    }

    try {
      emit(const PhaseChanged(ScanPhase.detectingNetwork));
      final subnet = requested ?? await _detector.preferred();
      if (subnet == null) {
        emit(const PhaseChanged(ScanPhase.noNetwork));
        emit(const ScanFailed(
          'No se detectó ninguna red local. Conéctate al mismo Wi-Fi que el '
          'dispositivo que emite.',
        ));
        return;
      }
      if (session.cancelled) return;

      final hosts = subnet.hosts();

      // --- Fase 1: lo que ya conocemos -----------------------------------
      emit(PhaseChanged(ScanPhase.checkingKnown, detail: subnet.cidr));
      final known = await _knownHosts.load();
      if (known.isNotEmpty && !session.cancelled) {
        await Future.wait([
          for (final entry in known)
            _probeGate.run(() async {
              if (session.cancelled) return;
              final candidate = await _prober.probe(
                entry.host,
                entry.port,
                source: DiscoverySource.remembered,
              );
              if (candidate != null && session.markSeen(candidate.id)) {
                emit(CandidateFound(candidate));
                _measureInBackground(candidate, out, session);
              }
            }),
        ]);
      }
      if (session.cancelled) return;

      // Aunque un servidor conocido responda, seguimos con el barrido rápido:
      // puede haber más de un emisor en casa y queremos poder comparar. Pero ya
      // hay algo reproducible en pantalla desde el primer segundo.

      // --- Fase 2: barrido rápido ----------------------------------------
      emit(PhaseChanged(ScanPhase.quickScan, detail: subnet.cidr));
      await _sweepAndProbe(
        out: out,
        session: session,
        source: DiscoverySource.quickScan,
        sweep: _scanner.sweep(
          hosts: hosts,
          ports: ScanConfig.quickPorts,
          timeout: config.quickTimeout,
          concurrency: config.quickConcurrency,
          onProgress: (done, total) => emit(ScanProgressed(done, total)),
        ),
      );
      if (session.cancelled) return;

      // --- Fase 3 y 4: solo si hizo falta --------------------------------
      if (session.foundCount == 0 || exhaustive) {
        emit(const PhaseChanged(ScanPhase.findingHosts));
        final alive = <String>[];
        final aliveStream = _scanner.findAliveHosts(
          hosts: hosts,
          onProgress: (done, total) => emit(ScanProgressed(done, total)),
        );
        await session.consume(aliveStream, alive.add);
        if (session.cancelled) return;

        // El propio dispositivo no se sirve video a sí mismo.
        alive.remove(subnet.localIp);

        if (alive.isEmpty) {
          emit(const ScanFailed(
            'No respondió ningún dispositivo en la red. Puede que el router '
            'tenga activado el aislamiento de clientes (AP isolation).',
          ));
        } else {
          emit(PhaseChanged(
            ScanPhase.wideScan,
            detail: '${alive.length} dispositivos activos',
          ));
          final quick = ScanConfig.quickPorts.toSet();
          final wide =
              ScanConfig.widePorts().where((p) => !quick.contains(p)).toList();
          await _sweepAndProbe(
            out: out,
            session: session,
            source: DiscoverySource.wideScan,
            sweep: _scanner.sweepHostMajor(
              hosts: alive,
              ports: wide,
              timeout: config.wideTimeout,
              concurrency: config.wideConcurrency,
              onProgress: (done, total) => emit(ScanProgressed(done, total)),
            ),
          );
        }
      }

      if (session.cancelled) return;
      emit(const PhaseChanged(ScanPhase.done));
    } on Object catch (error) {
      emit(ScanFailed('Fallo inesperado durante la búsqueda: $error'));
    } finally {
      // Dejamos que terminen las mediciones en curso antes de cerrar el canal.
      await session.waitForBackground();
      if (!out.isClosed) await out.close();
    }
  }

  /// Consume un barrido de puertos validando cada acierto en paralelo, sin
  /// esperar a que el barrido termine.
  Future<void> _sweepAndProbe({
    required StreamController<DiscoveryEvent> out,
    required _ScanSession session,
    required DiscoverySource source,
    required Stream<OpenPort> sweep,
  }) async {
    final probes = <Future<void>>[];

    await session.consume(sweep, (open) {
      if (!session.markProbed('${open.host}:${open.port}')) return;
      probes.add(_probeGate.run(() async {
        if (session.cancelled) return;
        final candidate =
            await _prober.probe(open.host, open.port, source: source);
        if (candidate == null || !session.markSeen(candidate.id)) return;
        if (!session.cancelled && !out.isClosed) {
          out.add(CandidateFound(candidate));
          _measureInBackground(candidate, out, session);
        }
      }));
    });

    await Future.wait(probes);
  }

  void _measureInBackground(
    StreamCandidate candidate,
    StreamController<DiscoveryEvent> out,
    _ScanSession session,
  ) {
    final future = _benchGate.run(() async {
      if (session.cancelled) return;
      final metrics = await _prober.benchmark(candidate);
      if (metrics == null || session.cancelled || out.isClosed) return;
      out.add(CandidateMeasured(candidate.copyWith(metrics: metrics)));
    });
    session.trackBackground(future);
  }
}

/// Estado mutable de una búsqueda en curso: qué se ha visto y cómo se cancela.
class _ScanSession {
  final _seenCandidates = <String>{};
  final _probedAddresses = <String>{};
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _pending = <Completer<void>>[];
  final _background = <Future<void>>[];
  bool cancelled = false;

  int get foundCount => _seenCandidates.length;

  bool markSeen(String id) => !cancelled && _seenCandidates.add(id);
  bool markProbed(String address) => _probedAddresses.add(address);

  void trackBackground(Future<void> future) {
    _background.add(future);
    future.whenComplete(() => _background.remove(future));
  }

  Future<void> waitForBackground() async {
    while (_background.isNotEmpty) {
      await Future.wait(List.of(_background));
    }
  }

  /// Escucha un stream hasta que acaba o hasta que se cancela la búsqueda.
  ///
  /// El completer se registra en [_pending] para que [cancel] pueda
  /// desbloquear la espera al instante: si el usuario pulsa "Detener" a mitad
  /// de un barrido no llega ningún dato más, y sin esto la fase se quedaría
  /// esperando para siempre a un `onDone` que nunca llega.
  Future<void> consume<T>(Stream<T> stream, void Function(T) onData) {
    if (cancelled) return Future.value();
    final completer = Completer<void>();
    _pending.add(completer);
    late StreamSubscription<T> subscription;
    subscription = stream.listen(
      (value) {
        if (cancelled) {
          subscription.cancel();
          if (!completer.isCompleted) completer.complete();
          return;
        }
        onData(value);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    _subscriptions.add(subscription);
    return completer.future.whenComplete(() => _pending.remove(completer));
  }

  void cancel() {
    cancelled = true;
    for (final completer in List.of(_pending)) {
      if (!completer.isCompleted) completer.complete();
    }
    _pending.clear();
  }

  Future<void> disposeSubscriptions() async {
    final subs = List.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subs) {
      await subscription.cancel();
    }
  }
}
