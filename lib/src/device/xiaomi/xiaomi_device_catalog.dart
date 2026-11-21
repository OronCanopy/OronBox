import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('XiaomiDeviceCatalog');

enum XiaomiWearableFamily { band, bandPro, redmiWatch, xiaomiWatch, unknown }

enum XiaomiWearableChip { bes, xring }

enum XiaomiWearableProtocol { sppV1, sppV2 }

typedef XiaomiWearableIdentity = XiaomiDeviceCatalogEntry;

class XiaomiDeviceCatalogEntry {
  const XiaomiDeviceCatalogEntry({
    required this.pdId,
    required this.model,
    required this.product,
    required this.id,
    required this.codename,
    required this.name,
    this.nameEn,
    this.vendor = 'xiaomi',
    this.feature = const [],
  });

  final int pdId;
  final String model;
  final String product;
  final String id;
  final String codename;
  final String name;
  final String? nameEn;
  final String vendor;
  final List<String> feature;

  String get abV2Id => id;
  String get displayNameText => displayName;
  String get displayName => localizedName();
  List<String> get aliases => [
    product,
    model,
    id,
    codename,
    name,
    if (nameEn != null) nameEn!,
  ];

  // s1p(l61), h1(n60), h1e(n60e), rw4(n65), band8p(m67) are sppv1, others are sppv2
  XiaomiWearableProtocol get protocol {
    if (const {'l61', 'n60', 'n60e', 'n65', 'm67'}.contains(codename)) {
      return XiaomiWearableProtocol.sppV1;
    }
    return XiaomiWearableProtocol.sppV2;
  }

  // o62m (S4 15th anniversary) and o65m (Redmi Watch 5 eSIM) are xring, others are bes
  XiaomiWearableChip get chip {
    if (const {'o62m', 'o65m'}.contains(codename)) {
      return XiaomiWearableChip.xring;
    }
    return XiaomiWearableChip.bes;
  }

  XiaomiWearableFamily get family {
    if (id.startsWith('xmrw') ||
        codename.startsWith('n65') ||
        codename.startsWith('o65') ||
        codename.startsWith('p65') ||
        codename.startsWith('q65')) {
      return XiaomiWearableFamily.redmiWatch;
    }
    if (id.startsWith('xmws') ||
        codename.startsWith('l61') ||
        codename.startsWith('n60') ||
        codename.startsWith('n62') ||
        codename.startsWith('o62') ||
        codename.startsWith('o63') ||
        codename.startsWith('p62') ||
        codename.startsWith('q63')) {
      return XiaomiWearableFamily.xiaomiWatch;
    }
    if (id.contains('p') ||
        codename == 'm67' ||
        codename == 'n67' ||
        codename == 'p67') {
      return XiaomiWearableFamily.bandPro;
    }
    return XiaomiWearableFamily.band;
  }

  String? get seriesName {
    if (const {'n62', 'o62', 'o62m', 'o63'}.contains(codename)) {
      return 'Xiaomi Watch ${codename == 'n62' ? 'S3' : 'S4'} 系列';
    }
    return null;
  }

  String localizedName([Locale? locale]) {
    final loc =
        locale ??
        XiaomiDeviceCatalog.activeLocaleResolver?.call() ??
        PlatformDispatcher.instance.locale;
    final isZh = loc.languageCode.toLowerCase() == 'zh';
    if (!isZh && nameEn != null && nameEn!.trim().isNotEmpty) {
      return nameEn!.trim();
    }
    return name;
  }

  bool hasFeature(String feat) {
    final target = feat.trim().toLowerCase();
    return feature.any((f) => f.trim().toLowerCase() == target);
  }

  factory XiaomiDeviceCatalogEntry.fromJson(
    Map<String, dynamic> json, {
    int? pdId,
  }) {
    final rawPdId = pdId ?? int.tryParse(json['pd_id']?.toString() ?? '') ?? 0;
    final featuresList =
        (json['feature'] as List?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];

    return XiaomiDeviceCatalogEntry(
      pdId: rawPdId,
      model: json['model']?.toString() ?? '',
      product: json['product']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      codename: json['codename']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      nameEn: json['name_en']?.toString(),
      vendor: json['vendor']?.toString() ?? 'xiaomi',
      feature: featuresList,
    );
  }

