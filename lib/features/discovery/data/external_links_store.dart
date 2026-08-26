import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/stream_candidate.dart';

/// Persistencia de enlaces externos pegados a mano.
/// 
/// Se guardan por separado de los hosts LAN porque la fase 'remembered'
/// del escaneo LAN no debe intentar conectarse a servidores de Internet.
class ExternalLinksStore {
  static const _key = 'flux.external_links.v1';
  static const _maxEntries = 20;

  Future<List<StreamCandidate>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key);
    if (jsonList == null || jsonList.isEmpty) return [];

    final result = <StreamCandidate>[];
    for (final jsonStr in jsonList) {
      try {
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        final urlString = data['url'] as String?;
        if (urlString == null) continue;

        final uri = Uri.tryParse(urlString);
        if (uri == null) continue;

        final host = uri.host;
        final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

        result.add(StreamCandidate(
          host: host,
          port: port,
          source: DiscoverySource.remembered, // para que salgan primero si hiciéramos una lista separada
          explicitUri: uri,
          fileName: data['title'] as String?,
          contentType: data['contentType'] as String?,
          discoveredAt: data['discoveredAt'] != null
              ? DateTime.tryParse(data['discoveredAt'] as String)
              : null,
        ));
      } catch (_) {
        // Ignorar entradas corruptas
      }
    }
    return result;
  }

  Future<void> remember(StreamCandidate candidate) async {
    if (!candidate.isExternal) return;
    
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key) ?? [];

    final urlString = candidate.explicitUri!.toString();
    
    // Quitar si ya existe para ponerlo al principio
    jsonList.removeWhere((str) {
      try {
        final data = jsonDecode(str) as Map<String, dynamic>;
        return data['url'] == urlString;
      } catch (_) {
        return false;
      }
    });

    final newEntry = {
      'url': urlString,
      'title': candidate.fileName,
      'contentType': candidate.contentType,
      'discoveredAt': DateTime.now().toIso8601String(),
    };

    jsonList.insert(0, jsonEncode(newEntry));

    if (jsonList.length > _maxEntries) {
      jsonList.removeRange(_maxEntries, jsonList.length);
    }

    await prefs.setStringList(_key, jsonList);
  }

  Future<void> forget(Uri uri) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = prefs.getStringList(_key);
    if (jsonList == null || jsonList.isEmpty) return;

    final urlString = uri.toString();
    jsonList.removeWhere((str) {
      try {
        final data = jsonDecode(str) as Map<String, dynamic>;
        return data['url'] == urlString;
      } catch (_) {
        return false;
      }
    });

    await prefs.setStringList(_key, jsonList);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
