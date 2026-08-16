
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/cast/receiver_service.dart';
import 'features/discovery/presentation/discovery_screen.dart';
import 'features/player/presentation/player_screen.dart';
import 'features/discovery/domain/stream_candidate.dart';

class FluxApp extends ConsumerStatefulWidget {
  const FluxApp({super.key});

  @override
  ConsumerState<FluxApp> createState() => _FluxAppState();
}

class _FluxAppState extends ConsumerState<FluxApp> {
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Iniciar servicio receptor para permitir que otras instancias de Flux puedan enviar transmisiones aquí
    final receiver = ref.read(castReceiverProvider);
    receiver.onPlayCommand = (host, port) {
      // Ejecutar navegación en el UI thread principal
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final candidate = StreamCandidate(
          host: host,
          port: port,
          source: DiscoverySource.manual,
          fileName: 'Recibiendo emisión',
          seekable: true,
        );
        
        navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => PlayerScreen(candidate: candidate),
          ),
        );
      });
    };
    receiver.start();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flux',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const DiscoveryScreen(),
      builder: (context, child) {
        // Evita que el tamaño de fuente del sistema descoloque los controles
        // del reproductor en móviles con accesibilidad al máximo.
        final scale = MediaQuery.textScalerOf(context).clamp(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.3,
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scale),
          child: child!,
        );
      },
    );
  }
}