  Map<String, dynamic> toJson() => {
    'pd_id': pdId,
    'model': model,
    'product': product,
    'id': id,
    'codename': codename,
    'name': name,
    if (nameEn != null) 'name_en': nameEn,
    'vendor': vendor,
    'feature': feature,
  };
}

const Map<int, Map<String, dynamic>> _builtinSeedDevices = {
  7673: {
    "model": "M2134W1",
    "product": "mijia.watch.l61",
    "id": "xmws1p",
    "codename": "l61",
    "name": "Xiaomi Watch S1 Pro",
    "name_en": "Xiaomi Watch S1 Pro",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "wifi_config",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  10268: {
    "model": "M2230W1",
    "product": "mijia.watch.n60",
    "id": "xmwh1",
    "codename": "n60",
    "name": "Xiaomi Watch H1",
    "name_en": "Xiaomi Watch H1",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  13188: {
    "model": "M2303B1",
    "product": "lchz.watch.m67",
    "id": "xmb8p",
    "codename": "m67",
    "name": "小米手环8 Pro",
    "name_en": "Xiaomi Smart Band 8 Pro",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  14614: {
    "model": "M2313W1",
    "product": "mijia.watch.n62",
    "id": "xmws3",
    "codename": "n62",
    "name": "Xiaomi Watch S3",
    "name_en": "Xiaomi Watch S3",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  14666: {
    "model": "M2314W1",
    "product": "lchz.watch.n65",
    "id": "xmrw4",
    "codename": "n65",
    "name": "Redmi Watch 4",
    "name_en": "Redmi Watch 4",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  14732: {
    "model": "M2311W1",
    "product": "mijia.watch.n62lte",
    "id": "xmws3",
    "codename": "n62",
    "name": "Xiaomi Watch S3 eSIM",
    "name_en": "Xiaomi Watch S3 eSIM",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  14792: {
    "model": "M2312W1",
    "product": "mijia.watch.n62s",
    "id": "xmws4",
    "codename": "o62",
    "name": "Xiaomi Watch S4 Sport",
    "name_en": "Xiaomi Watch S4 Sport",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  16859: {
    "model": "M2333B1",
    "product": "lchz.watch.m67ys",
    "id": "xmb8p",
    "codename": "m67",
    "name": "小米手环8 Pro 原神定制版",
    "name_en": "Xiaomi Smart Band 8 Pro Genshin Impact Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  17505: {
    "model": "M2311W1",
    "product": "mijia.watch.n62car",
    "id": "xmws3",
    "codename": "n62",
    "name": "Xiaomi Watch S3 eSIM",
    "name_en": "Xiaomi Watch S3 eSIM",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  17575: {
    "model": "M2345B1",
    "product": "miwear.watch.n66cn",
    "id": "xmb9",
    "codename": "n66",
    "name": "小米手环9",
    "name_en": "Xiaomi Smart Band 9",
    "vendor": "xiaomi",
    "feature": [
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  17576: {
    "model": "M2346B1",
    "product": "miwear.watch.n66nfc",
    "id": "xmb9",
    "codename": "n66",
    "name": "小米手环9 NFC版",
    "name_en": "Xiaomi Smart Band 9 NFC",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  17992: {
    "model": "M2346B1",
    "product": "miwear.watch.n66tc",
    "id": "xmb9",
    "codename": "n66",
    "name": "小米手环9 陶瓷特别版",
    "name_en": "Xiaomi Smart Band 9 Ceramic Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  18033: {
    "model": "M2311W1",
    "product": "mijia.watch.n62cg",
    "id": "xmws3",
    "codename": "n62",
    "name": "Xiaomi Watch S3 eSIM",
    "name_en": "Xiaomi Watch S3 eSIM",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  19330: {
    "model": "M2401B1",
    "product": "miwear.watch.n67cn",
    "id": "xmb9p",
    "codename": "n67",
    "name": "小米手环9 Pro",
    "name_en": "Xiaomi Smart Band 9 Pro",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  19602: {
    "model": "M2412W1",
    "product": "mijia.watch.n60e",
    "id": "xmwh1e",
    "codename": "n60e",
    "name": "Xiaomi Watch H1 E",
    "name_en": "Xiaomi Watch H1 E",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  19969: {
    "model": "M2425W1",
    "product": "mijia.watch.o62",
    "id": "xmws4",
    "codename": "o62",
    "name": "Xiaomi Watch S4",
    "name_en": "Xiaomi Watch S4",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  19970: {
    "model": "M2424W1",
    "product": "mijia.watch.o62lte",
    "id": "xmws4",
    "codename": "o62",
    "name": "Xiaomi Watch S4 eSIM",
    "name_en": "Xiaomi Watch S4 eSIM",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  19971: {
    "model": "M2426W1",
    "product": "mijia.watch.o62m",
    "id": "xmws4xring",
    "codename": "o62m",
    "name": "Xiaomi Watch S4 eSIM",
    "name_en": "Xiaomi Watch S4 15th Anniversary Edition",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  20266: {
    "model": "M2427W1",
    "product": "miwear.watch.o65",
    "id": "xmrw5",
    "codename": "o65",
    "name": "REDMI Watch 5",
    "name_en": "REDMI Watch 5",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  20267: {
    "model": "M2428W1",
    "product": "miwear.watch.o65m",
    "id": "xmrw5xring",
    "codename": "o65m",
    "name": "REDMI Watch 5 eSIM",
    "name_en": "REDMI Watch 5 eSIM",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  23034: {
    "model": "M2457B1",
    "product": "miwear.watch.o66cn",
    "id": "xmb10",
    "codename": "o66",
    "name": "小米手环10",
    "name_en": "Xiaomi Smart Band 10",
    "vendor": "xiaomi",
    "feature": [
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  23035: {
    "model": "M2456B1",
    "product": "miwear.watch.o66nfc",
    "id": "xmb10nfc",
    "codename": "o66nfc",
    "name": "小米手环10 NFC版",
    "name_en": "Xiaomi Smart Band 10 NFC",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  23036: {
    "model": "M2456B1",
    "product": "miwear.watch.o66tc",
    "id": "xmb10nfc",
    "codename": "o66nfc",
    "name": "小米手环10 陶瓷版",
    "name_en": "Xiaomi Smart Band 10 Ceramic Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  24414: {
    "model": "M2502W1",
    "product": "miwear.watch.o63",
    "id": "xmws441",
    "codename": "o63",
    "name": "Xiaomi Watch S4 41mm",
    "name_en": "Xiaomi Watch S4 41mm",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  24968: {
    "model": "M2456B1",
    "product": "miwear.watch.o66lj",
    "id": "xmb10nfc",
    "codename": "o66nfc",
    "name": "小米手环10 耀影金特别版",
    "name_en": "Xiaomi Smart Band 10 Glamour Gold Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  26572: {
    "model": "M2523W1",
    "product": "miwear.watch.p65",
    "id": "xmrw6",
    "codename": "p65",
    "name": "REDMI Watch 6",
    "name_en": "REDMI Watch 6",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  27469: {
    "model": "M2530W1",
    "product": "miwear.watch.p62",
    "id": "xmws5",
    "codename": "p62",
    "name": "Xiaomi Watch S5 46mm",
    "name_en": "Xiaomi Watch S5 46mm",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  28155: {
    "model": "M2517W1",
    "product": "miwear.watch.p62lte",
    "id": "xmws5",
    "codename": "p62",
    "name": "Xiaomi Watch S5 eSIM 46mm",
    "name_en": "Xiaomi Watch S5 eSIM 46mm",
    "vendor": "xiaomi",
    "feature": [
      "esim",
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  29598: {
    "model": "M2553B1",
    "product": "miwear.watch.p67cn",
    "id": "xmb10p",
    "codename": "p67",
    "name": "小米手环10 Pro",
    "name_en": "Xiaomi Smart Band 10 Pro",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  29599: {
    "model": "M2553B1",
    "product": "miwear.watch.p67tc",
    "id": "xmb10p",
    "codename": "p67",
    "name": "小米手环10 Pro 陶瓷版",
    "name_en": "Xiaomi Smart Band 10 Pro Ceramic Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
      "spp_proxy",
    ],
  },
  34102: {
    "model": "M2606W1",
    "product": "miwear.watch.q63",
    "id": "xmws541",
    "codename": "q63",
    "name": "Xiaomi Watch S5",
    "name_en": "Xiaomi Watch S5 41mm",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "miui_clock",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "spp_proxy",
    ],
  },
  34834: {
    "model": "M2616B1",
    "product": "miwear.watch.q66cn",
    "id": "xmb11",
    "codename": "q66cn",
    "name": "小米手环11",
    "name_en": "Xiaomi Smart Band 11",
    "vendor": "xiaomi",
    "feature": [
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  34835: {
    "model": "M2617B1",
    "product": "miwear.watch.q66nfc",
    "id": "xmb11nfc",
    "codename": "q66nfc",
    "name": "小米手环11 NFC版",
    "name_en": "Xiaomi Smart Band 11 NFC",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  34836: {
    "model": "M2617B1",
    "product": "miwear.watch.q66tc",
    "id": "xmb11nfc",
    "codename": "q66nfc",
    "name": "小米手环11 陶瓷版",
    "name_en": "Xiaomi Smart Band 11 Ceramic Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  34838: {
    "model": "M2617B1",
    "product": "miwear.watch.q66u",
    "id": "xmb11nfc",
    "codename": "q66nfc",
    "name": "小米手环11 全金属版",
    "name_en": "Xiaomi Smart Band 11 Titanium Edition",
    "vendor": "xiaomi",
    "feature": [
      "nfc",
      "xiaoai",
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
  37741: {
    "model": "M2524W1",
    "product": "miwear.watch.q65acn",
    "id": "xmrw6l",
    "codename": "q65a",
    "name": "REDMI Watch 6 活力版",
    "name_en": "REDMI Watch 6 Active",
    "vendor": "xiaomi",
    "feature": [
      "watchface",
      "notification",
      "weather",
      "market",
      "guide",
      "pressure",
      "media",
      "standing",
      "vo2max",
      "sao2",
      "unlock_phone",
      "sport_sort",
      "curse",
      "wrist",
      "heart_rate",
      "notification_action",
      "sedentary",
      "blood_oxygen_monitor",
      "pressure_monitor",
      "app_layout",
      "thirdparty_app",
      "sleep_goal",
      "bedtime_clock",
      "shortcut",
      "emergency_contact",
      "widget",
      "miui_clock_alert",
      "manual_heartrate",
      "assist_sleep",
      "quick_reply",
      "event_reminder",
    ],
  },
};

class XiaomiDeviceCatalog {
  XiaomiDeviceCatalog._() {
    _initDefaults();
  }

  static final XiaomiDeviceCatalog instance = XiaomiDeviceCatalog._();
  static Locale Function()? activeLocaleResolver;

  final Map<int, XiaomiDeviceCatalogEntry> _byPdId = {};
  final Map<String, XiaomiDeviceCatalogEntry> _byModel = {};
  final Map<String, XiaomiDeviceCatalogEntry> _byProduct = {};
  final Map<String, XiaomiDeviceCatalogEntry> _byCodename = {};
  final Map<String, XiaomiDeviceCatalogEntry> _byId = {};
  final Map<String, XiaomiDeviceCatalogEntry> _byNormalizedName = {};

  bool _initialized = false;
  bool get isInitialized => _initialized;

  List<XiaomiDeviceCatalogEntry> get allEntries =>
      _byPdId.values.toList(growable: false);

  void _initDefaults() {
    for (final entry in _builtinSeedDevices.entries) {
      final item = XiaomiDeviceCatalogEntry.fromJson(
        entry.value,
        pdId: entry.key,
      );
      _register(item);
    }
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;

    if (!kIsWeb) {
      try {
        final cacheFile = await _getCacheFile();
        if (await cacheFile.exists()) {
          final cachedContent = await cacheFile.readAsString();
          _loadFromJsonString(cachedContent);
          _log.fine('loaded cached xiaomi devices: ${_byPdId.length} entries');
        }
      } catch (e) {
        _log.warning('failed to load cached xiaomi devices', e);
      }
    }
  }

  void _loadFromJsonString(String rawJson) {
    if (rawJson.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return;

      for (final entry in decoded.entries) {
        final keyStr = entry.key.toString();
        final pdId = int.tryParse(keyStr);
        if (pdId == null || entry.value is! Map) continue;

        final item = XiaomiDeviceCatalogEntry.fromJson(
          (entry.value as Map).cast<String, dynamic>(),
          pdId: pdId,
        );

        _register(item);
      }
    } catch (e) {
      _log.warning('failed to parse xiaomi devices JSON', e);
    }
  }

  static bool _isSpecialVariant(XiaomiDeviceCatalogEntry entry) {
    final n = entry.name;
    return n.contains('陶瓷') ||
        n.contains('耀影金') ||
        n.contains('全金属') ||
        n.contains('定制版') ||
        n.contains('限定版') ||
        n.contains('特别版') ||
        n.contains('周年') ||
        n.contains('探索版');
  }

  void _register(XiaomiDeviceCatalogEntry item) {
    _byPdId[item.pdId] = item;
    if (item.product.isNotEmpty) {
      _byProduct[item.product.trim().toLowerCase()] = item;
    }

    final isSpecial = _isSpecialVariant(item);

    if (item.model.isNotEmpty) {
      final key = item.model.trim().toUpperCase();
      final existing = _byModel[key];
      if (existing == null || (!isSpecial && _isSpecialVariant(existing))) {
        _byModel[key] = item;
      }
    }

    if (item.codename.isNotEmpty) {
      final key = item.codename.trim().toLowerCase();
      final existing = _byCodename[key];
      if (existing == null || (!isSpecial && _isSpecialVariant(existing))) {
        _byCodename[key] = item;
      }
    }

    if (item.id.isNotEmpty) {
      final key = item.id.trim().toLowerCase();
      final existing = _byId[key];
      if (existing == null || (!isSpecial && _isSpecialVariant(existing))) {
        _byId[key] = item;
      }
    }

    if (item.name.isNotEmpty) {
      _byNormalizedName[_normalizeSearchToken(item.name)] = item;
    }
    if (item.nameEn != null && item.nameEn!.isNotEmpty) {
      _byNormalizedName[_normalizeSearchToken(item.nameEn!)] = item;
    }
  }

  XiaomiDeviceCatalogEntry? find({int? pdId, String? model, String? product}) {
    if (pdId != null && pdId > 0) {
      final direct = _byPdId[pdId];
      if (direct != null) return direct;
    }

    if (product != null && product.trim().isNotEmpty) {
      final direct = _byProduct[product.trim().toLowerCase()];
      if (direct != null) return direct;
    }

    if (model != null && model.trim().isNotEmpty) {
      final direct = _byModel[model.trim().toUpperCase()];
      if (direct != null) return direct;
    }

    return null;
  }

  XiaomiDeviceCatalogEntry? findByCodename(String? codename) {
    if (codename == null || codename.trim().isEmpty) return null;
    return _byCodename[codename.trim().toLowerCase()];
  }

  XiaomiDeviceCatalogEntry? resolve(String? input) {
    if (input == null || input.trim().isEmpty) return null;
    final raw = input.trim();

    // 1. Exact lookup by hardware / catalog identifiers (prioritizing unique product code)
    final lower = raw.toLowerCase();
    final byProduct = _byProduct[lower];
    if (byProduct != null) return byProduct;

    final byModel = _byModel[raw.toUpperCase()];
    if (byModel != null) return byModel;

    final byCodename = _byCodename[lower];
    if (byCodename != null) return byCodename;

    final byId = _byId[lower];
    if (byId != null) return byId;

    // 2. Exact match by normalized name
    final normalized = _normalizeSearchToken(raw);
    final byName = _byNormalizedName[normalized];
    if (byName != null) return byName;

    // 3. Strip 4-digit Bluetooth MAC suffix (e.g. 'Xiaomi Watch S5 12AB' -> 'Xiaomi Watch S5')
    final withoutSuffix = raw.replaceFirst(
      RegExp(r'(?:\s|-)?[a-f0-9]{4}$', caseSensitive: false),
      '',
    );
    if (withoutSuffix != raw) {
      return resolve(withoutSuffix);
    }

    return null;
  }

  List<String> codenamesForTitle(String? title) {
    final normalized = _normalizeSearchToken(title);
    if (normalized.isEmpty) return const [];

    final direct = _byNormalizedName[normalized];
    if (direct != null) return [direct.codename];

    if (!normalized.contains('/')) return const [];
    final segments = normalized.split('/');
    if (_byNormalizedName[segments.first] == null) return const [];
    final stem = segments.first.replaceAll(RegExp(r'\d+$'), '');
    final generations = {
      for (final segment in segments)
        ...RegExp(r'\d+').allMatches(segment).map((match) => match.group(0)!),
    };
    if (stem.isEmpty || generations.isEmpty) return const [];

    return [
      for (final identity in allEntries)
        if (_identityMatchesGeneration(identity, stem, generations))
          identity.codename,
    ];
  }

  bool _identityMatchesGeneration(
    XiaomiDeviceCatalogEntry identity,
    String stem,
    Set<String> generations,
  ) {
    final name = _normalizeSearchToken(identity.displayName);
    if (!name.startsWith(stem)) return false;
    final remainder = name.substring(stem.length);
    return generations.any(remainder.startsWith);
  }

  bool titleCoversVariant(String? title, String codename) {
    final normalized = _normalizeSearchToken(title);
    if (normalized.isEmpty || normalized.contains('/')) return false;

    final identity = _byCodename[codename.toLowerCase()];
    if (identity == null) return false;

    final base = _byNormalizedName[normalized];
    if (base == null || base.codename == identity.codename) return false;

    final baseName = _normalizeSearchToken(base.displayName);
    final name = _normalizeSearchToken(identity.displayName);
    return name.length > baseName.length && name.startsWith(baseName);
  }

  String displayNameForIdentity({
    required String name,
    String? codename,
    Locale? locale,
  }) {
    final identity = findByCodename(codename) ?? resolve(name);
    if (identity != null) return identity.localizedName(locale);
    final trimmed = name.trim();
    return trimmed.isEmpty ? 'Unknown device' : trimmed;
  }

  String seriesNameForIdentity(String value) {
    final identity = findByCodename(value);
    if (identity == null) return value;
    return identity.seriesName ?? '${identity.displayName} 系列';
  }

  Future<void> syncRemote({required Dio dio, required String baseUrl}) async {
    try {
      final cleanBase = baseUrl.replaceAll(RegExp(r'/+$'), '');
      final response = await dio.get<String>(
        '$cleanBase/api/v1/device-models',
        options: Options(responseType: ResponseType.plain),
      );

      final body = response.data;
      if (body == null || body.trim().isEmpty) return;

      _loadFromJsonString(body);
      _log.info(
        'successfully synced remote xiaomi devices: ${_byPdId.length} entries',
      );

      if (!kIsWeb) {
        final cacheFile = await _getCacheFile();
        await cacheFile.writeAsString(body, flush: true);
      }
    } catch (e) {
      _log.fine('failed to sync remote xiaomi devices (offline or error)', e);
    }
  }

  Future<File> _getCacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/xiaomi_device_catalog_cache.json');
  }
}

String _normalizeSearchToken(String? value) {
  final lower = value?.trim().toLowerCase() ?? '';
  if (lower.isEmpty) return '';
  return lower
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll('红米', 'redmi')
      .replaceAll('小米', 'xiaomi')
      .replaceAll('手环', 'smartband')
      .replaceAll('手表', 'watch')
      .replaceAll('系列', '')
      .replaceAll('纪念版', 'anniversary');
}

// Global top-level backward compatibility aliases
XiaomiDeviceCatalogEntry? normalizeXiaomiWearableIdentity(String? input) =>
    XiaomiDeviceCatalog.instance.resolve(input);

XiaomiDeviceCatalogEntry? xiaomiWearableIdentityForCodename(String? value) =>
    XiaomiDeviceCatalog.instance.findByCodename(value);

List<String> xiaomiWearableCodenamesForTitle(String? title) =>
    XiaomiDeviceCatalog.instance.codenamesForTitle(title);

bool xiaomiWearableTitleCoversVariant(String? title, String codename) =>
    XiaomiDeviceCatalog.instance.titleCoversVariant(title, codename);

String xiaomiDisplayNameForIdentity({
  required String name,
  String? codename,
  Locale? locale,
}) => XiaomiDeviceCatalog.instance.displayNameForIdentity(
  name: name,
  codename: codename,
  locale: locale,
);

String xiaomiSeriesNameForIdentity(String value) =>
    XiaomiDeviceCatalog.instance.seriesNameForIdentity(value);

String normalizeXiaomiWearableCodename(String? input) =>
    XiaomiDeviceCatalog.instance.resolve(input)?.codename ?? '';

Map<String, XiaomiDeviceCatalogEntry> get xiaomiWearableIdentities => {
  for (final e in XiaomiDeviceCatalog.instance.allEntries) e.codename: e,
};
