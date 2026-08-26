import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/stream_candidate.dart';
import '../discovery_controller.dart';

/// Entrada de enlace externo para reproducir video directamente desde Internet.
class ExternalLinkSheet extends ConsumerStatefulWidget {
  const ExternalLinkSheet({super.key});

  /// Abre la hoja y devuelve el stream validado, si se comprueba correctamente.
  static Future<StreamCandidate?> show(BuildContext context) {
    return showModalBottomSheet<StreamCandidate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const ExternalLinkSheet(),
    );
  }

  @override
  ConsumerState<ExternalLinkSheet> createState() => _ExternalLinkSheetState();
}

class _ExternalLinkSheetState extends ConsumerState<ExternalLinkSheet> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final input = _controller.text;
    if (input.trim().isEmpty) return;
    
    // Quitar el foco para que se baje el teclado mientras comprueba
    _focusNode.unfocus();
    
    final candidate =
        await ref.read(discoveryControllerProvider.notifier).addDirectLink(input);
    if (!mounted || candidate == null) {
      // Si falla, devolvemos el foco para que lo pueda editar
      _focusNode.requestFocus();
      return;
    }
    Navigator.of(context).pop(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(discoveryControllerProvider);
    final insets = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + insets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('Pegar enlace de video', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Se aceptan enlaces HTTP/HTTPS de Internet. Pega la URL directa del video.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'\s')),
            ],
            onChanged: (_) {
              if (state.directLinkError != null) {
                ref.read(discoveryControllerProvider.notifier).clearDirectLinkError();
              }
            },
            onSubmitted: (_) => _connect(),
            decoration: InputDecoration(
              hintText: 'https://ejemplo.com/video.mp4',
              prefixIcon: const Icon(Icons.link_rounded),
              errorText: state.directLinkError,
              errorMaxLines: 3,
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: state.checkingDirectLink ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: state.checkingDirectLink ? null : _connect,
                icon: state.checkingDirectLink
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(state.checkingDirectLink ? 'Comprobando…' : 'Comprobar enlace'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
