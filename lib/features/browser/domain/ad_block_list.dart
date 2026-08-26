import 'ad_domains.dart';

/// Bloqueador ligero de anuncios basado en lista de dominios conocidos.
class AdBlockList {
  AdBlockList({List<String>? initialDomains}) {
    if (initialDomains != null) {
      _domains.addAll(initialDomains);
    } else {
      _domains.addAll(defaultAdDomains);
    }
  }

  final Set<String> _domains = {};

  /// Agrega nuevos dominios a la lista de bloqueo.
  void addDomains(List<String> domains) {
    _domains.addAll(domains);
  }

  /// Verifica si una URL dada pertenece a un dominio publicitario bloqueado.
  bool isAdUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    
    // Check for exact matches or subdomains
    for (final domain in _domains) {
      if (host == domain || host.endsWith('.$domain')) {
        return true;
      }
    }
    return false;
  }
}
