import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../discovery/data/subnet_detector.dart';
import 'receiver_service.dart';

class TVDevice {
  final String ip;
  final String type; // 'webos' or 'android_tv'
  final String name;

  TVDevice({required this.ip, required this.type, required this.name});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TVDevice &&
          runtimeType == other.runtimeType &&
          ip == other.ip &&
          type == other.type;

  @override
  int get hashCode => ip.hashCode ^ type.hashCode;
}

final tvDiscoveryProvider = NotifierProvider<TVDiscoveryNotifier, List<TVDevice>>(() {
  return TVDiscoveryNotifier();
});

class TVDiscoveryNotifier extends Notifier<List<TVDevice>> {
  @override
  List<TVDevice> build() => [];

  Timer? _scanTimer;
  RawDatagramSocket? _udpSocket;

  void startDiscovery() {
    _scan();
    // Re-escaneo periódico
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(const Duration(seconds: 15), (_) => _scan());
  }

  void stopDiscovery() {
    _scanTimer?.cancel();
    _udpSocket?.close();
  }

  Future<void> _scan() async {
    final subnet = await SubnetDetector().preferred();
    if (subnet == null) return;

    // 1. UDP Broadcast para Android TVs (Flux Receivers)
    _discoverAndroidTVs();

    // 2. TCP Port Scan para webOS (puerto 3000 SSAP)
    _discoverWebOSTVs(subnet.hosts());
  }

  Future<void> _discoverAndroidTVs() async {
    try {
      if (_udpSocket == null) {
        _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _udpSocket!.broadcastEnabled = true;
        _udpSocket!.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            Datagram? dg = _udpSocket!.receive();
            if (dg != null) {
              final msg = utf8.decode(dg.data);
              if (msg.startsWith('FLUX_RECEIVER:')) {
                final parts = msg.split(':');
                // parts[0] = FLUX_RECEIVER
                // parts[1] = port (8080)
                // parts[2] = OS (optional)
                // parts[3] = instanceId (optional)
                String os = parts.length > 2 ? parts[2] : '';
                String instanceId = parts.length > 3 ? parts[3] : '';
                
                // Evitar agregarnos a nosotros mismos
                if (instanceId == appInstanceId) return;

                String deviceName = 'Flux App';
                if (os.isNotEmpty) {
                  // Capitalize OS name
                  os = os[0].toUpperCase() + os.substring(1);
                  deviceName = 'Flux ($os)';
                } else {
                  deviceName = 'Flux TV Box';
                }

                _addDevice(TVDevice(
                  ip: dg.address.address,
                  type: 'flux_app',
                  name: deviceName,
                ));
              }
            }
          }
        });
      }
      
      final msg = utf8.encode('FLUX_DISCOVER');
      _udpSocket!.send(msg, InternetAddress('255.255.255.255'), 8081);
    } catch (e) {
      debugPrint('[Flux] Error en UDP discovery: $e');
    }
  }

  Future<void> _discoverWebOSTVs(Iterable<String> hosts) async {
    for (final host in hosts) {
      Socket.connect(host, 3000, timeout: const Duration(milliseconds: 400)).then((socket) {
        socket.destroy();
        _addDevice(TVDevice(
          ip: host,
          type: 'webos',
          name: 'LG webOS TV',
        ));
      }).catchError((_) {
        // Ignorar
      });
    }
  }

  void _addDevice(TVDevice device) {
    if (!state.contains(device)) {
      state = [...state, device];
    }
  }
}
