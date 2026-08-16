import '../../../core/utils/formatters.dart';

/// Cómo llegamos a este stream. Cambia el orden en pantalla: lo que ya
/// funcionó ayer se prueba y se muestra antes que un hallazgo nuevo.
enum DiscoverySource { remembered, quickScan, wideScan, manual }

/// Medición de rendimiento de un stream concreto.
///
/// TTFB y throughput se guardan por separado a propósito: el servidor de Movie
/// Plus tarda ~1,5 s en responder al primer `Range` (tiene que abrir y buscar
/// dentro del MKV) pero luego transfiere rápido. Un único número "velocidad"
/// mezclaría ambas cosas y haría parecer lento un stream que va perfecto.
class StreamMetrics {
  const StreamMetrics({
    required this.timeToFirstByte,
    required this.bytesPerSecond,
    required this.seekTimeToFirstByte,
  });

  /// Latencia hasta el primer byte leyendo desde el inicio del archivo.
  final Duration timeToFirstByte;

  /// Throughput sostenido durante la lectura de prueba.
  final double bytesPerSecond;

  /// Latencia del primer byte tras saltar a mitad del archivo: esto es lo que
  /// notarás al arrastrar la barra de progreso.
  final Duration seekTimeToFirstByte;

  /// 0..100. Penaliza la latencia de salto porque es lo que se percibe como
  /// "va a trompicones", y premia el ancho de banda de forma logarítmica
  /// (pasar de 2 a 4 MB/s importa; de 40 a 80 ya no lo notas).
  double get score {
    final mbps = bytesPerSecond / (1024 * 1024);
    final bandwidth = (mbps <= 0) ? 0.0 : (30 * (1 + (mbps / 8)).clamp(0, 3));
    final seekMs = seekTimeToFirstByte.inMilliseconds;
    final latency = (40 * (1 - (seekMs / 4000))).clamp(0, 40).toDouble();
    final startMs = timeToFirstByte.inMilliseconds;
    final startup = (30 * (1 - (startMs / 3000))).clamp(0, 30).toDouble();
    return (bandwidth + latency + startup).clamp(0, 100).toDouble();
  }

  /// Estimación honesta: ¿aguanta la reproducción sin cortes?
  /// Un 1080p x264 ronda los 1,2 MB/s; un remux 4K puede pedir 8 MB/s.
  String get verdict {
    final mbps = bytesPerSecond / (1024 * 1024);
    if (mbps >= 6) return 'Excelente';
    if (mbps >= 2.5) return 'Muy bueno';
    if (mbps >= 1.2) return 'Suficiente';
    if (mbps > 0) return 'Justo';
    return 'Sin medir';
  }
}

/// Un servidor de video encontrado en la LAN y ya validado.
class StreamCandidate {
  const StreamCandidate({
    required this.host,
    required this.port,
    required this.source,
    this.fileName,
    this.contentType,
    this.sizeBytes,
    this.seekable = false,
    this.isLiveStream = false,
    this.lastModified,
    this.metrics,
    this.discoveredAt,
  });

  final String host;
  final int port;
  final DiscoverySource source;

  /// Nombre real del archivo, sacado de `Content-Disposition`. Es el dato que
  /// convierte una lista de IPs en una lista de películas.
  final String? fileName;

  final String? contentType;
  final int? sizeBytes;

  /// `Accept-Ranges: bytes`. Sin esto no hay adelantar ni retroceder.
  final bool seekable;

  /// HLS/DASH: sin tamaño y sin seek absoluto.
  final bool isLiveStream;

  final DateTime? lastModified;

  final StreamMetrics? metrics;
  final DateTime? discoveredAt;

  String get address => '$host:$port';
  Uri get uri => Uri.parse('http://$host:$port/');
  String get id => address;

  /// Identifica **qué archivo** hay detrás del puerto, no el puerto.
  ///
  /// Cuando cambias de capítulo en Movie Plus, la dirección sigue siendo la
  /// misma pero el contenido es otro. Comparar esta huella es lo que permite
  /// darse cuenta; comparar la URL no serviría de nada.
  String get fingerprint => [
        fileName ?? '',
        sizeBytes ?? 0,
        lastModified?.millisecondsSinceEpoch ?? 0,
      ].join('|');

  bool isSameContentAs(StreamCandidate other) =>
      fingerprint == other.fingerprint;

  /// Lo que se lee en la tarjeta: el nombre del episodio si lo sabemos, si no
  /// la dirección.
  String get title =>
      fileName == null ? address : Fmt.prettyTitle(fileName!);

  bool get hasTitle => fileName != null;

  /// Etiqueta corta del contenedor: MKV, MP4, AVI...
  String? get container {
    final name = fileName;
    if (name != null) {
      final dot = name.lastIndexOf('.');
      if (dot > 0 && name.length - dot <= 5) {
        return name.substring(dot + 1).toUpperCase();
      }
    }
    return switch (contentType) {
      final t? when t.contains('matroska') => 'MKV',
      final t? when t.contains('mp4') => 'MP4',
      final t? when t.contains('webm') => 'WEBM',
      final t? when t.contains('mpegurl') => 'HLS',
      final t? when t.contains('x-msvideo') => 'AVI',
      _ => null,
    };
  }

  StreamCandidate copyWith({
    StreamMetrics? metrics,
    DiscoverySource? source,
    String? fileName,
  }) {
    return StreamCandidate(
      host: host,
      port: port,
      source: source ?? this.source,
      fileName: fileName ?? this.fileName,
      contentType: contentType,
      sizeBytes: sizeBytes,
      seekable: seekable,
      isLiveStream: isLiveStream,
      lastModified: lastModified,
      metrics: metrics ?? this.metrics,
      discoveredAt: discoveredAt,
    );
  }

  @override
  bool operator ==(Object other) => other is StreamCandidate && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
