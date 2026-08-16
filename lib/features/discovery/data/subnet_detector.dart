import 'dart:io';

import '../domain/lan_subnet.dart';

/// Descubre en qué red está esta máquina.
class SubnetDetector {
  const SubnetDetector();

  /// Devuelve las subredes /24 privadas visibles, ordenadas de más a menos
  /// probable. Las virtuales (WSL, Hyper-V, VPN...) quedan al final con
  /// puntuación negativa: siguen ahí por si el usuario las quiere, pero nunca
  /// se escanean por defecto.
  Future<List<LanSubnet>> detect() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );

    final byPrefix = <String, LanSubnet>{};
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final subnet = LanSubnet.tryCreate(interface.name, address.address);
        if (subnet == null) continue;
        // Si dos interfaces comparten prefijo nos quedamos con la mejor.
        final existing = byPrefix[subnet.prefix];
        if (existing == null || subnet.score > existing.score) {
          byPrefix[subnet.prefix] = subnet;
        }
      }
    }

    final subnets = byPrefix.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return subnets;
  }

  /// La red que se escanea si el usuario no elige otra.
  Future<LanSubnet?> preferred() async {
    final subnets = await detect();
    if (subnets.isEmpty) return null;
    final real = subnets.where((s) => !s.isVirtual);
    return real.isNotEmpty ? real.first : subnets.first;
  }
}
