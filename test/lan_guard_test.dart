import 'package:flutter_test/flutter_test.dart';
import 'package:flux/core/net/lan_guard.dart';

void main() {
  group('LanGuard.isPrivate', () {
    test('acepta los tres rangos privados', () {
      expect(LanGuard.isPrivate('192.168.1.5'), isTrue);
      expect(LanGuard.isPrivate('10.0.0.7'), isTrue);
      expect(LanGuard.isPrivate('172.16.0.1'), isTrue);
      expect(LanGuard.isPrivate('172.31.255.254'), isTrue);
    });

    test('rechaza direcciones públicas', () {
      expect(LanGuard.isPrivate('8.8.8.8'), isFalse);
      expect(LanGuard.isPrivate('1.1.1.1'), isFalse);
      // 172.15 y 172.32 quedan fuera de 172.16/12: es el error clásico al
      // implementar este rango a ojo.
      expect(LanGuard.isPrivate('172.15.0.1'), isFalse);
      expect(LanGuard.isPrivate('172.32.0.1'), isFalse);
      expect(LanGuard.isPrivate('193.168.1.5'), isFalse);
    });

    test('rechaza link-local y basura', () {
      expect(LanGuard.isPrivate('169.254.51.42'), isFalse);
      expect(LanGuard.isPrivate('192.168.1'), isFalse);
      expect(LanGuard.isPrivate('192.168.1.256'), isFalse);
      expect(LanGuard.isPrivate(''), isFalse);
      expect(LanGuard.isPrivate('no-soy-una-ip'), isFalse);
    });
  });

  group('LanGuard.isAllowedUri', () {
    test('permite HTTP a la LAN', () {
      expect(
        LanGuard.isAllowedUri(Uri.parse('http://192.168.1.5:4445/')),
        isTrue,
      );
    });

    test('bloquea internet y esquemas locales', () {
      expect(LanGuard.isAllowedUri(Uri.parse('http://evil.com/v.mkv')), isFalse);
      expect(LanGuard.isAllowedUri(Uri.parse('http://8.8.8.8:80/')), isFalse);
      expect(LanGuard.isAllowedUri(Uri.parse('file:///C:/secreto.txt')), isFalse);
      expect(LanGuard.isAllowedUri(Uri.parse('data:video/mp4;base64,AA')), isFalse);
    });
  });

  test('conversión ida y vuelta de IPv4', () {
    expect(LanGuard.fromInt(LanGuard.toInt('192.168.1.5')!), '192.168.1.5');
    expect(LanGuard.fromInt(LanGuard.toInt('10.0.0.1')!), '10.0.0.1');
  });
}
