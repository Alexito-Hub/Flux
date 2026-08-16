import 'package:flutter_test/flutter_test.dart';
import 'package:flux/features/discovery/data/stream_watcher.dart';
import 'package:flux/features/discovery/domain/stream_candidate.dart';

StreamCandidate episode(
  String name, {
  int size = 1500000000,
  int port = 4445,
  int modifiedYear = 2023,
}) {
  return StreamCandidate(
    host: '192.168.1.5',
    port: port,
    source: DiscoverySource.quickScan,
    fileName: name,
    contentType: 'video/x-matroska',
    sizeBytes: size,
    seekable: true,
    lastModified: DateTime.utc(modifiedYear, 2, 10),
  );
}

void main() {
  group('huella del contenido', () {
    test('el mismo archivo mantiene su huella', () {
      expect(
        episode('S03E10.mkv').isSameContentAs(episode('S03E10.mkv')),
        isTrue,
      );
    });

    test('otro capítulo cambia la huella aunque el puerto sea el mismo', () {
      final actual = episode('S03E10.mkv');
      final siguiente = episode('S03E11.mkv', size: 1490000000);
      expect(actual.isSameContentAs(siguiente), isFalse);
      // Misma dirección, otro contenido: por eso comparar URLs no sirve.
      expect(actual.uri, siguiente.uri);
    });

    test('dos capítulos del mismo peso se distinguen por la fecha', () {
      final a = episode('cap.mkv', modifiedYear: 2023);
      final b = episode('cap.mkv', modifiedYear: 2024);
      expect(a.isSameContentAs(b), isFalse);
    });
  });

  group('StreamWatcher', () {
    test('callado mientras el archivo no cambia', () async {
      final actual = episode('S03E10.mkv');
      final watcher = StreamWatcher(probe: (_, _) async => actual);
      final events = <WatchEvent>[];
      watcher.events.listen(events.add);

      watcher.start(actual);
      await watcher.check();
      await watcher.check();
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      watcher.dispose();
    });

    test('avisa del cambio de capítulo en el mismo puerto', () async {
      final actual = episode('S03E10.mkv');
      final siguiente = episode('S03E11.mkv', size: 1490000000);
      var served = actual;

      final watcher = StreamWatcher(probe: (_, _) async => served);
      final events = <WatchEvent>[];
      watcher.events.listen(events.add);

      watcher.start(actual);
      await watcher.check();
      served = siguiente;
      await watcher.check();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single, isA<SourceChanged>());
      expect((events.single as SourceChanged).candidate.fileName, 'S03E11.mkv');
      expect(watcher.current?.fileName, 'S03E11.mkv');
      watcher.dispose();
    });

    test('un solo fallo no dispara la alarma; dos sí', () async {
      final actual = episode('S03E10.mkv');
      StreamCandidate? served = actual;

      final watcher = StreamWatcher(probe: (_, _) async => served);
      final events = <WatchEvent>[];
      watcher.events.listen(events.add);

      watcher.start(actual);
      served = null;
      await watcher.check();
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty, reason: 'un pico de Wi-Fi no es una caída');

      await watcher.check();
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<SourceLost>());
      watcher.dispose();
    });

    test('tras una caída, si vuelve el mismo archivo se anuncia recuperación',
        () async {
      final actual = episode('S03E10.mkv');
      StreamCandidate? served = actual;

      final watcher = StreamWatcher(probe: (_, _) async => served);
      final events = <WatchEvent>[];
      watcher.events.listen(events.add);

      watcher.start(actual);
      served = null;
      await watcher.check();
      await watcher.check(); // aquí se emite SourceLost
      served = actual;
      await watcher.check();
      await Future<void>.delayed(Duration.zero);

      expect(events.last, isA<SourceRestored>());
      watcher.dispose();
    });

    test('tras una caída, si vuelve otro archivo es un cambio de capítulo',
        () async {
      final actual = episode('S03E10.mkv');
      StreamCandidate? served = actual;

      final watcher = StreamWatcher(probe: (_, _) async => served);
      final events = <WatchEvent>[];
      watcher.events.listen(events.add);

      watcher.start(actual);
      served = null;
      await watcher.check();
      await watcher.check();
      served = episode('S03E11.mkv', size: 1490000000);
      await watcher.check();
      await Future<void>.delayed(Duration.zero);

      expect(events.last, isA<SourceChanged>());
      expect((events.last as SourceChanged).recovered, isTrue);
      watcher.dispose();
    });

    test('si el servidor reaparece en otro puerto, lo encuentra y lo sigue',
        () async {
      final actual = episode('S03E10.mkv');
      final enOtroPuerto = episode('S03E11.mkv', size: 1490000000, port: 8080);

      final watcher = StreamWatcher(
        probe: (_, _) async => null, // el 4445 ya no responde
        rescan: (_) async => enOtroPuerto,
      );
      final events = <WatchEvent>[];
      watcher.events.listen(events.add);

      watcher.start(actual);
      await watcher.check();
      await watcher.check();
      await Future<void>.delayed(Duration.zero);

      expect(events.first, isA<SourceLost>());
      expect(events.last, isA<SourceChanged>());
      expect(watcher.current?.port, 8080);
      expect(watcher.isLost, isFalse);
      watcher.dispose();
    });
  });
}
