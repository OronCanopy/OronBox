import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/router/app_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';
import 'package:oronbox/src/app/theme/system_accent_color.dart';
import 'package:oronbox/src/app/window/desktop_window.dart';
import 'package:oronbox/src/core/providers/theme_locale_providers.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_detail_page.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_management_page.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_host_request_handler.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_browser_sessions.dart';

final _pluginWindowRouterProvider = Provider.autoDispose
    .family<GoRouter, String>((ref, pluginId) {
      final router = GoRouter(
        navigatorKey: rootNavigatorKey,
        initialLocation: '/plugins/${Uri.encodeComponent(pluginId)}',
        routes: [
          GoRoute(
            path: '/plugins/:id',
            builder: (context, state) =>
                PluginDetailPage(pluginId: pluginId, allowDetach: false),
          ),
          pluginBrowserRoute(
            fallbackLocation: '/plugins/${Uri.encodeComponent(pluginId)}',
          ),
          GoRoute(
            path: '/plugins/:id/manage',
            builder: (context, state) =>
                PluginManagementPage(pluginId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: '/plugins/:id/page',
            builder: (context, state) {
              final args = state.extra as PluginUiRouteArgs?;
              return PluginUiPage(
                pluginId: state.pathParameters['id']!,
                preview: args?.nodes,
                title: args?.title ?? '',
              );
            },
          ),
        ],
      );
      ref.onDispose(router.dispose);
      return router;
    });

final _desktopAccentColorProvider = FutureProvider<Color?>((ref) {
  final source = ref.watch(
    themeSettingsProvider.select((settings) {
      return settings.desktopAccentColorSource;
    }),
  );
  return loadDesktopAccentColor(source);
});

class PluginWindowApp extends ConsumerWidget {
  const PluginWindowApp({super.key, required this.pluginId});
  final String pluginId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSettings = ref.watch(themeSettingsProvider);
    final router = ref.watch(_pluginWindowRouterProvider(pluginId));
    final localeSettings = ref.watch(localeSettingsProvider);
    final desktopAccentColor = ref
        .watch(_desktopAccentColorProvider)
        .maybeWhen(data: (color) => color, orElse: () => null);

    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final useDynamicColor = themeSettings.useDynamicColor;
        final lightColorScheme = useDynamicColor
            ? lightDynamic ?? _colorScheme(desktopAccentColor, Brightness.light)
            : _colorScheme(themeSettings.customSeedColor, Brightness.light);
        final darkColorScheme = useDynamicColor
            ? darkDynamic ?? _colorScheme(desktopAccentColor, Brightness.dark)
            : _colorScheme(themeSettings.customSeedColor, Brightness.dark);

        return MaterialApp.router(
          title: 'OronBox Plugin',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.buildLightTheme(colorScheme: lightColorScheme),
          darkTheme: themeSettings.isOledDark
              ? AppTheme.buildOledDarkTheme(colorScheme: darkColorScheme)
              : AppTheme.buildDarkTheme(colorScheme: darkColorScheme),
          themeMode: themeSettings.materialThemeMode,
          locale: localeSettings.materialLocale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => OronBoxScaffoldMessenger(
            child: SecondaryWindowHost(
              role: 'plugin.$pluginId',
              child: PluginHostRequestHandler(
                reportLifecycle: false,
                pluginId: pluginId,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }

  ColorScheme? _colorScheme(Color? seedColor, Brightness brightness) {
    if (seedColor == null) return null;
    return ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
  }
}
