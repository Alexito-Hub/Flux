import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../domain/track_labels.dart';
import '../player_controller.dart';

/// Panel de pistas: audio, subtítulos y velocidad.
///
/// Es donde vive lo que el usuario pidió como "compatible con subtítulos e
/// idiomas": un MKV suele traer dos o tres audios y varios subtítulos, y
/// cambiar entre ellos tiene que ser un gesto, no una odisea.
class TracksSheet extends StatefulWidget {
  const TracksSheet({super.key, required this.controller});

  final PlayerController controller;

  static Future<void> show(BuildContext context, PlayerController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16191F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => TracksSheet(controller: controller),
    );
  }

  @override
  State<TracksSheet> createState() => _TracksSheetState();
}

class _TracksSheetState extends State<TracksSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final tracks = widget.controller.tracks;
        final current = widget.controller.currentTrack;

        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              TabBar(
                controller: _tabs,
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(icon: Icon(Icons.graphic_eq_rounded), text: 'Audio'),
                  Tab(icon: Icon(Icons.subtitles_outlined), text: 'Subtítulos'),
                  Tab(icon: Icon(Icons.speed_rounded), text: 'Velocidad'),
                ],
              ),
              Flexible(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _AudioList(
                      tracks: tracks.audio,
                      selected: current.audio,
                      onSelect: (track) {
                        widget.controller.setAudioTrack(track);
                        Navigator.of(context).pop();
                      },
                    ),
                    _SubtitleList(
                      tracks: tracks.subtitle,
                      selected: current.subtitle,
                      onSelect: (track) {
                        widget.controller.setSubtitleTrack(track);
                        Navigator.of(context).pop();
                      },
                    ),
                    _SpeedList(
                      rate: widget.controller.rate,
                      onSelect: (value) {
                        widget.controller.setRate(value);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ),
              SizedBox(height: MediaQuery.paddingOf(context).bottom + 8),
            ],
          ),
        );
      },
    );
  }
}

class _AudioList extends StatelessWidget {
  const _AudioList({
    required this.tracks,
    required this.selected,
    required this.onSelect,
  });

  final List<AudioTrack> tracks;
  final AudioTrack selected;
  final ValueChanged<AudioTrack> onSelect;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const _Empty('Este video no tiene pistas de audio.');
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return _TrackTile(
          label: TrackLabels.audio(track, index),
          detail: track.codec,
          selected: track.id == selected.id,
          onTap: () => onSelect(track),
        );
      },
    );
  }
}

class _SubtitleList extends StatelessWidget {
  const _SubtitleList({
    required this.tracks,
    required this.selected,
    required this.onSelect,
  });

  final List<SubtitleTrack> tracks;
  final SubtitleTrack selected;
  final ValueChanged<SubtitleTrack> onSelect;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const _Empty('Este video no trae subtítulos incrustados.');
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return _TrackTile(
          label: TrackLabels.subtitle(track, index),
          detail: track.codec,
          selected: track.id == selected.id,
          onTap: () => onSelect(track),
        );
      },
    );
  }
}

class _SpeedList extends StatelessWidget {
  const _SpeedList({required this.rate, required this.onSelect});

  final double rate;
  final ValueChanged<double> onSelect;

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final speed in _speeds)
          _TrackTile(
            label: speed == 1.0 ? 'Normal (1x)' : '${speed}x',
            selected: (rate - speed).abs() < 0.01,
            onTap: () => onSelect(speed),
          ),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      dense: true,
      leading: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
        size: 20,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: detail == null
          ? null
          : Text(detail!.toUpperCase(), style: theme.textTheme.labelSmall),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
