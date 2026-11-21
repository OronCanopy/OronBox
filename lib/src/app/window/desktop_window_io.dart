import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Pointer, Void;
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as image;
import 'package:material_ui/material_ui.dart' hide Image;
import 'package:window_manager/window_manager.dart' as nativeapi;
import 'package:window_manager/window_manager.dart'
    show SizeToNative, OffsetToNative;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';
import 'package:oronbox/src/app/router/app_router.dart';
import 'package:oronbox/src/app/window/debug_window_preference.dart';
import 'package:oronbox/src/app/window/window_launch_spec.dart';
import 'package:oronbox/src/core/services/shared_prefs_service.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

nativeapi.Window? _mainWindow;
nativeapi.Window? _secondaryWindow;
Future<void> Function()? _closeSecondary;

Future<void> closeDesktopWindow() async {
  if (_secondaryWindow != null) {
    await closeSecondaryWindow();
  } else if (_mainWindow case final window?) {
    if (nativeapi.Window.isCloseSupported()) {
      window.close();
    } else {
      _onUnsupportedWindowClose?.call();
    }
  }
}

VoidCallback? _onUnsupportedWindowClose;

void dragDesktopWindow() {
  (_secondaryWindow ?? _mainWindow)?.startDragging();
}

Future<void> initializeDesktopWindow({
  WindowLaunchSpec spec = const WindowLaunchSpec(),
}) async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
  if (spec.isSecondary) {
    final address = await const MethodChannel(
      'org.oroncanopy.oronbox/window_handle',
    ).invokeMethod<int>('get');
    if (address == null || address == 0) {
      throw StateError('Secondary window unavailable');
    }
    _secondaryWindow = nativeapi.Window.createWithNativeWindow(
      Pointer<Void>.fromAddress(address),
    );
    if (_secondaryWindow == null) {
      throw StateError('Secondary window unavailable');
    }
  } else {
    _mainWindow = nativeapi.WindowManager.instance.getCurrent();
  }
  final window = _secondaryWindow ?? _mainWindow;
  if (window == null) return;
  final secondary = spec.isSecondary;
  final role = spec.storageKey;
  final prefs = SharedPrefsService.instance;
  final savedWidth = prefs.getDouble('window.$role.width');
  final savedHeight = prefs.getDouble('window.$role.height');
  final defaultSize = switch (spec.role) {
    OronBoxWindowRole.debug => const Size(1000, 650),
    OronBoxWindowRole.plugin => const Size(1100, 760),
    OronBoxWindowRole.webview => const Size(900, 720),
    OronBoxWindowRole.main => const Size(1280, 720),
  };
  final minimumSize = switch (spec.role) {
    OronBoxWindowRole.debug => const Size(640, 520),
    _ => const Size(720, 520),
  };
  final wasFrameless = !secondary && Platform.isMacOS && window.isFrameless;
  window.titleBarStyle = secondary
      ? nativeapi.TitleBarStyle.normal
      : nativeapi.TitleBarStyle.hidden;
  if (!secondary) {
    window.isWindowControlButtonsVisible = Platform.isMacOS;
    if (wasFrameless) window.hasShadow = true;
    if (window.isFullScreen) window.isFullScreen = false;
    if (window.isMaximized) window.unmaximize();
    if (window.isMinimized) window.restore();
  }
  final size = savedWidth != null && savedHeight != null
      ? Size(savedWidth, savedHeight)
      : defaultSize;
  window.setSize(size.toNative(), false);
  window.minimumSize = minimumSize.toNative();
  window.title = switch (spec.role) {
    OronBoxWindowRole.debug => 'OronBox Debug',
    OronBoxWindowRole.plugin => 'OronBox Plugin',
    OronBoxWindowRole.webview || OronBoxWindowRole.main => 'OronBox',
  };
  final x = prefs.getDouble('window.$role.x');
  final y = prefs.getDouble('window.$role.y');
  if (x != null && y != null) {
    window.position = Offset(x, y).toNative();
  } else {
    window.center();
  }
  if (window.isMinimized) window.restore();
  window.show();
  window.focus();
}

