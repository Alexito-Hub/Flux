import '../../../core/utils/formatters.dart';

/// Cómo llegamos a este stream. Cambia el orden en pantalla: lo que ya
/// funcionó ayer se prueba y se muestra antes que un hallazgo nuevo.
enum DiscoverySource {
  remembered,
  quickScan,
  wideScan,
  manual,

  /// El usuario pegó una URL externa a mano.
  directLink,

  /// Se detectó dentro del navegador embebido.
  webBrowser,
}

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

/// Un servidor de video encontrado en la LAN y ya validado, o un enlace
/// externo / video detectado en el navegador embebido.
class StreamCandidate {
  const StreamCandidate({
    required this.host,
    required this.port,
    required this.source,
    this.explicitUri,
    this.fileName,
    this.contentType,
    this.sizeBytes,
    this.seekable = false,
    this.isLiveStream = false,
    this.lastModified,
    this.metrics,
    this.discoveredAt,
    this.httpHeaders,
  });

  final String host;
  final int port;
  final DiscoverySource source;

  /// URI completa para orígenes externos (directLink, webBrowser). Cuando está
  /// presente, [uri] la devuelve tal cual con su scheme, path y query
  /// originales en vez de reconstruir `http://host:port/`.
  ///
  /// [host] y [port] siguen poblados (parseados desde esta URI) porque otras
  /// partes del código (casting a webOS/Flux receiver, dirección de red) los
  /// siguen necesitando.
  final Uri? explicitUri;

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

  /// Cabeceras HTTP (Referer, User-Agent) necesarias para reproducir el stream.
  final Map<String, String>? httpHeaders;

  /// `true` cuando el origen es un enlace externo o un video del navegador
  /// embebido — no LAN.
  bool get isExternal => explicitUri != null;

  String get address => '$host:$port';

  /// Para orígenes LAN devuelve `http://host:port/`; para externos devuelve
  /// la [explicitUri] original con su scheme, path y query.
  Uri get uri => explicitUri ?? Uri.parse('http://$host:$port/');

  /// Los candidatos LAN se identifican por `host:port`; los externos por su
  /// URL completa, ya que varios videos pueden venir del mismo host.
  String get id => explicitUri?.toString() ?? address;

  /// Identifica **qué archivo** hay detrás del puerto, no el puerto.
  ///
  /// Cuando cambias de capítulo en Movie Plus, la dirección sigue siendo la
  /// misma pero el contenido es otro. Comparar esta huella es lo que permite
  /// darse cuenta; comparar la URL no serviría de nada.
  ///
  /// Para orígenes externos sin metadata LAN, la propia URL sirve como huella.
  String get fingerprint {
    if (isExternal &&
        fileName == null &&
        sizeBytes == null &&
        lastModified == null) {
      return explicitUri.toString();
    }
    return [
      fileName ?? '',
      sizeBytes ?? 0,
      lastModified?.millisecondsSinceEpoch ?? 0,
    ].join('|');
  }

  bool isSameContentAs(StreamCandidate other) =>
      fingerprint == other.fingerprint;

  /// Lo que se lee en la tarjeta: el nombre del episodio si lo sabemos, si no
  /// la dirección.
  String get title {
    if (fileName != null) return Fmt.prettyTitle(fileName!);
    if (isExternal) {
      // Para URLs externas, intentar extraer un nombre legible del path.
      final pathSegments = explicitUri!.pathSegments;
      if (pathSegments.isNotEmpty) {
        final last = pathSegments.last;
        if (last.isNotEmpty) return Fmt.prettyTitle(last);
      }
      return explicitUri!.host;
    }
    return address;
  }

  bool get hasTitle => fileName != null || isExternal;

  /// Etiqueta corta del contenedor: MKV, MP4, AVI...
  String? get container {
    // Intentar desde el nombre de archivo.
    final name = fileName;
    if (name != null) {
      final dot = name.lastIndexOf('.');
      if (dot > 0 && name.length - dot <= 5) {
        return name.substring(dot + 1).toUpperCase();
      }
    }
    // Intentar desde el path de la URI explícita.
    if (isExternal && name == null) {
      final path = explicitUri!.path;
      final dot = path.lastIndexOf('.');
      if (dot > 0 && path.length - dot <= 5) {
        final ext = path.substring(dot + 1).toUpperCase();
        if (const {'MP4', 'MKV', 'WEBM', 'AVI', 'MOV', 'FLV', 'TS', 'M3U8', 'MPD'}
            .contains(ext)) {
          return ext;
        }
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
    Uri? explicitUri,
    StreamMetrics? metrics,
    DiscoverySource? source,
    String? fileName,
    Map<String, String>? httpHeaders,
  }) {
    return StreamCandidate(
      host: host,
      port: port,
      source: source ?? this.source,
      explicitUri: explicitUri ?? this.explicitUri,
      fileName: fileName ?? this.fileName,
      contentType: contentType,
      sizeBytes: sizeBytes,
      seekable: seekable,
      isLiveStream: isLiveStream,
      lastModified: lastModified,
      metrics: metrics ?? this.metrics,
      discoveredAt: discoveredAt,
      httpHeaders: httpHeaders ?? this.httpHeaders,
    );
  }

  @override
  bool operator ==(Object other) => other is StreamCandidate && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
