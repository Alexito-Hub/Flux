import 'package:flutter_test/flutter_test.dart';
import 'package:flux/features/discovery/data/known_hosts_store.dart';
import 'package:flux/features/discovery/data/stream_prober.dart';

void main() {
  group('KnownHostsStore.parseAddress', () {
    test('acepta las formas que un usuario escribe de verdad', () {
      expect(
        KnownHostsStore.parseAddress('192.168.1.5:4445'),
        (host: '192.168.1.5', port: 4445),
      );
      expect(
        KnownHostsStore.parseAddress('http://192.168.1.5:4445/v.mkv'),
        (host: '192.168.1.5', port: 4445),
      );
      expect(
        KnownHostsStore.parseAddress('  192.168.1.5:8080/loquesea  '),
        (host: '192.168.1.5', port: 8080),
      );
    });

    test('sin puerto asume el 4445 de Movie Plus', () {
      expect(
        KnownHostsStore.parseAddress('192.168.1.5'),
        (host: '192.168.1.5', port: 4445),
      );
    });

    test('rechaza cualquier destino fuera de la red local', () {
      expect(KnownHostsStore.parseAddress('8.8.8.8:80'), isNull);
      expect(KnownHostsStore.parseAddress('http://ejemplo.com:4445'), isNull);
      expect(KnownHostsStore.parseAddress(''), isNull);
      expect(KnownHostsStore.parseAddress('...'), isNull);
    });
  });

  group('StreamProber.fileNameFrom', () {
    test('lee el formato que devuelve el servidor real', () {
      expect(
        StreamProber.fileNameFrom(
          'inline; filename="Rick and Morty S03E10.mkv"',
        ),
        'Rick and Morty S03E10.mkv',
      );
    });

    test('soporta el formato extendido con codificación', () {
      expect(
        StreamProber.fileNameFrom(
          "attachment; filename*=UTF-8''El%20Padrino%20II.mkv",
        ),
        'El Padrino II.mkv',
      );
    });

    test('sin comillas y sin cabecera', () {
      expect(StreamProber.fileNameFrom('inline; filename=video.mp4'), 'video.mp4');
      expect(StreamProber.fileNameFrom(null), isNull);
      expect(StreamProber.fileNameFrom('inline'), isNull);
    });
  });
}