class DesktopWindowHost extends ConsumerStatefulWidget {
  const DesktopWindowHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DesktopWindowHost> createState() => _DesktopWindowHostState();
}

class _DesktopWindowHostState extends ConsumerState<DesktopWindowHost> {
  static const _exitBehaviorKey = 'desktop.exit_behavior';
  bool _initialized = false;
  bool _showingDialog = false;
  bool _exiting = false;
  AppLifecycleListener? _lifecycleListener;
  nativeapi.ListenerId? _windowListenerId;
  TrayIcon? _trayIcon;
  Image? _trayImage;
  Menu? _trayMenu;
  MenuItem? _showMenuItem;
  MenuItem? _exitMenuItem;
  ListenerId? _trayListenerId;
  ListenerId? _showMenuListenerId;
  ListenerId? _exitMenuListenerId;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized && _isDesktop) {
      _initialized = true;
      _initialize();
    }
  }

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      _lifecycleListener = AppLifecycleListener(
        onExitRequested: () async {
          unawaited(_exitApplication());
          return AppExitResponse.cancel;
        },
      );
    }
  }

  Future<void> _initialize() async {
    final l10n = AppLocalizations.of(context)!;
    _onUnsupportedWindowClose = _onWindowClose;
    _windowListenerId = _mainWindow?.addListener((event) {
      if (event is nativeapi.WindowCloseRequestedEvent) {
        event.request.cancel();
        _onWindowClose();
      }
    });
    final icon = switch (Platform.operatingSystem) {
      'macos' => 'assets/images/tray_icon_macos.png',
      'windows' => 'assets/images/tray_icon.ico',
      _ => 'assets/images/tray_icon.png',
    };
    final trayIcon = TrayIcon.create();
    if (trayIcon == null) return;
    _trayIcon = trayIcon;
    trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
    if (Platform.isMacOS) trayIcon.isIconTemplate = true;
    final trayImage = ImageAsset.fromAsset(icon);
    if (trayImage != null) {
      _trayImage = trayImage;
      trayIcon.icon = trayImage;
    }
    trayIcon.setVisible(true);
    if (!Platform.isLinux) trayIcon.setTooltip('OronBox');

    final menu = Menu.create();
    final showItem = MenuItem.createWithLabelAndType(
      l10n.desktopTrayShow,
      MenuItemType.normal,
    );
    final exitItem = MenuItem.createWithLabelAndType(
      l10n.desktopTrayExit,
      MenuItemType.normal,
    );
    _trayMenu = menu;
    _showMenuItem = showItem;
    _exitMenuItem = exitItem;
    if (menu == null || showItem == null || exitItem == null) {
      _disposeTray();
      return;
    }
    menu
      ..addItem(showItem)
      ..addSeparator()
      ..addItem(exitItem);
    trayIcon.setContextMenu(menu);
    _showMenuListenerId = showItem.addListener((event) {
      if (event is MenuItemClickedEvent) unawaited(_showWindow());
    });
    _exitMenuListenerId = exitItem.addListener((event) {
      if (event is MenuItemClickedEvent) unawaited(_exitApplication());
    });
    _trayListenerId = trayIcon.addListener((event) {
      if (event is TrayIconClickedEvent) unawaited(_showWindow());
    });
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    if (_isDesktop) {
      if (_windowListenerId case final listener?) {
        _mainWindow?.removeListener(listener);
      }
      _onUnsupportedWindowClose = null;
      _disposeTray();
    }
    super.dispose();
  }

  void _disposeTray() {
    final trayIcon = _trayIcon;
    if (trayIcon != null) {
      if (_trayListenerId case final listenerId?) {
        trayIcon.removeListener(listenerId);
      }
      trayIcon.setContextMenu(null);
    }
    if (_showMenuListenerId case final listenerId?) {
      _showMenuItem?.removeListener(listenerId);
    }
    if (_exitMenuListenerId case final listenerId?) {
      _exitMenuItem?.removeListener(listenerId);
    }
    _trayMenu?.dispose();
    _showMenuItem?.dispose();
    _exitMenuItem?.dispose();
    _trayImage?.dispose();
    _trayIcon?.dispose();
    _trayListenerId = null;
    _showMenuListenerId = null;
    _exitMenuListenerId = null;
    _trayMenu = null;
    _showMenuItem = null;
    _exitMenuItem = null;
    _trayImage = null;
    _trayIcon = null;
  }

  Future<void> _showWindow() async {
    final window = _mainWindow;
    if (window == null) return;
    if (window.isMinimized) window.restore();
    window.show();
    window.focus();
  }

  Future<void> _exitApplication() async {
    if (_exiting) return;
    _exiting = true;
    final host = ref.read(applicationHostProvider);
    final forcedExit = Timer(const Duration(seconds: 8), () => exit(0));
    try {
      _mainWindow?.hide();
    } catch (_) {}
    try {
      await shutdownSecondaryWindows().timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await host.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _disposeTray();
    forcedExit.cancel();
    exit(0);
  }

  void _onWindowClose() {
    final behavior = SharedPrefsService.instance.getInt(_exitBehaviorKey);
    if (behavior == 0) {
      unawaited(_exitApplication());
    } else if (behavior == 1) {
      _mainWindow?.hide();
    } else {
      unawaited(_askCloseBehavior());
    }
  }

  Future<void> _askCloseBehavior() async {
    if (_showingDialog || !mounted) return;
    final navigatorContext = rootNavigatorKey.currentContext;
    if (navigatorContext == null) {
      _mainWindow?.hide();
      return;
    }
    _showingDialog = true;
    var remember = false;
    final l10n = AppLocalizations.of(navigatorContext)!;
    await showDialog<void>(
      context: navigatorContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.desktopCloseTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.desktopCloseMessage),
              const SizedBox(height: 24),
              AppCheckboxRow(
                value: remember,
                onChanged: (value) => setState(() => remember = value ?? false),
                title: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 8),
                  child: Text(l10n.desktopCloseRemember),
                ),
                expanded: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (remember) {
                  await SharedPrefsService.instance.setInt(_exitBehaviorKey, 0);
                }
                await _exitApplication();
              },
              child: Text(l10n.desktopCloseExit),
            ),
            TextButton(
              onPressed: () async {
                if (remember) {
                  await SharedPrefsService.instance.setInt(_exitBehaviorKey, 1);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                _mainWindow?.hide();
              },
              child: Text(l10n.desktopCloseToTray),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.settingsCancel),
            ),
          ],
        ),
      ),
    );
    _showingDialog = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class SecondaryWindowHost extends StatefulWidget {
  const SecondaryWindowHost({
    super.key,
    required this.role,
    required this.child,
    this.onClose,
  });
  final String role;
  final Widget child;
  final Future<void> Function()? onClose;

  @override
  State<SecondaryWindowHost> createState() => _SecondaryWindowHostState();
}

