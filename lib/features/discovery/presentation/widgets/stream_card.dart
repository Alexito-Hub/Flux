import 'package:flutter/material.dart';

import '../../../../core/utils/formatters.dart';
import '../../domain/stream_candidate.dart';

/// Tarjeta de un stream encontrado. Muestra lo que importa para decidir:
/// qué es, dónde está y si va a ir fino.
class StreamCard extends StatelessWidget {
  const StreamCard({
    super.key,
    required this.candidate,
    required this.onPlay,
    required this.onRemeasure,
    this.isBest = false,
  });

  final StreamCandidate candidate;
  final VoidCallback onPlay;
  final VoidCallback onRemeasure;
  final bool isBest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = candidate.metrics;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isBest
              ? theme.colorScheme.primary.withValues(alpha: 0.55)
              : theme.colorScheme.outlineVariant,
          width: isBest ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onPlay,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Poster(container: candidate.container, isBest: isBest),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          candidate.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          candidate.address,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isBest)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'MEJOR',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (candidate.sizeBytes != null)
                    _Tag(
                      icon: Icons.sd_storage_outlined,
                      label: Fmt.bytes(candidate.sizeBytes),
                    ),
                  _Tag(
                    icon: candidate.seekable
                        ? Icons.swap_horiz_rounded
                        : Icons.block_rounded,
                    label: candidate.seekable ? 'Con avance' : 'Sin avance',
                    warning: !candidate.seekable,
                  ),
                  if (candidate.source == DiscoverySource.remembered)
                    const _Tag(icon: Icons.history_rounded, label: 'Conocido'),
                  if (candidate.source == DiscoverySource.manual)
                    const _Tag(icon: Icons.keyboard_alt_outlined, label: 'Manual'),
                  if (candidate.isLiveStream)
                    const _Tag(icon: Icons.sensors_rounded, label: 'En directo'),
                ],
              ),
              const SizedBox(height: 14),
              _MetricsRow(metrics: metrics, onRemeasure: onRemeasure),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Reproducir'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({this.container, this.isBest = false});

  final String? container;
  final bool isBest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 52,
      height: 68,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary.withValues(alpha: isBest ? 0.35 : 0.18),
            theme.colorScheme.surfaceContainerHighest,
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.movie_outlined,
            size: 22,
            color: theme.colorScheme.primary,
          ),
          if (container != null) ...[
            const SizedBox(height: 4),
            Text(
              container!,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 9,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Fila de métricas. Mientras no hay medición muestra un estado de "midiendo"
/// en vez de ceros, que serían mentira.
class _MetricsRow extends StatelessWidget {
  const _MetricsRow({required this.metrics, required this.onRemeasure});

  final StreamMetrics? metrics;
  final VoidCallback onRemeasure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (metrics == null) {
      return Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Midiendo velocidad…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final quality = _qualityColor(metrics!.score, theme);
    return Row(
      children: [
        Expanded(
          child: _Metric(
            label: 'Velocidad',
            value: Fmt.speed(metrics!.bytesPerSecond),
            color: quality,
          ),
        ),
        Expanded(
          child: _Metric(
            label: 'Salto',
            value: Fmt.millis(metrics!.seekTimeToFirstByte),
          ),
        ),
        Expanded(
          child: _Metric(
            label: 'Estado',
            value: metrics!.verdict,
            color: quality,
          ),
        ),
        IconButton(
          onPressed: onRemeasure,
          tooltip: 'Volver a medir',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.speed_rounded, size: 18),
        ),
      ],
    );
  }

  static Color _qualityColor(double score, ThemeData theme) {
    if (score >= 65) return theme.colorScheme.primary;
    if (score >= 40) return const Color(0xFFE0B33C);
    return const Color(0xFFE06C6C);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 9,
            letterSpacing: 0.6,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label, this.warning = false});

  final IconData icon;
  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = warning
        ? const Color(0xFFE0B33C)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
