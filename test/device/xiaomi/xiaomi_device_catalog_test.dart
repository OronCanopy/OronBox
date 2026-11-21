import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/core/models/bt_models.dart';
import 'package:oronbox/src/core/models/device.dart';
import 'package:oronbox/src/device/xiaomi/xiaomi_device_catalog.dart';

void main() {
  group('XiaomiDeviceCatalogEntry protocol & chip', () {
    test('s1p, h1, h1e, rw4, band8p are sppv1, others are sppv2', () {
      final catalog = XiaomiDeviceCatalog.instance;

      // SPP v1 devices
      final s1p = catalog.findByCodename('l61');
      expect(s1p, isNotNull);
      expect(s1p!.protocol, XiaomiWearableProtocol.sppV1);

      final h1 = catalog.findByCodename('n60');
      expect(h1, isNotNull);
      expect(h1!.protocol, XiaomiWearableProtocol.sppV1);

      final h1e = catalog.findByCodename('n60e');
      expect(h1e, isNotNull);
      expect(h1e!.protocol, XiaomiWearableProtocol.sppV1);

      final rw4 = catalog.findByCodename('n65');
      expect(rw4, isNotNull);
      expect(rw4!.protocol, XiaomiWearableProtocol.sppV1);

      final b8p = catalog.findByCodename('m67');
      expect(b8p, isNotNull);
      expect(b8p!.protocol, XiaomiWearableProtocol.sppV1);

      // SPP v2 devices
      final s3 = catalog.findByCodename('n62');
      expect(s3, isNotNull);
      expect(s3!.protocol, XiaomiWearableProtocol.sppV2);

      final s4 = catalog.findByCodename('o62');
      expect(s4, isNotNull);
      expect(s4!.protocol, XiaomiWearableProtocol.sppV2);

      final s5 = catalog.findByCodename('p62');
      expect(s5, isNotNull);
      expect(s5!.protocol, XiaomiWearableProtocol.sppV2);

      final band9 = catalog.findByCodename('n66');
      expect(band9, isNotNull);
      expect(band9!.protocol, XiaomiWearableProtocol.sppV2);

      final band10 = catalog.findByCodename('o66');
      expect(band10, isNotNull);
      expect(band10!.protocol, XiaomiWearableProtocol.sppV2);

      final band11 = catalog.findByCodename('q66cn');
      expect(band11, isNotNull);
      expect(band11!.protocol, XiaomiWearableProtocol.sppV2);

      final rw5 = catalog.findByCodename('o65');
      expect(rw5, isNotNull);
      expect(rw5!.protocol, XiaomiWearableProtocol.sppV2);

      final rw6 = catalog.findByCodename('p65');
      expect(rw6, isNotNull);
      expect(rw6!.protocol, XiaomiWearableProtocol.sppV2);
    });

    test('chip is xring only for o62m and o65m', () {
      final catalog = XiaomiDeviceCatalog.instance;

      final s4Anniversary = catalog.findByCodename('o62m');
      expect(s4Anniversary, isNotNull);
      expect(s4Anniversary!.chip, XiaomiWearableChip.xring);

      final rw5Esim = catalog.findByCodename('o65m');
      expect(rw5Esim, isNotNull);
      expect(rw5Esim!.chip, XiaomiWearableChip.xring);

      final s5 = catalog.findByCodename('p62');
      expect(s5, isNotNull);
      expect(s5!.chip, XiaomiWearableChip.bes);

      final band9 = catalog.findByCodename('n66');
      expect(band9, isNotNull);
      expect(band9!.chip, XiaomiWearableChip.bes);
    });
  });

  group('Deleted deprecated devices check', () {
    test('ensures S1 standard, S2, Band 7, Band 8 standard, and Redmi Band are completely removed', () {
      final catalog = XiaomiDeviceCatalog.instance;

      // S1 standard (k62) & S2 (m62s, m62a)
      expect(catalog.find(pdId: 5306), isNull);
      expect(catalog.findByCodename('k62'), isNull);
      expect(catalog.find(pdId: 9255), isNull);
      expect(catalog.find(pdId: 9257), isNull);
      expect(catalog.findByCodename('m62s'), isNull);
      expect(catalog.findByCodename('m62a'), isNull);

      // Band 7 (v7, v7nfc, l67)
      expect(catalog.find(pdId: 7800), isNull);
      expect(catalog.find(pdId: 7801), isNull);
      expect(catalog.find(pdId: 6885), isNull);
      expect(catalog.findByCodename('v7'), isNull);
      expect(catalog.findByCodename('v7nfc'), isNull);
      expect(catalog.findByCodename('l67'), isNull);

      // Band 8 standard / NFC / Disney (m66)
      expect(catalog.find(pdId: 11814), isNull);
      expect(catalog.find(pdId: 11816), isNull);
      expect(catalog.find(pdId: 14215), isNull);
      expect(catalog.findByCodename('m66'), isNull);

      // Redmi Band (n69)
      expect(catalog.find(pdId: 20478), isNull);
      expect(catalog.findByCodename('n69'), isNull);
    });
  });

  group('XiaomiDeviceCatalog resolution & i18n', () {
    test('resolves inputs by model, product, id, codename, name, and bluetooth suffix', () {
      final catalog = XiaomiDeviceCatalog.instance;

      // By CMIIT Model
      expect(catalog.resolve('M2517W1')?.codename, 'p62');
      // By official product
      expect(catalog.resolve('miwear.watch.p62lte')?.model, 'M2517W1');
      // By AstroBox id
      expect(catalog.resolve('xmws5')?.codename, 'p62');
      // By codename
      expect(catalog.resolve('p62')?.id, 'xmws5');
      // By Chinese name
      expect(catalog.resolve('Xiaomi Watch S5 eSIM 46mm')?.pdId, 28155);
      // By name with Bluetooth suffix
      expect(catalog.resolve('Xiaomi Watch S5 46mm 12AB')?.codename, 'p62');
      expect(catalog.resolve('Xiaomi Smart Band 9 Pro 34CD')?.codename, 'n67');
    });

    test('localizedName respects locale', () {
      final catalog = XiaomiDeviceCatalog.instance;
      final band9p = catalog.findByCodename('n67');
      expect(band9p, isNotNull);

      expect(band9p!.localizedName(const Locale('zh', 'CN')), '小米手环9 Pro');
      expect(
        band9p.localizedName(const Locale('en', 'US')),
        'Xiaomi Smart Band 9 Pro',
      );
    });

    test('displayNameForIdentity and MiWearState.localizedName respect active locale and explicit locale', () {
      expect(
        xiaomiDisplayNameForIdentity(
          name: '小米手环9',
          codename: 'n66',
          locale: const Locale('en'),
        ),
        'Xiaomi Smart Band 9',
      );
      expect(
        xiaomiDisplayNameForIdentity(
          name: 'Xiaomi Smart Band 9',
          codename: 'n66',
          locale: const Locale('zh'),
        ),
        '小米手环9',
      );

      const pairedZhDevice = MiWearState(
        name: '小米手环9',
        addr: '11:22:33:44:55:66',
        connectType: 'ble',
        codename: 'n66',
      );
      expect(
        pairedZhDevice.localizedName(const Locale('en')),
        'Xiaomi Smart Band 9',
      );
      expect(pairedZhDevice.localizedName(const Locale('zh')), '小米手环9');

      XiaomiDeviceCatalog.activeLocaleResolver = () => const Locale('en');
      try {
        expect(
          xiaomiDisplayNameForIdentity(name: '小米手环9', codename: 'n66'),
          'Xiaomi Smart Band 9',
        );
        expect(pairedZhDevice.localizedName(), 'Xiaomi Smart Band 9');
      } finally {
        XiaomiDeviceCatalog.activeLocaleResolver = null;
      }
    });
  });

  group('Base SKU protection against special variants', () {
    test('standard / NFC models never resolve to ceramic or gold variants by model alone', () {
      final catalog = XiaomiDeviceCatalog.instance;

      // Band 10 NFC model M2456B1 must resolve to base NFC, never ceramic or gold
      final band10 = catalog.resolve('M2456B1');
      expect(band10, isNotNull);
      expect(band10!.name, equals('小米手环10 NFC版'));
      expect(band10.product, equals('miwear.watch.o66nfc'));

      final band10Find = catalog.find(model: 'M2456B1');
      expect(band10Find?.name, equals('小米手环10 NFC版'));

      // Band 9 NFC model M2346B1 must resolve to base NFC, never ceramic
      final band9 = catalog.resolve('M2346B1');
      expect(band9, isNotNull);
      expect(band9!.name, equals('小米手环9 NFC版'));
      expect(band9.product, equals('miwear.watch.n66nfc'));

      // Band 11 NFC model M2617B1 must resolve to base NFC, never titanium/ceramic
      final band11 = catalog.resolve('M2617B1');
      expect(band11, isNotNull);
      expect(band11!.name, equals('小米手环11 NFC版'));
      expect(band11.product, equals('miwear.watch.q66nfc'));

      // Band 10 Pro model M2553B1 must resolve to base Pro, never ceramic
      final band10p = catalog.resolve('M2553B1');
      expect(band10p, isNotNull);
      expect(band10p!.name, equals('小米手环10 Pro'));
      expect(band10p.product, equals('miwear.watch.p67cn'));
    });

    test('exact product lookup still accurately resolves ceramic and gold variants', () {
      final catalog = XiaomiDeviceCatalog.instance;

      // When product is explicitly provided (via handshake or cloud), accurately resolve
      final ceramic = catalog.find(
        product: 'miwear.watch.o66tc',
        model: 'M2456B1',
      );
      expect(ceramic, isNotNull);
      expect(ceramic!.name, equals('小米手环10 陶瓷版'));
      expect(ceramic.pdId, equals(23036));

      final gold = catalog.find(
        product: 'miwear.watch.o66lj',
        model: 'M2456B1',
      );
      expect(gold, isNotNull);
      expect(gold!.name, equals('小米手环10 耀影金特别版'));
      expect(gold.pdId, equals(24968));

      final band9Ceramic = catalog.find(
        product: 'miwear.watch.n66tc',
        model: 'M2346B1',
      );
      expect(band9Ceramic, isNotNull);
      expect(band9Ceramic!.name, equals('小米手环9 陶瓷特别版'));
    });
  });
}
