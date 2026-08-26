import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/net/lan_guard.dart';

/// Recuerda los `host:puerto` que ya sirvieron video alguna vez.
///
/// Es la optimización con mejor relación coste/beneficio de toda la app: el
/// caso normal es volver a ver algo desde el mismo teléfono, y probar tres
/// direcciones conocidas tarda ~200 ms frente a los segundos de un barrido.
class KnownHostsStore {
  static const _key = 'flux.known_hosts.v1';
  static const _maxEntries = 12;

  Future<List<({String host, int port})>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw.map(parseAddress).nonNulls.toList();
  }

  /// Guarda [host]:[port] al principio de la lista (más reciente primero).
  Future<void> remember(String host, int port) async {
    if (!LanGuard.isAllowedTarget(host)) return;
    final prefs = await SharedPreferences.getInstance();
    final entry = '$host:$port';
    final list = prefs.getStringList(_key) ?? <String>[];
    list
      ..remove(entry)
      ..insert(0, entry);
    if (list.length > _maxEntries) list.removeRange(_maxEntries, list.length);
    await prefs.setStringList(_key, list);
  }

  Future<void> forget(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? <String>[];
    list.remove('$host:$port');
    await prefs.setStringList(_key, list);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Acepta lo que el usuario pegue: `192.168.1.5:4445`,
  /// `http://192.168.1.5:4445/v.mkv`, o `192.168.1.5` (asume el 4445).
  ///
  /// Devuelve `null` si no es una IPv4 de red privada — la app no habla con
  /// nada fuera de la LAN, ni siquiera si se lo escribes a mano.
  static ({String host, int port})? parseAddress(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'http://$text';

    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    if (!LanGuard.isAllowedTarget(uri.host)) return null;

    final port = uri.hasPort ? uri.port : 4445;
    if (!LanGuard.isAllowedPort(port)) return null;
    return (host: uri.host, port: port);
  }

  /// Acepta una URL completa de Internet. Valida que el esquema sea http/https
  /// y que no sea una IP privada.
  static ({String host, int port, Uri uri})? parseExternalLink(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text'; // asume https para internet

    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (!LanGuard.isAllowedExternalUri(uri)) return null;

    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return (host: uri.host, port: port, uri: uri);
  }
}
