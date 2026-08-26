import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class VideoVerifier {
  /// Verifica si una URL responde con un estado de éxito (2xx o 3xx) y es accesible.
  /// Se usa una petición HEAD o un GET parcial (Range bytes=0-1) para ahorrar ancho de banda.
  static Future<bool> verifyUrl(String url, {String? referer}) async {
    if (url.startsWith('blob:') || url.startsWith('data:')) return false;
    
    try {
      final uri = Uri.parse(url);
      final headers = <String, String>{
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        if (referer != null) 'Referer': referer,
        'Range': 'bytes=0-1', // Solo pedimos 2 bytes para comprobar disponibilidad
      };

      // Primero intentamos con GET parcial, ya que muchos servidores de video rechazan HEAD.
      final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 5));
      
      if (response.statusCode >= 200 && response.statusCode < 400) {
        return true;
      }
      
      // Fallback a HEAD si el GET con Range falló (p.ej. 400 Bad Request por no soportar rangos)
      if (response.statusCode == 400 || response.statusCode == 405) {
         final headResponse = await http.head(uri, headers: {
            'User-Agent': headers['User-Agent']!,
            if (referer != null) 'Referer': referer,
         }).timeout(const Duration(seconds: 5));
         
         return headResponse.statusCode >= 200 && headResponse.statusCode < 400;
      }

      return false;
    } catch (e) {
      debugPrint('[VideoVerifier] Error verificando $url: $e');
      return false;
    }
  }
}
