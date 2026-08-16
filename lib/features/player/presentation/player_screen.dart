import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/settings/app_settings.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/responsive.dart';
import '../../discovery/data/known_hosts_store.dart';
import '../../discovery/data/stream_prober.dart';
import '../../discovery/data/stream_watcher.dart';
import '../../discovery/domain/stream_candidate.dart';
import 'player_controller.dart';
import 'widgets/player_controls.dart';
import 'widgets/tracks_sheet.dart';

/// Pantalla de reproducción a pantalla completa.
///
/// Reúne las tres capas: el video, los gestos y los controles. Cada una vive
/// en su widget para que tocar la disposición de los botones no pueda romper
/// la reproducción.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key, required this.candidate});

  final StreamCandidate candidate;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final PlayerController _controller =
      PlayerController(uri: widget.candidate.uri);
  final _focusNode = FocusNode();

  /// Sonda propia del reproductor: vigilar la emisión no debe competir por la
  /// misma cola de peticiones que un escaneo en curso.
  late final StreamProber _prober = StreamProber();
  StreamWatcher? _watcher;
  StreamSubscription<WatchEvent>? _watchSubscription;

  /// Lo que se está viendo ahora mismo. Cambia solo cuando el emisor cambia de
  /// capítulo, y por eso no puede leerse de `widget.candidate`.
  late StreamCandidate _candidate = widget.candidate;

  static const _autoHide = Duration(seconds: 3);
  static const _bannerDuration = Duration(seconds: 4);

  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _zoomToFill = false;
  Timer? _hideTimer;

  String? _banner;
  bool _bannerIsWarning = false;
  Timer? _bannerTimer;

  /// Aviso flotante de "±10 s" tras un doble toque.
  int _skipFeedback = 0;
  bool _skipForward = true;
  Timer? _skipTimer;

  /// Aviso flotante del volumen al deslizar en vertical.
  double? _volumeFeedback;
  Timer? _volumeTimer;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _controller.initialize();
    _enterImmersive();
    _restartHideTimer();
    if (ref.read(settingsProvider).followSource) _startWatching();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _skipTimer?.cancel();
    _volumeTimer?.cancel();
    _bannerTimer?.cancel();
    _stopWatching();
    _prober.dispose();
    _controller.dispose();
    _focusNode.dispose();
    _exitImmersive();
    super.dispose();
  }

  // --- Seguimiento de la emisión -------------------------------------------

  void _startWatching() {
    if (_watcher != null) return;
    final watcher = StreamWatcher.of(_prober);
    _watchSubscription = watcher.events.listen(_onWatchEvent);
    watcher.start(_candidate);
    // Un error o un atasco del motor son la señal más rápida de que el emisor
    // ha cambiado de archivo: se comprueba en el acto, sin esperar al ciclo.
    _controller.onSourceSuspect = watcher.poke;
    _watcher = watcher;
  }

  void _stopWatching() {
    _controller.onSourceSuspect = null;
    _watchSubscription?.cancel();
    _watchSubscription = null;
    _watcher?.dispose();
    _watcher = null;
  }

  Future<void> _onWatchEvent(WatchEvent event) async {
    if (!mounted) return;
    switch (event) {
      case SourceChanged(:final candidate, :final recovered):
        setState(() => _candidate = candidate);
        _showBanner(
          recovered
              ? 'Nueva emisión: ${candidate.title}'
              : 'Cambiando a ${candidate.title}',
        );
        // Recordar la dirección nueva: si cambió de puerto, la próxima
        // búsqueda la encontrará al instante.
        unawaited(KnownHostsStore().remember(candidate.host, candidate.port));
        await _controller.switchTo(candidate.uri);
      case SourceLost():
        _showBanner('La emisión se detuvo. Buscando…', warning: true);
      case SourceRestored(:final candidate):
        setState(() => _candidate = candidate);
        _showBanner('Emisión recuperada');
        // Medido sobre el servidor real: puede estar caído hasta medio minuto
        // seguido. Para entonces el reproductor ya se habrá rendido por su
        // cuenta, así que en cuanto la fuente vuelve hay que despertarlo — si
        // no, la emisión está de vuelta y la pantalla sigue con el error.
        if (_controller.fatalError != null || !_controller.playing) {
          await _controller.retry();
        }
    }
  }

  void _showBanner(String message, {bool warning = false}) {
    setState(() {
      _banner = message;
      _bannerIsWarning = warning;
    });
    _bannerTimer?.cancel();
    // Los avisos de problema se quedan hasta que se resuelvan; los de "ya está"
    // desaparecen solos.
    if (warning) return;
    _bannerTimer = Timer(_bannerDuration, () {
      if (mounted) setState(() => _banner = null);
    });
  }

  Future<void> _toggleFollow() async {
    final enabled = !ref.read(settingsProvider).followSource;
    await ref.read(settingsProvider.notifier).setFollowSource(enabled);
    if (!mounted) return;
    if (enabled) {
      _startWatching();
      _showBanner('Se seguirá la emisión al cambiar de capítulo');
    } else {
      _stopWatching();
      _showBanner('Ya no se seguirán los cambios de capítulo');
    }
  }

  /// En móvil, un reproductor de películas se usa en horizontal y sin barras
  /// del sistema. Al salir se restaura todo tal y como estaba.
  Future<void> _enterImmersive() async {
    if (!_isMobile) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _exitImmersive() async {
    if (_isMobile) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else if (_fullscreen) {
      await windowManager.setFullScreen(false);
    }
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHide, () {
      if (mounted && _controller.playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _restartHideTimer();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _restartHideTimer();
  }

  Future<void> _toggleFullscreen() async {
    if (_isMobile) {
      // En móvil ya estamos a pantalla completa: aquí el botón hace lo único
      // que falta, rellenar la pantalla recortando las bandas negras.
      setState(() => _zoomToFill = !_zoomToFill);
      return;
    }
    final next = !_fullscreen;
    await windowManager.setFullScreen(next);
    if (mounted) setState(() => _fullscreen = next);
  }

  void _skip(Duration delta) {
    _controller.seekBy(delta);
    setState(() {
      _skipForward = !delta.isNegative;
      _skipFeedback = delta.inSeconds.abs();
    });
    _skipTimer?.cancel();
    _skipTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _skipFeedback = 0);
    });
  }

  void _nudgeVolume(double delta) {
    final next = (_controller.volume + delta).clamp(0.0, 100.0);
    _controller.setVolume(next);
    setState(() => _volumeFeedback = next);
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _volumeFeedback = null);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final big = shift ? const Duration(seconds: 60) : const Duration(seconds: 10);

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.keyK:
        _controller.playOrPause();
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyJ:
        _skip(-big);
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyL:
        _skip(big);
      case LogicalKeyboardKey.arrowUp:
        _nudgeVolume(5);
      case LogicalKeyboardKey.arrowDown:
        _nudgeVolume(-5);
      case LogicalKeyboardKey.keyM:
        _controller.setVolume(_controller.volume > 0 ? 0 : 100);
      case LogicalKeyboardKey.keyF:
      case LogicalKeyboardKey.f11:
        _toggleFullscreen();
      case LogicalKeyboardKey.escape:
        if (_fullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).maybePop();
        }
      default:
        return KeyEventResult.ignored;
    }
    _showControls();
    return KeyEventResult.handled;
  }

  void _onDoubleTapAt(Offset localPosition, double width) {
    final third = width / 3;
    if (localPosition.dx < third) {
      _skip(const Duration(seconds: -10));
    } else if (localPosition.dx > width - third) {
      _skip(const Duration(seconds: 10));
    } else {
      _controller.playOrPause();
      _showControls();
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = context.isCompact;
    final following = ref.watch(settingsProvider).followSource;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            onHover: (_) {
              if (!_isMobile) _showControls();
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Video(
                      controller: _controller.video,
                      controls: NoVideoControls,
                      fit: _zoomToFill ? BoxFit.cover : BoxFit.contain,
                      // El wakelock lo gestiona PlayerController siguiendo el
                      // estado real de reproducción.
                      wakelock: false,
                      subtitleViewConfiguration: SubtitleViewConfiguration(
                        style: TextStyle(
                          fontSize: compact ? 26 : 34,
                          height: 1.3,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          shadows: const [
                            Shadow(blurRadius: 6, color: Colors.black),
                            Shadow(blurRadius: 12, color: Colors.black87),
                          ],
                        ),
                        // Espacio suficiente para que el texto nunca quede
                        // debajo de la barra de progreso.
                        padding: EdgeInsets.only(
                          left: 24,
                          right: 24,
                          bottom: _controlsVisible ? 96 : 32,
                        ),
                      ),
                    ),
                    _GestureLayer(
                      onTap: _toggleControls,
                      onDoubleTapAt: (offset) =>
                          _onDoubleTapAt(offset, constraints.maxWidth),
                      onVolumeDrag: _isMobile ? _nudgeVolume : null,
                    ),
                    _BufferingIndicator(controller: _controller),
                    _PreparingOverlay(
                      controller: _controller,
                      title: _candidate.title,
                    ),
                    if (_skipFeedback > 0)
                      _SkipFeedback(
                        seconds: _skipFeedback,
                        forward: _skipForward,
                      ),
                    if (_volumeFeedback != null)
                      _VolumeFeedback(volume: _volumeFeedback!),
                    IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: PlayerControls(
                          controller: _controller,
                          title: _candidate.title,
                          subtitle: _candidate.address,
                          isFullscreen: _isMobile ? _zoomToFill : _fullscreen,
                          following: following,
                          onToggleFollow: _toggleFollow,
                          onBack: () => Navigator.of(context).maybePop(),
                          onToggleFullscreen: _toggleFullscreen,
                          onOpenTracks: () {
                            _hideTimer?.cancel();
                            TracksSheet.show(context, _controller)
                                .then((_) => _restartHideTimer());
                          },
                        ),
                      ),
                    ),
                    // El aviso de cambio de emisión va por encima de los
                    // controles y no se oculta con ellos: si el capítulo
                    // cambia solo, hay que enterarse aunque no estés tocando
                    // la pantalla.
                    if (_banner != null)
                      _SourceBanner(
                        message: _banner!,
                        warning: _bannerIsWarning,
                      ),
                    _ErrorOverlay(controller: _controller),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Gestos táctiles: un toque muestra controles, dos toques saltan, y deslizar
/// en vertical ajusta el volumen.
class _GestureLayer extends StatefulWidget {
  const _GestureLayer({
    required this.onTap,
    required this.onDoubleTapAt,
    this.onVolumeDrag,
  });

  final VoidCallback onTap;
  final ValueChanged<Offset> onDoubleTapAt;
  final ValueChanged<double>? onVolumeDrag;

  @override
  State<_GestureLayer> createState() => _GestureLayerState();
}

class _GestureLayerState extends State<_GestureLayer> {
  /// Dónde cayó el primer toque del doble toque. Vive en el State y no en
  /// `build` porque entre `onDoubleTapDown` y `onDoubleTap` pasan ~200 ms, y
  /// cualquier reconstrucción por el camino perdería la posición — y con ella
  /// el saber si el usuario quería adelantar o retroceder.
  Offset? _doubleTapPosition;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: () {
        final position = _doubleTapPosition;
        if (position != null) widget.onDoubleTapAt(position);
      },
      onVerticalDragUpdate: widget.onVolumeDrag == null
          ? null
          // Arrastrar hacia arriba sube: 100 px de recorrido ≈ 40 puntos de
          // volumen, suficientemente fino para ajustar sin pelearse.
          : (details) => widget.onVolumeDrag!(-details.delta.dy * 0.4),
    );
  }
}

