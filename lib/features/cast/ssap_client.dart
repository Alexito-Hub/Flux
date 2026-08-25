import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SSAPClient {
  final String ip;
  final int port;
  WebSocket? _socket;
  bool _isConnected = false;

  SSAPClient({required this.ip, this.port = 3000});

  Future<void> connect() async {
    try {
      _socket = await WebSocket.connect('ws://$ip:$port');
      _isConnected = true;
      
      _socket!.listen((data) {
        final Map<String, dynamic> response =
            jsonDecode(data as String) as Map<String, dynamic>;
        debugPrint('[Flux] SSAP Message: $response');
        if (response['type'] == 'registered') {
          final key = (response['payload'] as Map<String, dynamic>?)?['client-key']
              as String?;
          if (key != null) {
            SharedPreferences.getInstance().then(
              (p) => p.setString('webos_client_key_$ip', key),
            );
          }
        }
      }, onDone: () {
        _isConnected = false;
      }, onError: (e) {
        _isConnected = false;
      });
      
      await _register();
    } catch (e) {
      _isConnected = false;
      debugPrint('[Flux] Error conectando al TV webOS en $ip:$port: $e');
    }
  }

  Future<void> _register() async {
    final prefs = await SharedPreferences.getInstance();
    final clientKey = prefs.getString('webos_client_key_$ip');

    final payload = {
      'type': 'register',
      'id': 'register_0',
      'payload': {
        'forcePairing': false,
        'manifest': {
          'manifestVersion': 1,
          'appVersion': '1.0.0',
          'signatures': [
            {
              'signatureVersion': 1,
              'signature': 'Flux'
            }
          ],
          'permissions': [
            'LAUNCH',
            'LAUNCH_WEBAPP',
            'APP_TO_APP',
            'CLOSE',
            'TEST_OPEN',
            'TEST_PROTECTED',
            'CONTROL_AUDIO',
            'CONTROL_DISPLAY',
            'CONTROL_INPUT_JOYSTICK',
            'CONTROL_INPUT_MEDIA_RECORDING',
            'CONTROL_INPUT_MEDIA_PLAYBACK',
            'CONTROL_INPUT_TV',
            'CONTROL_POWER',
            'READ_APP_STATUS',
            'READ_CURRENT_CHANNEL',
            'READ_INPUT_DEVICE_LIST',
            'READ_NETWORK_STATE',
            'READ_RUNNING_APPS',
            'READ_TV_CHANNEL_LIST',
            'WRITE_NOTIFICATION_TOAST',
            'WRITE_SETTINGS'
          ]
        },
        if (clientKey != null) 'client-key': clientKey,
      }
    };

    _socket?.add(jsonEncode(payload));
  }

  Future<void> launchApp(String appId, Map<String, dynamic> params) async {
    if (!_isConnected) await connect();
    if (!_isConnected) return;

    final payload = {
      'type': 'request',
      'id': 'launch_0',
      'uri': 'ssap://system.launcher/launch',
      'payload': {
        'id': appId,
        'params': params,
      }
    };

    _socket?.add(jsonEncode(payload));
  }

  void disconnect() {
    _socket?.close();
    _isConnected = false;
  }
}
