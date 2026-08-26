import 'dart:io';

/// Frontera de seguridad de la app: Flux **solo** habla con direcciones IPv4
/// privadas (RFC 1918) o loopback. Cualquier host fuera de eso se rechaza aquí,
/// antes de abrir un socket, antes de seguir una redirección y antes de
/// reproducir. No hay forma de que el escáner "se escape" a Internet.
abstract final class LanGuard {
  /// Redes privadas permitidas, en forma (red, bits de máscara).
  static const _privateBlocks = <({int network, int maskBits})>[
    (network: 0x0A000000, maskBits: 8), // 10.0.0.0/8
    (network: 0xAC100000, maskBits: 12), // 172.16.0.0/12
    (network: 0xC0A80000, maskBits: 16), // 192.168.0.0/16
  ];

  /// Convierte "192.168.1.5" en su entero de 32 bits. `null` si no es IPv4.
  static int? toInt(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    var value = 0;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return null;
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return null;
      value = (value << 8) | octet;
    }
    return value;
  }

  static String fromInt(int value) =>
      '${(value >> 24) & 0xFF}.${(value >> 16) & 0xFF}.'
      '${(value >> 8) & 0xFF}.${value & 0xFF}';

  static bool isLoopback(String ip) => ip.startsWith('127.');

  /// 169.254.0.0/16: autoconfiguración. Es "local" pero nunca lleva un stream
  /// útil, y en Windows aparece en interfaces Bluetooth/desconectadas.
  static bool isLinkLocal(String ip) => ip.startsWith('169.254.');

  /// ¿Es una IPv4 privada enrutable dentro de la LAN?
  static bool isPrivate(String ip) {
    final value = toInt(ip);
    if (value == null) return false;
    if (isLinkLocal(ip)) return false;
    for (final block in _privateBlocks) {
      final mask = block.maskBits == 0 ? 0 : (0xFFFFFFFF << (32 - block.maskBits)) & 0xFFFFFFFF;
      if ((value & mask) == block.network) return true;
    }
    return false;
  }

  /// Lo que la app acepta como destino: LAN privada o la propia máquina.
  static bool isAllowedTarget(String host) =>
      isPrivate(host) || isLoopback(host);

  /// Puerto válido y no reservado a servicios de sistema que nunca sirven video.
  static bool isAllowedPort(int port) => port > 0 && port <= 65535;

  /// Verificación final antes de abrir una URL en el reproductor.
  /// Rechaza esquemas raros (file://, data://) y hosts fuera de la LAN.
  static bool isAllowedUri(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    if (!isAllowedTarget(uri.host)) return false;
    return isAllowedPort(uri.hasPort ? uri.port : 80);
  }

  static bool isPrivateAddress(InternetAddress address) =>
      address.type == InternetAddressType.IPv4 && isPrivate(address.address);

  /// Valida una URI proveniente de un origen externo (enlace pegado a mano,
  /// navegador embebido). A diferencia de [isAllowedUri], **acepta** hosts
  /// públicos — pero bloquea esquemas peligrosos y direcciones que intentan
  /// colarse como externas siendo realmente locales.
  static bool isAllowedExternalUri(Uri uri) {
    // Solo HTTP/HTTPS — bloquea file://, data://, javascript://, etc.
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    if (!isAllowedPort(uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80))) {
      return false;
    }
    // Rechazar IPs privadas disfrazadas de externas: si alguien pega
    // http://192.168.1.5/video.mp4 como "enlace externo", debe usar el
    // flujo manual LAN en su lugar.
    if (isPrivate(uri.host) || isLoopback(uri.host) || isLinkLocal(uri.host)) {
      return false;
    }
    return true;
  }
}