/// Aviso flotante de que la emisión cambió, se perdió o volvió.
class _SourceBanner extends StatelessWidget {
  const _SourceBanner({required this.message, required this.warning});

  final String message;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final accent =
        warning ? const Color(0xFFE0B33C) : Theme.of(context).colorScheme.primary;

    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 74),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(offset: Offset(0, -12 * (1 - t)), child: child),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: accent.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      warning ? Icons.sync_problem_rounded : Icons.sensors_rounded,
                      size: 17,
                      color: accent,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Se muestra mientras el capítulo nuevo llena el búfer. Aquí sí conviene
/// tapar el video: durante la precarga el fotograma que hay debajo es todavía
/// el del capítulo anterior.
class _PreparingOverlay extends StatelessWidget {
  const _PreparingOverlay({required this.controller, required this.title});

  final PlayerController controller;
  final String title;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.preparing) return const SizedBox.shrink();
        return IgnorePointer(
          child: Container(
            color: Colors.black.withValues(alpha: 0.82),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ValueListenableBuilder<Duration>(
                  valueListenable: controller.buffer,
                  builder: (context, buffered, _) => Text(
                    'Precargando… ${Fmt.duration(buffered)} en memoria',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BufferingIndicator extends StatelessWidget {
  const _BufferingIndicator({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final show = controller.buffering && controller.fatalError == null;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: const Center(
              child: SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SkipFeedback extends StatelessWidget {
  const _SkipFeedback({required this.seconds, required this.forward});

  final int seconds;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  Fmt.signedSeconds(forward ? seconds : -seconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VolumeFeedback extends StatelessWidget {
  const _VolumeFeedback({required this.volume});

  final double volume;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 90),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  volume <= 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 90,
                  child: LinearProgressIndicator(
                    value: volume / 100,
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${volume.round()}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Solo aparece cuando la reconexión automática se ha rendido. Hasta entonces
/// el usuario ve el aviso discreto de "reconectando" y la reproducción se
/// recupera sola.
class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.controller});

  final PlayerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final error = controller.fatalError;
        if (error == null) return const SizedBox.shrink();

        return Container(
          color: Colors.black87,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded,
                    size: 44, color: Colors.white70),
                const SizedBox(height: 16),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, height: 1.4),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Comprueba que la transmisión sigue activa en el teléfono.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('Volver'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: controller.retry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