class _SecondaryWindowHostState extends State<SecondaryWindowHost> {
  Timer? _saveTimer;
  nativeapi.ListenerId? _listener;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _closeSecondary = _close;
    _listener = _secondaryWindow?.addListener((event) {
      if (event is nativeapi.WindowCloseRequestedEvent) {
        if (!_closing) {
          event.request.cancel();
          unawaited(_close());
        }
      } else if (event is nativeapi.WindowResizedEvent ||
          event is nativeapi.WindowMovedEvent) {
        _saveTimer?.cancel();
        _saveTimer = Timer(const Duration(milliseconds: 250), _saveBounds);
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_listener case final listener?) {
      _secondaryWindow?.removeListener(listener);
    }
    _closeSecondary = null;
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    if (widget.role == 'debug') await setDebugWindowEnabled(false);
    await widget.onClose?.call();
    _secondaryWindow?.close();
  }

  Future<void> _saveBounds() async {
    final window = _secondaryWindow;
    if (window == null || _closing) return;
    final size = window.size;
    final position = window.position;
    await reportSecondaryWindowBounds(
      role: widget.role,
      width: size.width,
      height: size.height,
      x: position.x,
      y: position.y,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

bool get supportsSecondaryWindows =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

final _coordinator = _WindowCoordinator();

final _pendingPrimaryLaunchArguments = <List<String>>[];
final StreamController<List<String>> _primaryLaunchArguments =
    StreamController<List<String>>.broadcast(
      onListen: () {
        for (final arguments in _pendingPrimaryLaunchArguments) {
          _primaryLaunchArguments.add(arguments);
        }
        _pendingPrimaryLaunchArguments.clear();
      },
    );
Stream<List<String>> get primaryLaunchArguments =>
    _primaryLaunchArguments.stream;

void _emitPrimaryLaunchArguments(List<String> arguments) {
  if (_primaryLaunchArguments.hasListener) {
    _primaryLaunchArguments.add(arguments);
  } else {
    _pendingPrimaryLaunchArguments.add(arguments);
  }
}

Future<bool> initializeWindowCoordinator(
  WindowLaunchSpec spec, {
  List<String> launchArguments = const [],
}) async {
  if (!supportsSecondaryWindows) return true;
  if (spec.isSecondary) {
    await _setupSecondaryWindowHandler();
    return true;
  } else {
    if (launchArguments.isNotEmpty) {
      _emitPrimaryLaunchArguments(launchArguments);
    }
    return _coordinator.initialize(launchArguments: launchArguments);
  }
}

Future<void> _setupSecondaryWindowHandler() async {
  try {
    final controller = await WindowController.fromCurrentEngine();
    await controller.setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'focus':
          await focusSecondaryWindow();
          return true;
        case 'close':
          await closeSecondaryWindow();
          return true;
        default:
          return null;
      }
    });
  } catch (_) {}
}

Future<void> notifySecondaryWindowReady() async {
  await _setupSecondaryWindowHandler();
}

Future<bool> openDebugWindow() =>
    _coordinator.open(key: 'debug', role: 'debug');

Future<void> closeSecondaryWindow() async {
  if (_closeSecondary case final close?) {
    await close();
  } else {
    _secondaryWindow?.close();
  }
}

Future<bool> closeDebugWindow() => _coordinator.close('debug');

Future<bool> openPluginWindow(String pluginId) => _coordinator.open(
  key: 'plugin:$pluginId',
  role: 'plugin',
  targetId: pluginId,
);

Future<bool> takePluginWindow(String pluginId) =>
    _coordinator.close('plugin:$pluginId');

Future<String> createWebViewWindow(String id) async {
  final key = 'webview:$id';
  if (!await _coordinator.open(key: key, role: 'webview', targetId: id)) {
    throw StateError('WebView window could not be opened');
  }
  return _coordinator._controllers[key]!.windowId;
}

Future<void> closeWebViewWindow(String id) async {
  await _coordinator.close('webview:$id');
}

Future<void> focusSecondaryWindow() async {
  final window = _secondaryWindow;
  if (window == null) return;
  window.show();
  if (window.isMinimized) window.restore();
  window.focus();
}

Future<void> setSecondaryWindowIcon(String? base64Icon) async {
  if (base64Icon == null || base64Icon.isEmpty) return;
  try {
    if (Platform.isMacOS) {
      await const MethodChannel('org.oroncanopy.oronbox/window')
          .invokeMethod<void>('setIcon', base64Icon);
      return;
    }
    if (!Platform.isWindows && !Platform.isLinux) return;
    final bytes = base64Decode(base64Icon);
    final directory = await getTemporaryDirectory();
    final extension = Platform.isWindows ? 'ico' : 'png';
    final file = File(
      '${directory.path}${Platform.pathSeparator}oronbox-plugin-window-icon-$pid.$extension',
    );
    if (Platform.isWindows) {
      final decoded = image.decodeImage(bytes);
      if (decoded == null) throw const FormatException('Invalid plugin icon');
      await file.writeAsBytes(
        image.encodeIco(image.copyResize(decoded, width: 256, height: 256)),
        flush: true,
      );
    } else {
      await file.writeAsBytes(bytes, flush: true);
    }
    await const MethodChannel('window_manager')
        .invokeMethod<void>('setIcon', {'iconPath': file.path});
  } on MissingPluginException {
    // Runtime window icons are only available on runners that implement them.
  } on PlatformException {
    // A malformed optional icon must not prevent the plugin UI from opening.
  } on FormatException {
    // Ignore invalid optional plugin artwork.
  } on FileSystemException {
    // An unwritable temporary directory must not block the plugin UI.
  } catch (_) {
    // Window artwork is optional and must never prevent a plugin from opening.
  }
}

Future<void> setSecondaryWindowTitle(String title) async {
  if (title.isEmpty) return;
  _secondaryWindow?.title = title;
}

Future<void> shutdownSecondaryWindows() => _coordinator.shutdown();

Future<void> reportSecondaryWindowBounds({
  required String role,
  required double width,
  required double height,
  required double x,
  required double y,
}) async {
  final prefs = SharedPrefsService.instance;
  await prefs.setDouble('window.$role.width', width);
  await prefs.setDouble('window.$role.height', height);
  await prefs.setDouble('window.$role.x', x);
  await prefs.setDouble('window.$role.y', y);
}

class _WindowCoordinator {
  final Map<String, WindowController> _controllers = {};
  StreamSubscription<void>? _windowsChangedSub;
  bool _initialized = false;

