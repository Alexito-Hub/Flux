/// Parámetros del escaneo. Todo lo ajustable vive aquí para no tener números
/// mágicos repartidos por el código.
class ScanConfig {
  const ScanConfig({
    this.quickTimeout = const Duration(milliseconds: 450),
    this.wideTimeout = const Duration(milliseconds: 350),
    this.livenessTimeout = const Duration(milliseconds: 600),
    this.probeTimeout = const Duration(seconds: 5),
    this.quickConcurrency = 192,
    this.wideConcurrency = 256,
    this.probeConcurrency = 8,
    // Las mediciones van de una en una: dos descargas simultáneas se roban el
    // aire del Wi-Fi y ambas parecerían la mitad de rápidas de lo que son.
    this.benchmarkConcurrency = 1,
    // Medido contra el servidor real: tarda ~1 s en empezar a enviar y luego
    // sostiene ~8 MB/s. Con una muestra de 3 MB el corte por tiempo llegaba
    // durante la rampa de subida y el resultado salía 7 veces por debajo de la
    // velocidad real. 8 MB da una lectura fiel sin tardar más de dos segundos.
    this.benchmarkBytes = 8 * 1024 * 1024,
    this.benchmarkMaxDuration = const Duration(milliseconds: 4000),
  });

  /// Tiempo máximo esperando un `connect()` en la fase rápida. 450 ms es
  /// generoso para una LAN (un teléfono responde en <30 ms) pero cubre el caso
  /// de un dispositivo dormido en Wi-Fi ahorrando energía.
  final Duration quickTimeout;
  final Duration wideTimeout;
  final Duration livenessTimeout;

  /// Timeout de la validación HTTP. El servidor de Movie Plus puede tardar en
  /// abrir un MKV de 1,5 GB, así que aquí somos pacientes.
  final Duration probeTimeout;

  final int quickConcurrency;
  final int wideConcurrency;
  final int probeConcurrency;
  final int benchmarkConcurrency;

  final int benchmarkBytes;
  final Duration benchmarkMaxDuration;

  /// Fase 1. El 4445 va primero porque es el que usa Movie Plus; el resto son
  /// los puertos que usan las apps de casting/servidor HTTP más comunes.
  static const quickPorts = <int>[
    4445, 4444, 4446, 4447, 4448, 4449,
    8080, 8888, 8000, 8081, 8090, 8008,
    5000, 5001, 9000, 3000, 1234, 12345,
    7000, 8200, 32469, 2020,
  ];

  /// Fase 2. Se aplica solo a hosts que ya sabemos que están vivos, así que
  /// puede permitirse ser amplia sin dispararse en tiempo.
  static List<int> widePorts() {
    final ports = <int>{...quickPorts};
    void addRange(int from, int to) {
      for (var p = from; p <= to; p++) {
        ports.add(p);
      }
    }

    addRange(4400, 4500); // familia de Movie Plus / Web Video Caster
    addRange(8000, 8100); // servidores HTTP embebidos
    addRange(8800, 8900);
    addRange(5000, 5010);
    addRange(9000, 9010);
    addRange(3000, 3010);
    addRange(1230, 1240);
    addRange(12340, 12350);
    addRange(7000, 7010);
    addRange(10000, 10010);
    addRange(32768, 32790); // rango efímero típico de Android
    addRange(49152, 49180); // rango efímero de UPnP/DLNA
    ports.addAll([8443, 8181, 6000, 6666, 2222, 8123, 5353, 1900]);
    return ports.toList()..sort();
  }

  /// Puerto que casi con total seguridad está cerrado. Si el host contesta con
  /// un RST inmediato, está vivo; si no contesta nada, no existe.
  static const livenessProbePort = 9;
}
