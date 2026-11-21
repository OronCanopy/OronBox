import 'package:oronbox/src/app/generated/app_localizations.dart';

String pluginPermissionLabel(AppLocalizations l10n, String capability) =>
    switch (capability) {
      'ui' => l10n.pluginFeatures,
      'file' => l10n.pluginPermissionPickFile,
      'mass.firmware' => l10n.deviceFeaturesInstallFirmware,
      'device' || 'os.device-id' => l10n.pluginPermissionReadDevice,
      'interconnect' ||
      'register_interconnect_recv' => l10n.pluginPermissionInterconnect,
      'request' ||
      'notification' ||
      'canopusconnect.send' => l10n.pluginPermissionSendProtocol,
      'protocol' ||
      'register_transport_recv' ||
      'canopusconnect.listen' => l10n.pluginPermissionObserveProtocol,
      'thirdpartyapp' ||
      'watchface' ||
      'queue' => l10n.pluginPermissionOperateDevice,
      'mass' => l10n.pluginPermissionOperateDevice,
      'provider' || 'register_provider' => l10n.pluginPermissionProvider,
      'register_deeplink_action' => l10n.pluginPermissionReceiveLink,
      'browser' => l10n.pluginPermissionOpenExternal,
      'http-server' || 'http-server.lan' => l10n.pluginPermissionHostServer,
      'clipboard.read' => l10n.pluginPermissionReadClipboard,
      'clipboard.write' => l10n.pluginPermissionWriteClipboard,
      'appside' => l10n.pluginPermissionOperateAppSide,
      _ => capability,
    };

String pluginPermissionOperationLabel(
  AppLocalizations l10n,
  Map<String, Object?> request,
) {
  final method = request['operation']?.toString() ?? '';
  return switch (method) {
    'dialog.open-url' ||
    'browser.open' ||
    'ui.openExternal' => l10n.pluginPermissionOpenExternal,
    'clipboard.read-text' => l10n.pluginPermissionReadClipboard,
    'clipboard.write-text' => l10n.pluginPermissionWriteClipboard,
    'http-server.start' => l10n.pluginPermissionHostServer,
    'register.register-deeplink-action' => l10n.pluginPermissionReceiveLink,
    'interconnect.send' ||
    'interconnect.observe' ||
    'interconnect.send-qaic-message' ||
    'register.register-interconnect-recv' => l10n.pluginPermissionInterconnect,
    'register.register-provider' ||
    'provider.register' ||
    'provider.unregister' => l10n.pluginPermissionProvider,
    'device.list' ||
    'device.info' ||
    'device.apps.list' ||
    'watchface.list' ||
    'device.get-device-list' ||
    'device.get-connected-device-list' ||
    'thirdpartyapp.get-thirdparty-app-list' ||
    'watchface.get-watchface-list' ||
    'os.device-id' => l10n.pluginPermissionReadDevice,
    'device.connect' ||
    'device.disconnect' ||
    'device.apps.launch' ||
    'device.apps.uninstall' ||
    'device.install' ||
    'watchface.set' ||
    'device.disconnect-device' ||
    'thirdpartyapp.launch-qa' ||
    'queue.add-resource-to-queue' ||
    'watchface.set-current-watchface' => l10n.pluginPermissionOperateDevice,
    'protocol.observe' ||
    'register.register-transport-recv' ||
    'canopusconnect.listen' => l10n.pluginPermissionObserveProtocol,
    'protocol.send' ||
    'protocol.request' ||
    'transport.send' ||
    'transport.request' ||
    'canopusconnect.send' ||
    'notification.send' ||
    'notification.remove' => l10n.pluginPermissionSendProtocol,
    'file.pick' ||
    'file.read' ||
    'file.write' ||
    'file.list' ||
    'file.stat' ||
    'file.mkdir' ||
    'file.copy' ||
    'file.move' ||
    'file.remove' => l10n.pluginPermissionPickFile,
    'file.unload' => l10n.pluginPermissionExportFile,
    'ui.dialog' => l10n.pluginFeatures,
    _ => pluginPermissionLabel(l10n, request['capability']?.toString() ?? ''),
  };
}
