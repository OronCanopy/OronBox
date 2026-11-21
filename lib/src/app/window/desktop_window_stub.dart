import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:oronbox/src/app/window/window_launch_spec.dart';

Future<void> initializeDesktopWindow({
  WindowLaunchSpec spec = const WindowLaunchSpec(),
}) async {}

class DesktopWindowHost extends StatelessWidget {
  const DesktopWindowHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class SecondaryWindowHost extends StatelessWidget {
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
  Widget build(BuildContext context) => child;
}

bool get supportsSecondaryWindows => false;
Stream<List<String>> get primaryLaunchArguments => const Stream.empty();

Future<bool> initializeWindowCoordinator(
  WindowLaunchSpec spec, {
  List<String> launchArguments = const [],
}) async => true;

Future<void> notifySecondaryWindowReady() async {}
Future<bool> openDebugWindow() async => false;
Future<void> closeSecondaryWindow() async {}
Future<bool> closeDebugWindow() async => false;
Future<bool> openPluginWindow(String pluginId) async => false;
Future<bool> takePluginWindow(String pluginId) async => true;
Future<String> createWebViewWindow(String id) async =>
    throw UnsupportedError('Desktop windows are unavailable');
Future<void> closeWebViewWindow(String id) async {}
Future<void> focusSecondaryWindow() async {}
Future<void> setSecondaryWindowIcon(String? base64Icon) async {}
Future<void> setSecondaryWindowTitle(String title) async {}
Future<void> shutdownSecondaryWindows() async {}
Future<void> reportSecondaryWindowBounds({
  required String role,
  required double width,
  required double height,
  required double x,
  required double y,
}) async {}

Future<void> closeDesktopWindow() async {}
void dragDesktopWindow() {}
