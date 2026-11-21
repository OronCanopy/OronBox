import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';

enum AppThemeMode { system, light, dark, oledDark }

enum DesktopAccentColorSource { system, gtk, qt }

class ThemeSettings {
  const ThemeSettings({
    required this.themeMode,
    required this.useDynamicColor,
    required this.desktopAccentColorSource,
    required this.customSeedColor,
  });

  final AppThemeMode themeMode;
  final bool useDynamicColor;
  final DesktopAccentColorSource desktopAccentColorSource;
  final Color customSeedColor;

  ThemeSettings copyWith({
    AppThemeMode? themeMode,
    bool? useDynamicColor,
    DesktopAccentColorSource? desktopAccentColorSource,
    Color? customSeedColor,
  }) {
    return ThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      useDynamicColor: useDynamicColor ?? this.useDynamicColor,
      desktopAccentColorSource:
          desktopAccentColorSource ?? this.desktopAccentColorSource,
      customSeedColor: customSeedColor ?? this.customSeedColor,
    );
  }

  static const String _keyThemeMode = 'app_theme_mode';
  static const String _keyDynamicColor = 'app_dynamic_color';
  static const String _keyDesktopAccentColorSource =
      'app_desktop_accent_color_source';
  static const String _keyCustomSeedColor = 'app_custom_seed_color';
  static const Color _defaultSeedColor = Color(0xFF6750A4);

  static ThemeSettings load() {
    final prefs = SharedPrefsService.instance;
    final rawThemeMode = prefs.getString(_keyThemeMode);
    final rawDesktopAccentColorSource = prefs.getString(
      _keyDesktopAccentColorSource,
    );
    return ThemeSettings(
      themeMode: _enumByName(
        AppThemeMode.values,
        rawThemeMode,
        AppThemeMode.system,
      ),
      desktopAccentColorSource: _enumByName(
        DesktopAccentColorSource.values,
        rawDesktopAccentColorSource,
        DesktopAccentColorSource.system,
      ),
      useDynamicColor: prefs.getBool(_keyDynamicColor) ?? true,
      customSeedColor: Color(
        prefs.getInt(_keyCustomSeedColor) ?? _defaultSeedColor.toARGB32(),
      ),
    );
  }

  Future<void> save() async {
    final prefs = SharedPrefsService.instance;
    await prefs.setString(_keyThemeMode, themeMode.name);
    await prefs.setBool(_keyDynamicColor, useDynamicColor);
    await prefs.setString(
      _keyDesktopAccentColorSource,
      desktopAccentColorSource.name,
    );
    await prefs.setInt(_keyCustomSeedColor, customSeedColor.toARGB32());
  }

  ThemeMode get materialThemeMode {
    return switch (themeMode) {
      AppThemeMode.light => ThemeMode.light,
      AppThemeMode.dark || AppThemeMode.oledDark => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  bool get isOledDark => themeMode == AppThemeMode.oledDark;

  static T _enumByName<T extends Enum>(
    Iterable<T> values,
    String? name,
    T fallback,
  ) {
    if (name == null) {
      return fallback;
    }
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return fallback;
  }
}

class ThemeSettingsNotifier extends Notifier<ThemeSettings> {
  @override
  ThemeSettings build() => ThemeSettings.load();

  Future<void> setThemeMode(AppThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await state.save();
  }

  Future<void> setDynamicColor(bool value) async {
    state = state.copyWith(useDynamicColor: value);
    await state.save();
  }

  Future<void> setDesktopAccentColorSource(
    DesktopAccentColorSource source,
  ) async {
    state = state.copyWith(desktopAccentColorSource: source);
    await state.save();
  }

  Future<void> setCustomSeedColor(Color color) async {
    state = state.copyWith(customSeedColor: color);
    await state.save();
  }
}

final themeSettingsProvider =
    NotifierProvider<ThemeSettingsNotifier, ThemeSettings>(
      ThemeSettingsNotifier.new,
    );

enum AppLocale { system, en, zh, zhHant, ja, ru }

class LocaleSettings {
  const LocaleSettings({required this.locale});

  final AppLocale locale;

  static Locale? currentActiveLocale;

  static Locale resolveActiveLocale() {
    if (currentActiveLocale != null) return currentActiveLocale!;
    try {
      final configured = load().materialLocale;
      if (configured != null) {
        currentActiveLocale = configured;
        return configured;
      }
    } catch (_) {}
    return PlatformDispatcher.instance.locale;
  }

  LocaleSettings copyWith({AppLocale? locale}) {
    return LocaleSettings(locale: locale ?? this.locale);
  }

  static const String _keyLocale = 'app_locale';

  static LocaleSettings load() {
    final prefs = SharedPrefsService.instance;
    final raw = prefs.getString(_keyLocale);
    final settings = LocaleSettings(
      locale: AppLocale.values.byName(raw ?? AppLocale.system.name),
    );
    currentActiveLocale = settings.materialLocale;
    return settings;
  }

  Future<void> save() async {
    await SharedPrefsService.instance.setString(_keyLocale, locale.name);
  }

  Locale? get materialLocale {
    return switch (locale) {
      AppLocale.en => const Locale('en'),
      AppLocale.zh => const Locale('zh'),
      AppLocale.zhHant => const Locale('zh', 'TW'),
      AppLocale.ja => const Locale('ja'),
      AppLocale.ru => const Locale('ru'),
      _ => null,
    };
  }
}

class LocaleSettingsNotifier extends Notifier<LocaleSettings> {
  @override
  LocaleSettings build() {
    final loaded = LocaleSettings.load();
    LocaleSettings.currentActiveLocale = loaded.materialLocale;
    return loaded;
  }

  Future<void> setLocale(AppLocale locale) async {
    state = state.copyWith(locale: locale);
    LocaleSettings.currentActiveLocale = state.materialLocale;
    await state.save();
  }
}

final localeSettingsProvider =
    NotifierProvider<LocaleSettingsNotifier, LocaleSettings>(
      LocaleSettingsNotifier.new,
    );
