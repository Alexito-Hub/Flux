import 'package:flutter/material.dart';

import '../../../../core/utils/responsive.dart';
import '../player_controller.dart';
import 'seek_bar.dart';

/// Capa de controles sobre el video. Se adapta al tamaño real de la ventana,
/// no a la plataforma: una ventana estrecha en Windows recibe los mismos
/// controles grandes que un móvil.
class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.controller,
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onToggleFullscreen,
    required this.onOpenTracks,
    required this.isFullscreen,
    required this.following,
    required this.onToggleFollow,
    required this.onCast,
  });

  final PlayerController controller;
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onOpenTracks;
  final bool isFullscreen;

  /// Si está activo, Flux carga solo el capítulo nuevo cuando lo cambias en el
  /// teléfono.
  final bool following;
  final VoidCallback onToggleFollow;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    final padding = MediaQuery.paddingOf(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Column(
          children: [
            _TopBar(
              title: title,
              subtitle: subtitle,
              reconnecting: controller.reconnecting,
              attempt: controller.reconnectAttempt,
              onBack: onBack,
              padding: padding,
              compact: compact,
              following: following,
              onToggleFollow: onToggleFollow,
              onCast: onCast,
            ),
            Expanded(
              child: Center(
                child: _CenterControls(
                  controller: controller,
                  compact: compact,
                ),
              ),
            ),
            _BottomBar(
              controller: controller,
              compact: compact,
              padding: padding,
              isFullscreen: isFullscreen,
              onToggleFullscreen: onToggleFullscreen,
              onOpenTracks: onOpenTracks,
            ),
          ],
        );
      },
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.reconnecting,
    required this.attempt,
    required this.onBack,
    required this.padding,
    required this.compact,
    required this.following,
    required this.onToggleFollow,
    required this.onCast,
  });

  final String title;
  final String subtitle;
  final bool reconnecting;
  final int attempt;
  final VoidCallback onBack;
  final EdgeInsets padding;
  final bool compact;
  final bool following;
  final VoidCallback onToggleFollow;
  final VoidCallback onCast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.only(
        top: padding.top + 8,
        left: padding.left + 8,
        right: padding.right + 12,
        bottom: 20,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
            color: Colors.white,
            tooltip: 'Volver',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white60,
                  ),
                ),
              ],
            ),
          ),
          if (reconnecting) _ReconnectBadge(attempt: attempt),
          IconButton(
            onPressed: onToggleFollow,
            color: following ? theme.colorScheme.primary : Colors.white54,
            tooltip: following
                ? 'Siguiendo la emisión: al cambiar de capítulo se carga solo'
                : 'Seguimiento desactivado',
            icon: Icon(
              following ? Icons.sensors_rounded : Icons.sensors_off_rounded,
            ),
          ),
          /* Ocultado temporalmente por solicitud
          IconButton(
            onPressed: onCast,
            color: Colors.white,
            tooltip: 'Transmitir a TV / Dispositivo',
            icon: const Icon(Icons.cast_rounded),
          ),
          */
        ],
      ),
    );
  }
}

/// Aviso honesto de que se perdió la conexión y se está recuperando, en vez de
/// dejar la pantalla congelada sin explicación.
class _ReconnectBadge extends StatelessWidget {
  const _ReconnectBadge({required this.attempt});

  final int attempt;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFE0B33C).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE0B33C).withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFE0B33C),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Reconectando ($attempt)',
            style: const TextStyle(
              color: Color(0xFFE0B33C),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CenterControls extends StatelessWidget {
  const _CenterControls({required this.controller, required this.compact});

  final PlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 40.0 : 44.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundButton(
          icon: Icons.replay_10_rounded,
          size: size,
          onPressed: () => controller.seekBy(const Duration(seconds: -10)),
          tooltip: 'Retroceder 10 s',
        ),
        SizedBox(width: compact ? 28 : 36),
        _RoundButton(
          icon: controller.playing
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          size: compact ? 64 : 72,
          filled: true,
          onPressed: controller.playOrPause,
          tooltip: controller.playing ? 'Pausar' : 'Reproducir',
        ),
        SizedBox(width: compact ? 28 : 36),
        _RoundButton(
          icon: Icons.forward_10_rounded,
          size: size,
          onPressed: () => controller.seekBy(const Duration(seconds: 10)),
          tooltip: 'Avanzar 10 s',
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.size,
    required this.onPressed,
    this.filled = false,
    this.tooltip,
  });

  final IconData icon;
  final double size;
  final VoidCallback onPressed;
  final bool filled;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: filled ? Colors.white.withValues(alpha: 0.16) : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size + 16,
          height: size + 16,
          child: Icon(icon, size: size, color: Colors.white),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.controller,
    required this.compact,
    required this.padding,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    required this.onOpenTracks,
  });

  final PlayerController controller;
  final bool compact;
  final EdgeInsets padding;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onOpenTracks;

  @override
  Widget build(BuildContext context) {
    final hasSubtitles = controller.tracks.subtitle.length > 1;
    final subtitlesOn = controller.currentTrack.subtitle.id != 'no';

    return Container(
      padding: EdgeInsets.only(
        left: padding.left + 16,
        right: padding.right + 16,
        top: 24,
        bottom: padding.bottom + 10,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xE6000000), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SeekBar(controller: controller, compact: compact),
          const SizedBox(height: 4),
          Row(
            children: [
              if (!compact) ...[
                _BarButton(
                  icon: controller.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  tooltip: 'Reproducir/Pausar  ·  Espacio',
                  onPressed: controller.playOrPause,
                ),
                _VolumeControl(controller: controller),
              ],
              const Spacer(),
              if (hasSubtitles)
                _BarButton(
                  icon: subtitlesOn
                      ? Icons.subtitles_rounded
                      : Icons.subtitles_off_rounded,
                  tooltip: 'Subtítulos',
                  active: subtitlesOn,
                  onPressed: onOpenTracks,
                ),
              _BarButton(
                icon: Icons.tune_rounded,
                tooltip: 'Audio, subtítulos y velocidad',
                onPressed: onOpenTracks,
                badge: controller.rate == 1.0
                    ? null
                    : '${controller.rate.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}x',
              ),
              _BarButton(
                icon: isFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                tooltip: 'Pantalla completa  ·  F',
                onPressed: onToggleFullscreen,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    final muted = controller.volume <= 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BarButton(
          icon: muted
              ? Icons.volume_off_rounded
              : (controller.volume < 50
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded),
          tooltip: 'Silenciar  ·  M',
          onPressed: () => controller.setVolume(muted ? 100 : 0),
        ),
        SizedBox(
          width: 96,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              inactiveTrackColor: Colors.white24,
            ),
            child: Slider(
              value: controller.volume.clamp(0, 100),
              max: 100,
              onChanged: controller.setVolume,
            ),
          ),
        ),
      ],
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
    this.badge,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final color =
        active ? Theme.of(context).colorScheme.primary : Colors.white;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          onPressed: onPressed,
          tooltip: tooltip,
          icon: Icon(icon, size: 22),
          color: color,
        ),
        if (badge != null)
          Positioned(
            right: 0,
            bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge!,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
