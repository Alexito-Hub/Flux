import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../discovery/domain/stream_candidate.dart';
import '../ssap_client.dart';
import '../tv_discovery.dart';

class CastDialog extends ConsumerStatefulWidget {
  const CastDialog({super.key, required this.candidate});

  final StreamCandidate candidate;

  static Future<void> show(BuildContext context, StreamCandidate candidate) {
    return showDialog(
      context: context,
      builder: (context) => CastDialog(candidate: candidate),
    );
  }

  @override
  ConsumerState<CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends ConsumerState<CastDialog> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(tvDiscoveryProvider.notifier).startDiscovery();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(tvDiscoveryProvider.notifier).stopDiscovery();
      }
    });
    super.dispose();
  }

  Future<void> _castTo(TVDevice tv) async {
    final host = widget.candidate.host;
    final port = widget.candidate.port;

    if (tv.type == 'webos') {
      final client = SSAPClient(ip: tv.ip);
      await client.connect();
      await client.launchApp('com.alessandro.flux', {
        'host': host,
        'port': port,
      });
      // El client se cerrará después, podemos dejar que haga cleanup con disconnect
      Future.delayed(const Duration(seconds: 3), () => client.disconnect());
    } else if (tv.type == 'flux_app' || tv.type == 'android_tv') {
      try {
        final client = HttpClient();
        final request = await client.postUrl(Uri.parse('http://${tv.ip}:8080/launch'));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'host': host, 'port': port}));
        await request.close();
        client.close();
      } catch (e) {
        debugPrint('[Flux] Error haciendo HTTP post al TV Box: $e');
      }
    }
    
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(tvDiscoveryProvider);

    return AlertDialog(
      title: const Text('Transmitir a...'),
      content: SizedBox(
        width: 300,
        child: devices.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Buscando dispositivos en la red...', textAlign: TextAlign.center),
                  ],
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: devices.length,
                itemBuilder: (context, index) {
                  final tv = devices[index];
                  return ListTile(
                    leading: Icon(
                      tv.type == 'webos' ? Icons.tv : Icons.ad_units,
                    ),
                    title: Text(tv.name),
                    subtitle: Text(tv.ip),
                    onTap: () => _castTo(tv),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
