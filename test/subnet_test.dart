import 'package:flutter_test/flutter_test.dart';
import 'package:flux/features/discovery/domain/lan_subnet.dart';

void main() {
  group('elección de subred', () {
    // Esta es exactamente la situación del PC donde se desarrolló Flux: cinco
    // interfaces, cuatro de ellas virtuales. Escanear la equivocada significa
    // no encontrar nunca el teléfono.
    test('la Wi-Fi real gana a WSL, Hyper-V y Bluetooth', () {
      final candidates = [
        LanSubnet.tryCreate('vEthernet (WSL (Hyper-V firewall))', '172.18.96.1')!,
        LanSubnet.tryCreate('vEthernet (Default Switch)', '172.20.0.1')!,
        LanSubnet.tryCreate('Wi-Fi', '192.168.1.4')!,
      ]..sort((a, b) => b.score.compareTo(a.score));

      expect(candidates.first.localIp, '192.168.1.4');
      expect(candidates.first.isVirtual, isFalse);
      expect(candidates[1].isVirtual, isTrue);
    });

    test('en Android la interfaz se llama wlan0', () {
      final wifi = LanSubnet.tryCreate('wlan0', '192.168.1.7')!;
      final vpn = LanSubnet.tryCreate('tun0-vpn', '10.8.0.2')!;
      expect(wifi.score, greaterThan(vpn.score));
      expect(vpn.isVirtual, isTrue);
    });

    test('las direcciones no privadas no generan subred', () {
      expect(LanSubnet.tryCreate('Wi-Fi', '8.8.8.8'), isNull);
      expect(LanSubnet.tryCreate('Bluetooth', '169.254.51.42'), isNull);
    });
  });

  group('geometría de la subred', () {
    final subnet = LanSubnet.tryCreate('Wi-Fi', '192.168.1.4')!;

    test('prefijo y CIDR', () {
      expect(subnet.prefix, '192.168.1');
      expect(subnet.cidr, '192.168.1.0/24');
    });

    test('cubre los 254 hosts asignables', () {
      final hosts = subnet.hosts();
      expect(hosts, hasLength(254));
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
      expect(hosts, contains('192.168.1.5'));
    });
  });
}
