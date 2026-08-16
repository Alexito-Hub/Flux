import 'package:flutter/material.dart';

import '../../../../core/utils/formatters.dart';
import '../player_controller.dart';

/// Barra de progreso con indicador de búfer.
///
/// No usa `Slider` a propósito: hace falta pintar tres capas (pista, búfer
/// descargado y posición) y saber qué parte del video ya está en memoria es
/// justo lo que te dice si puedes saltar hacia adelante sin esperar.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.controller, this.compact = false});

  final PlayerController controller;
  final bool compact;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragFraction;
  bool _hovering = false;

  Duration get _total => widget.controller.duration;

  void _updateDrag(double dx, double width) {
    setState(() => _dragFraction = (dx / width).clamp(0.0, 1.0));
  }

  Future<void> _commit() async {
    final fraction = _dragFraction;
    if (fraction == null || _total <= Duration.zero) {
      setState(() => _dragFraction = null);
      return;
    }
    final target = _total * fraction;
    setState(() => _dragFraction = null);
    await widget.controller.seekTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seekable = _total > Duration.zero;

    return ValueListenableBuilder<Duration>(
      valueListenable: widget.controller.position,
      builder: (context, position, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: widget.controller.buffer,
          builder: (context, buffered, _) {
            final total = _total.inMilliseconds;
            final playedFraction = _dragFraction ??
                (total <= 0 ? 0.0 : (position.inMilliseconds / total).clamp(0.0, 1.0));
            final bufferFraction =
                total <= 0 ? 0.0 : (buffered.inMilliseconds / total).clamp(0.0, 1.0);
            final preview = _dragFraction == null
                ? position
                : _total * _dragFraction!;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MouseRegion(
                  onEnter: (_) => setState(() => _hovering = true),
                  onExit: (_) => setState(() => _hovering = false),
                  cursor: seekable
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.basic,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: seekable
                            ? (details) {
                                _updateDrag(details.localPosition.dx, width);
                                _commit();
                              }
                            : null,
                        onHorizontalDragStart: seekable
                            ? (details) =>
                                _updateDrag(details.localPosition.dx, width)
                            : null,
                        onHorizontalDragUpdate: seekable
                            ? (details) =>
                                _updateDrag(details.localPosition.dx, width)
                            : null,
                        onHorizontalDragEnd: seekable ? (_) => _commit() : null,
                        onHorizontalDragCancel:
                            seekable ? () => setState(() => _dragFraction = null) : null,
                        child: SizedBox(
                          // Zona táctil generosa aunque la barra sea fina: en
                          // un móvil, acertar en 4 px es imposible.
                          height: widget.compact ? 28 : 24,
                          child: Center(
                            child: _Track(
                              played: playedFraction,
                              buffered: bufferFraction,
                              active: _hovering || _dragFraction != null,
                              enabled: seekable,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        Fmt.duration(preview),
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: Colors.white),
                      ),
                      Text(
                        seekable ? Fmt.duration(_total) : 'en directo',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({
    required this.played,
    required this.buffered,
    required this.active,
    required this.enabled,
  });

  final double played;
  final double buffered;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final height = active ? 6.0 : 4.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          alignment: Alignment.centerLeft,
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(height),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              width: width * buffered,
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(height),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              width: width * played,
              decoration: BoxDecoration(
                color: enabled ? primary : Colors.white54,
                borderRadius: BorderRadius.circular(height),
              ),
            ),
            if (enabled)
              Positioned(
                left: (width * played) - (active ? 8 : 6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: active ? 16 : 12,
                  height: active ? 16 : 12,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(color: Colors.black54, blurRadius: 4),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
