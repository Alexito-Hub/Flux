import 'package:flutter_test/flutter_test.dart';
import 'package:flux/core/utils/formatters.dart';
import 'package:flux/features/discovery/domain/stream_candidate.dart';

StreamMetrics metrics({
  required double mbps,
  int startMs = 300,
  int seekMs = 300,
}) {
  return StreamMetrics(
    timeToFirstByte: Duration(milliseconds: startMs),
    bytesPerSecond: mbps * 1024 * 1024,
    seekTimeToFirstByte: Duration(milliseconds: seekMs),
  );
}

void main() {
  group('puntuación de un stream', () {
    test('más ancho de banda puntúa más', () {
      expect(metrics(mbps: 8).score, greaterThan(metrics(mbps: 1).score));
    });

    test('un salto lento penaliza aunque el ancho de banda sea bueno', () {
      final agil = metrics(mbps: 6, seekMs: 200);
      final torpe = metrics(mbps: 6, seekMs: 3500);
      expect(agil.score, greaterThan(torpe.score));
    });

    test('la puntuación nunca se sale de 0..100', () {
      expect(metrics(mbps: 200, startMs: 1, seekMs: 1).score, lessThanOrEqualTo(100));
      expect(
        metrics(mbps: 0, startMs: 9000, seekMs: 9000).score,
        greaterThanOrEqualTo(0),
      );
    });

    test('el veredicto refleja si aguanta un 1080p (~1,2 MB/s)', () {
      expect(metrics(mbps: 0.5).verdict, 'Justo');
      expect(metrics(mbps: 1.5).verdict, 'Suficiente');
      expect(metrics(mbps: 8).verdict, 'Excelente');
    });
  });

  group('presentación del candidato', () {
    test('el nombre del archivo se convierte en título legible', () {
      const candidate = StreamCandidate(
        host: '192.168.1.5',
        port: 4445,
        source: DiscoverySource.quickScan,
        fileName: 'Rick.and.Morty.S03E10.1080p.mkv',
        contentType: 'video/x-matroska',
      );
      expect(candidate.title, 'Rick and Morty S03E10 1080p');
      expect(candidate.container, 'MKV');
      expect(candidate.uri.toString(), 'http://192.168.1.5:4445/');
    });

    test('sin nombre cae a la dirección', () {
      const candidate = StreamCandidate(
        host: '192.168.1.9',
        port: 8080,
        source: DiscoverySource.manual,
        contentType: 'video/mp4',
      );
      expect(candidate.title, '192.168.1.9:8080');
      expect(candidate.container, 'MP4');
    });
  });

  group('formateo', () {
    test('duración', () {
      expect(Fmt.duration(const Duration(minutes: 3, seconds: 5)), '03:05');
      expect(
        Fmt.duration(const Duration(hours: 1, minutes: 23, seconds: 45)),
        '1:23:45',
      );
      expect(Fmt.duration(const Duration(seconds: -5)), '00:00');
    });

    test('tamaños y velocidades', () {
      expect(Fmt.bytes(1536566495), '1.4 GB');
      expect(Fmt.bytes(null), '—');
      expect(Fmt.speed(3 * 1024 * 1024), '3.0 MB/s');
      expect(Fmt.speed(0), '—');
    });
  });
}
