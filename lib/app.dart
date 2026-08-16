import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/discovery/presentation/discovery_screen.dart';

class FluxApp extends StatelessWidget {
  const FluxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flux',
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
