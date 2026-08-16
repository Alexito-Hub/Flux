import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/stream_candidate.dart';
import '../discovery_controller.dart';

/// Entrada manual de IP:puerto. Es la salida de emergencia cuando el barrido
/// no encuentra nada: routers con aislamiento de clientes, redes de invitados,
/// o un puerto que no está en ninguna lista.
class ManualConnectSheet extends ConsumerStatefulWidget {
  const ManualConnectSheet({super.key});

  /// Abre la hoja y devuelve el stream validado, si el usuario conecta.
  static Future<StreamCandidate?> show(BuildContext context) {
    return showModalBottomSheet<StreamCandidate>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const ManualConnectSheet(),
    );
  }

  @override
  ConsumerState<ManualConnectSheet> createState() => _ManualConnectSheetState();
}

class _ManualConnectSheetState extends ConsumerState<ManualConnectSheet> {
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
    final candidate =
        await ref.read(discoveryControllerProvider.notifier).addManual(input);
    if (!mounted || candidate == null) return;
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
          Text('Conectar a mano', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'Escribe la dirección que muestra la app al empezar a transmitir. '
            'Si no pones puerto, se usa el 4445.',
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
              if (state.manualError != null) {
                ref.read(discoveryControllerProvider.notifier).clearManualError();
              }
            },
            onSubmitted: (_) => _connect(),
            decoration: InputDecoration(
              hintText: '192.168.1.5:4445',
              prefixIcon: const Icon(Icons.lan_outlined),
              errorText: state.manualError,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Solo se aceptan direcciones de tu red local.',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: state.checkingManual ? null : _connect,
              icon: state.checkingManual
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link_rounded),
              label: Text(state.checkingManual ? 'Comprobando…' : 'Conectar'),
            ),
          ),
        ],
      ),
    );
  }
}
