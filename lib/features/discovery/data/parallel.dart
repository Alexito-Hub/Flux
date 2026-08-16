import 'dart:async';
import 'dart:collection';

/// Limita cuántas tareas pesadas corren a la vez (validación HTTP, medición de
/// velocidad). A diferencia del barrido de puertos, aquí cada tarea consume
/// ancho de banda real del servidor, y lanzar veinte a la vez falsearía las
/// mediciones de las otras.
class Semaphore {
  Semaphore(this.maxConcurrent);

  final int maxConcurrent;
  final Queue<Completer<void>> _waiting = Queue();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= maxConcurrent) {
      final completer = Completer<void>();
      _waiting.add(completer);
      await completer.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// Ejecuta [task] sobre [items] con como mucho [concurrency] operaciones a la
/// vez, emitiendo cada resultado no nulo en cuanto está listo.
///
/// Es el motor del escáner: 254 hosts × 22 puertos son ~5.600 conexiones, y la
/// diferencia entre hacerlas de una en una (minutos) y en pool de 192
/// (segundos) es toda la funcionalidad. Al ser E/S pura no hace falta un
/// isolate: los sockets no bloquean el hilo de UI.
///
/// Cancelar la suscripción detiene el reparto de trabajo nuevo, así que el
/// botón "Detener" surte efecto de inmediato.
Stream<R> parallelMap<T, R extends Object>(
  Iterable<T> items,
  int concurrency,
  Future<R?> Function(T item) task, {
  void Function(int completed)? onProgress,
}) {
  final controller = StreamController<R>();
  final iterator = items.iterator;
  var cancelled = false;
  var completed = 0;
  var active = 0;
  var exhausted = false;

  void finishIfDone() {
    if (active == 0 && (exhausted || cancelled) && !controller.isClosed) {
      controller.close();
    }
  }

  void pump() {
    while (!cancelled && active < concurrency) {
      if (!iterator.moveNext()) {
        exhausted = true;
        break;
      }
      final item = iterator.current;
      active++;
      task(item).then((result) {
        if (result != null && !cancelled && !controller.isClosed) {
          controller.add(result);
        }
      }).catchError((Object _) {
        // Un fallo de socket es el resultado esperado en la mayoría de hosts;
        // no es un error del escaneo.
      }).whenComplete(() {
        active--;
        completed++;
        if (!cancelled) onProgress?.call(completed);
        if (cancelled) {
          finishIfDone();
        } else {
          pump();
          finishIfDone();
        }
      });
    }
    finishIfDone();
  }

  controller
    ..onListen = pump
    ..onCancel = () {
      cancelled = true;
    };

  return controller.stream;
}
