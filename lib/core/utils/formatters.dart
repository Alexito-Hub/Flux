/// Formateo humano de duraciones, tamaños y velocidades.
abstract final class Fmt {
  /// 1:23:45 o 23:45 según haga falta. Nunca muestra horas si no las hay.
  static String duration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  /// Diferencia con signo, para el indicador de salto (+10s / -10s).
  static String signedSeconds(int seconds) =>
      seconds >= 0 ? '+${seconds}s' : '${seconds}s';

  static String bytes(int? value) {
    if (value == null || value <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final decimals = size >= 100 || unit == 0 ? 0 : 1;
    return '${size.toStringAsFixed(decimals)} ${units[unit]}';
  }

  /// Velocidad en MB/s, la unidad que importa para saber si un stream aguanta.
  static String speed(double? bytesPerSecond) {
    if (bytesPerSecond == null || bytesPerSecond <= 0) return '—';
    final mbps = bytesPerSecond / (1024 * 1024);
    if (mbps >= 10) return '${mbps.toStringAsFixed(0)} MB/s';
    if (mbps >= 1) return '${mbps.toStringAsFixed(1)} MB/s';
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }

  static String millis(Duration? d) {
    if (d == null) return '—';
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
  }

  /// Limpia el nombre que llega en Content-Disposition para mostrarlo como
  /// título: quita la extensión y los puntos/guiones bajos de los releases.
  static String prettyTitle(String fileName) {
    var name = fileName.trim();
    final dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 5) name = name.substring(0, dot);
    name = name.replaceAll(RegExp(r'[._]+'), ' ').replaceAll(RegExp(r'\s+'), ' ');
    return name.trim();
  }
}
