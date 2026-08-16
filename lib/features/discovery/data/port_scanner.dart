import 'dart:async';
import 'dart:io';

import '../../../core/net/lan_guard.dart';
import 'parallel.dart';
import 'scan_config.dart';

/// Un puerto abierto encontrado en la LAN.
class OpenPort {
  const OpenPort(this.host, this.port);
  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

/// Escáner TCP tipo nmap, en Dart puro.
class PortScanner {
  const PortScanner({this.config = const ScanConfig()});

  final ScanConfig config;

  /// Barrido hosts × puertos.
  ///
  /// El orden es **puerto-mayor**: primero el puerto 4445 en los 254 hosts,
  /// luego el siguiente puerto. Así, en el caso normal (Movie Plus en su puerto
  /// de siempre) el stream aparece en pantalla en el primer segundo, sin
  /// esperar a que termine el resto del barrido.
  Stream<OpenPort> sweep({
    required List<String> hosts,
    required List<int> ports,
    required Duration timeout,
    required int concurrency,
    void Function(int done, int total)? onProgress,
  }) {
    final targets = <OpenPort>[
      for (final port in ports)
        for (final host in hosts)
          if (LanGuard.isAllowedTarget(host)) OpenPort(host, port),
    ];

    return parallelMap<OpenPort, OpenPort>(
      targets,
      concurrency,
      (target) => _tryConnect(target, timeout),
      onProgress: (done) => onProgress?.call(done, targets.length),
    );
  }

  /// Barrido host-mayor: agota todos los puertos de un host antes de pasar al
  /// siguiente. Es lo que quieres en la fase amplia, donde ya sabes qué pocos
  /// hosts están vivos y quieres resultados por dispositivo.
  Stream<OpenPort> sweepHostMajor({
    required List<String> hosts,
    required List<int> ports,
    required Duration timeout,
    required int concurrency,
    void Function(int done, int total)? onProgress,
  }) {
    final targets = <OpenPort>[
      for (final host in hosts)
        if (LanGuard.isAllowedTarget(host))
          for (final port in ports) OpenPort(host, port),
    ];

    return parallelMap<OpenPort, OpenPort>(
      targets,
      concurrency,
      (target) => _tryConnect(target, timeout),
      onProgress: (done) => onProgress?.call(done, targets.length),
    );
  }

  /// Detección de hosts vivos sin ICMP (no hay ping en Dart puro, y en Android
  /// tampoco habría permisos para raw sockets).
  ///
  /// El truco: conectar a un puerto que seguro está cerrado. Un dispositivo
  /// encendido responde `RST` al instante → "connection refused" → está vivo.
  /// Una IP sin nadie detrás no responde nada → timeout → no existe.
  /// Reduce la fase amplia de 254 hosts a los 5-15 reales de tu casa.
  Stream<String> findAliveHosts({
    required List<String> hosts,
    void Function(int done, int total)? onProgress,
  }) {
    return parallelMap<String, String>(
      hosts.where(LanGuard.isAllowedTarget),
      config.wideConcurrency,
      (host) => _isAlive(host),
      onProgress: (done) => onProgress?.call(done, hosts.length),
    );
  }

  Future<OpenPort?> _tryConnect(OpenPort target, Duration timeout) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        target.host,
        target.port,
        timeout: timeout,
      );
      return target;
    } on SocketException {
      return null;
    } on Object {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  Future<String?> _isAlive(String host) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        ScanConfig.livenessProbePort,
        timeout: config.livenessTimeout,
      );
      // Improbable, pero un puerto 9 abierto también prueba que está vivo.
      return host;
    } on SocketException catch (e) {
      return _isRefused(e) ? host : null;
    } on Object {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// `ECONNREFUSED` = 111 en Linux/Android, `WSAECONNREFUSED` = 10061 en
  /// Windows. Comprobamos también el texto por si acaso.
  static bool _isRefused(SocketException e) {
    final code = e.osError?.errorCode;
    if (code == 111 || code == 10061 || code == 61) return true;
    final message = (e.osError?.message ?? e.message).toLowerCase();
    return message.contains('refused');
  }
}
