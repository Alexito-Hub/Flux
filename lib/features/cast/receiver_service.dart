import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multicast_dns/multicast_dns.dart';

final String appInstanceId = DateTime.now().millisecondsSinceEpoch.toString();

final castReceiverProvider = Provider<CastReceiverService>((ref) {
  return CastReceiverService();
});

class CastReceiverService {
  MDnsClient? _mdns;
  HttpServer? _server;
  RawDatagramSocket? _udpSocket;
  Function(String host, int port)? onPlayCommand;

  Future<void> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      debugPrint('[Flux] CastReceiverService escuchando en puerto ${_server!.port}');
      
      _server!.listen((HttpRequest request) async {
        // Soporte básico CORS
        if (request.method == 'OPTIONS') {
           request.response
            ..headers.add('Access-Control-Allow-Origin', '*')
            ..headers.add('Access-Control-Allow-Methods', 'POST, OPTIONS')
            ..headers.add('Access-Control-Allow-Headers', 'Content-Type')
            ..statusCode = HttpStatus.ok;
           await request.response.close();
           return;
        }

        if (request.method == 'POST' && request.uri.path == '/launch') {
          final content = await utf8.decoder.bind(request).join();
          try {
            final data = jsonDecode(content);
            final host = data['host'] as String?;
            final port = data['port'] as int?;
            
            if (host != null && port != null && onPlayCommand != null) {
              onPlayCommand!(host, port);
              request.response
                ..headers.add('Access-Control-Allow-Origin', '*')
                ..statusCode = HttpStatus.ok
                ..write('{"status": "ok"}');
            } else {
              request.response
                ..headers.add('Access-Control-Allow-Origin', '*')
                ..statusCode = HttpStatus.badRequest
                ..write('{"error": "invalid payload"}');
            }
          } catch (e) {
            request.response
              ..headers.add('Access-Control-Allow-Origin', '*')
              ..statusCode = HttpStatus.internalServerError
              ..write('{"error": "failed to parse JSON"}');
          }
        } else if (request.method == 'GET' && request.uri.path == '/info') {
           // Endpoint para descubrimiento manual
           request.response
              ..headers.add('Access-Control-Allow-Origin', '*')
              ..statusCode = HttpStatus.ok
              ..write('{"app": "Flux", "type": "receiver"}');
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..write('Not found');
        }
        await request.response.close();
      });
    } catch (e) {
      debugPrint('[Flux] Error al iniciar servidor HTTP para Cast: $e');
    }

    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 8081);
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _udpSocket!.receive();
          if (dg != null) {
            final msg = utf8.decode(dg.data);
            if (msg == 'FLUX_DISCOVER') {
              // Responder al emisor que somos un receptor Flux (incluyendo OS e instanceId)
              final reply = utf8.encode('FLUX_RECEIVER:${_server?.port ?? 8080}:${Platform.operatingSystem}:$appInstanceId');
              _udpSocket!.send(reply, dg.address, dg.port);
            }
          }
        }
      });
      debugPrint('[Flux] CastReceiverService escuchando UDP discovery en puerto 8081');
    } catch (e) {
      debugPrint('[Flux] Error al iniciar UDP discovery: $e');
    }
  }

  void stop() {
    _server?.close(force: true);
    _udpSocket?.close();
    _mdns?.stop();
  }
}