  Future<bool> initialize({List<String> launchArguments = const []}) async {
    if (_initialized) return true;
    _initialized = true;
    _windowsChangedSub = onWindowsChanged.listen((_) => _pruneControllers());
    return true;
  }

  Future<void> _pruneControllers() async {
    try {
      final all = await WindowController.getAll();
      final activeIds = all.map((c) => c.windowId).toSet();
      _controllers.removeWhere(
        (key, controller) => !activeIds.contains(controller.windowId),
      );
    } catch (_) {}
  }

  Future<bool> open({
    required String key,
    required String role,
    String? targetId,
  }) async {
    if (!supportsSecondaryWindows) return false;
    await initialize();

    final existing = _controllers[key];
    if (existing != null) {
      try {
        await existing.invokeMethod('focus');
        return true;
      } catch (_) {
        _controllers.remove(key);
      }
    }

    try {
      final payload = jsonEncode({
        'role': role,
        if (targetId != null) 'targetId': targetId,
      });
      final controller = await WindowController.create(
        WindowConfiguration(arguments: payload, hiddenAtLaunch: true),
      );
      _controllers[key] = controller;
      await controller.show();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> close(String key) async {
    final controller = _controllers.remove(key);
    if (controller == null) return true;
    try {
      await controller.invokeMethod('close');
    } catch (_) {}
    return true;
  }

  Future<void> shutdown() async {
    final controllers = {
      for (final value in _controllers.values) value.windowId: value,
    };
    for (final window in await WindowController.getAll()) {
      if (window.arguments.contains('"role":"webview"')) {
        controllers[window.windowId] = window;
      }
    }
    _controllers.clear();
    for (final controller in controllers.values) {
      try {
        await controller.invokeMethod('close');
      } catch (_) {}
    }
    await _windowsChangedSub?.cancel();
    _windowsChangedSub = null;
    _initialized = false;
  }
}
