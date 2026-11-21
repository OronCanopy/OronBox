import 'dart:async';

import 'package:oronbox/src/core/wasm/wasm_compatibility.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:oronbox/src/core/services/private_app_state.dart';
import 'package:oronbox/src/features/settings/services/legal_agreements.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oronbox/src/app/oronbox_app.dart';
import 'package:oronbox/src/app/window/desktop_window.dart';
import 'package:oronbox/src/core/logging/logging_service.dart';
import 'package:oronbox/src/core/logging/diagnostic_event.dart';
import 'package:oronbox/src/core/services/license_registry_service.dart';
import 'package:oronbox/src/core/services/bluetooth_permission_bootstrap.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/host/gui_host_overrides.dart';
import 'package:oronbox/src/app/integrations/app_link_handler.dart';
import 'package:oronbox/src/features/debug/pages/debug_window_app.dart';
import 'package:oronbox/src/app/widgets/private_state_gate.dart';
import 'package:oronbox/src/features/plugins/pages/plugin_window_app.dart';
import 'package:oronbox/src/features/devices/health/health_store.dart';
import 'package:oronbox/src/app/webview/webview_window_app.dart';
import 'package:oronbox/src/features/accounts/services/bandbbs_browser_authorization.dart';
import 'package:oronbox/src/features/accounts/pages/bandbbs_browser_callback_app.dart';

void main(List<String> args) async {
  final startupStopwatch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  if (isBandBbsBrowserCallback) {
    await SharedPrefsService.instance.init();
    runApp(const ProviderScope(child: BandBbsBrowserCallbackApp()));
    return;
  }
  final window = WindowLaunchSpec.parse(args);
  final process = switch (window.role) {
    OronBoxWindowRole.debug => DiagnosticProcess.debugWindow,
    OronBoxWindowRole.plugin => DiagnosticProcess.pluginWindow,
    OronBoxWindowRole.webview => DiagnosticProcess.frontend,
    OronBoxWindowRole.main => DiagnosticProcess.frontend,
  };
  await initLogging(arguments: args, process: process);
  installGlobalErrorLogging();
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarColor: Colors.transparent,
      ),
    );
  }
  await SharedPrefsService.instance.init();
  if (window.role == OronBoxWindowRole.webview) {
    await initializeWindowCoordinator(window);
    await initializeDesktopWindow(spec: window);
    runApp(ProviderScope(child: WebViewWindowApp(id: window.targetId ?? '')));
    return;
  }
  try {
    await WasmCompatibility.shared.initialize();
  } catch (error, stack) {
    getLogger('Application')
        .warning('Wasm compatibility state unavailable', error, stack);
  }
  unawaited(PrivateAppState.instance.initialize().catchError((_) {}));
  if (!await initializeWindowCoordinator(window, launchArguments: args)) return;
  if (window.role == OronBoxWindowRole.main) {
    await requestBluetoothPermissionOnStartup();
  }
  await initializeDesktopWindow(spec: window);
  runApp(
    ProviderScope(
      overrides: [
        ...guiHostOverrides(),
        initialDeepLinksProvider.overrideWithValue(args),
      ],
      child: PrivateStateGate(
        child: switch (window.role) {
          OronBoxWindowRole.debug => const DebugWindowApp(),
          OronBoxWindowRole.plugin => PluginWindowApp(
            pluginId: window.targetId ?? '',
          ),
          OronBoxWindowRole.webview => throw StateError(
            'WebView has a dedicated entry point',
          ),
          OronBoxWindowRole.main => const OronBoxApp(),
        },
      ),
    ),
  );
  if (window.role == OronBoxWindowRole.main) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(HealthStore().resetForStorageMigration());
      unawaited(LicenseRegistryService.registerThirdPartyLicenses());
      unawaited(LegalAgreements.refreshManifest());
    });
  }
  startupStopwatch.stop();
  logDiagnostic(
    getLogger('Application'),
    Level.INFO,
    'OronBox startup completed',
    fields: {
      'durationMs': startupStopwatch.elapsedMilliseconds,
      'role': process.name,
    },
  );
  if (window.isSecondary) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(notifySecondaryWindowReady());
    });
  }
  if (window.role == OronBoxWindowRole.main &&
      !args.contains('--nogui') &&
      supportsSecondaryWindows &&
      isDebugWindowEnabled()) {
    unawaited(() async {
      if (!await openDebugWindow()) {
        await setDebugWindowEnabled(false);
      }
    }());
  }
}
