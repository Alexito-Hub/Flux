import '../../../core/net/lan_guard.dart';

/// Una subred /24 candidata a ser escaneada, con la interfaz que la expone.
///
/// Una máquina Windows normal tiene varias: Wi-Fi, Ethernet, y las virtuales de
/// WSL / Hyper-V / VMware / Docker. Escanear la equivocada es el fallo más
/// común de este tipo de herramientas, así que las puntuamos y ordenamos.
class LanSubnet {
  const LanSubnet({
    required this.interfaceName,
    required this.localIp,
    required this.score,
  });

  final String interfaceName;

  /// IP de esta máquina dentro de la subred, p. ej. `192.168.1.4`.
  final String localIp;

  /// Mayor es mejor. Ver [scoreInterface].
  final int score;

  /// `192.168.1` — los tres primeros octetos.
  String get prefix {
    final parts = localIp.split('.');
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  String get cidr => '$prefix.0/24';

  /// Los 254 hosts asignables de la subred, empezando por los más probables:
  /// los teléfonos suelen caer en el rango bajo del DHCP.
  List<String> hosts() => [for (var i = 1; i <= 254; i++) '$prefix.$i'];

  bool get isVirtual => score < 0;

  /// Heurística de "esta es la red de verdad".
  static int scoreInterface(String name, String ip) {
    final n = name.toLowerCase();
    var score = 0;

    const virtualMarkers = [
      'vethernet', 'wsl', 'hyper-v', 'vmware', 'virtualbox', 'vbox',
      'docker', 'tap-', 'tunnel', 'bluetooth', 'loopback', 'npcap',
      'zerotier', 'tailscale', 'radmin', 'hamachi', 'utun', 'vpn',
    ];
    for (final marker in virtualMarkers) {
      if (n.contains(marker)) score -= 1000;
    }

    if (n.contains('wlan') || n.contains('wi-fi') || n.contains('wifi')) {
      score += 100;
    } else if (n.startsWith('eth') || n.contains('ethernet')) {
      score += 60;
    } else if (n.startsWith('en') || n.startsWith('rmnet')) {
      score += 40;
    }

    // 192.168.x.x es la red doméstica típica; 172.16/12 es donde viven casi
    // todos los adaptadores virtuales, así que pesa menos.
    if (ip.startsWith('192.168.')) {
      score += 30;
    } else if (ip.startsWith('10.')) {
      score += 15;
    }

    // Ser el `.1` de la subred significa que normalmente eres tú el router de
    // esa red — señal clásica de un switch virtual, no de la LAN de casa.
    if (ip.endsWith('.1')) score -= 25;

    return score;
  }

  static LanSubnet? tryCreate(String interfaceName, String ip) {
    if (!LanGuard.isPrivate(ip)) return null;
    return LanSubnet(
      interfaceName: interfaceName,
      localIp: ip,
      score: scoreInterface(interfaceName, ip),
    );
  }

  @override
  bool operator ==(Object other) => other is LanSubnet && other.prefix == prefix;

  @override
  int get hashCode => prefix.hashCode;

  @override
  String toString() => '$cidr ($interfaceName)';
}
