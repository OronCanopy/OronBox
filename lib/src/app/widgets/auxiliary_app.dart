import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/theme/system_accent_color.dart';
import 'package:oronbox/src/core/providers/theme_locale_providers.dart';

final _accentColor = FutureProvider<Color?>(
  (ref) => loadDesktopAccentColor(
    ref.watch(
      themeSettingsProvider.select((value) => value.desktopAccentColorSource),
    ),
  ),
);

class AuxiliaryApp extends ConsumerWidget {
  const AuxiliaryApp({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeSettingsProvider);
    final locale = ref.watch(localeSettingsProvider);
    final accent = ref.watch(_accentColor).asData?.value;
    ColorScheme? colors(Brightness brightness) {
      final seed = theme.useDynamicColor ? accent : theme.customSeedColor;
      return seed == null
          ? null
          : ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    }

    return DynamicColorBuilder(
      builder: (light, dark) => MaterialApp(
        title: 'OronBox',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.buildLightTheme(
          colorScheme: theme.useDynamicColor
              ? light ?? colors(Brightness.light)
              : colors(Brightness.light),
        ),
        darkTheme: theme.isOledDark
            ? AppTheme.buildOledDarkTheme(
                colorScheme: theme.useDynamicColor
                    ? dark ?? colors(Brightness.dark)
                    : colors(Brightness.dark),
              )
            : AppTheme.buildDarkTheme(
                colorScheme: theme.useDynamicColor
                    ? dark ?? colors(Brightness.dark)
                    : colors(Brightness.dark),
              ),
        themeMode: theme.materialThemeMode,
        locale: locale.materialLocale,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: child,
      ),
    );
  }
}
