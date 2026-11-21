import 'package:file_picker/file_picker.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segmented_list/segmented_list.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_scaffold_messenger.dart';
import 'package:oronbox/src/app/widgets/dialog_helper.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/commands/command_protocol.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:oronbox/src/device/core/device_state.dart';
import 'package:oronbox/src/device/core/device_kind.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';
import 'package:oronbox/src/host/application_host_provider.dart';

class MiWearEngineeringPage extends ConsumerStatefulWidget {
  const MiWearEngineeringPage({super.key});
  @override
  ConsumerState<MiWearEngineeringPage> createState() =>
      _MiWearEngineeringPageState();
}

class _MiWearEngineeringPageState extends ConsumerState<MiWearEngineeringPage> {
  late final _host = ref.read(applicationHostProvider);
  StreamSubscription<CommandEvent>? _subscription;
  Map<String, Object?> _state = {};
  bool _busy = false;
  bool _returnNoticeVisible = false;
  bool _scanning = false;
  bool _installing = false;
  String? _modeAddress;
  int _modeGeneration = 0;
  int? _readingMode;
  int? _mode;
  PickedFileData? _file;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription = _host.events.listen((event) {
      if (event.event == 'miwear.engineering.state' && mounted) {
        setState(() => _state = Map<String, Object?>.from(event.data));
      }
    });
    unawaited(_run('status'));
    ref.listenManual(
      deviceManagerProvider,
      (_, next) => _updateModeDevice(
        next.protocolState == ProtocolState.ready
            ? next.currentDevice?.addr
            : null,
      ),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(
      _host.execute(const OronBoxCommand(method: 'miwear.engineering.cancel')),
    );
    final path = _file?.path;
    if (path != null) unawaited(ManagedTemporaryFiles.releaseImport(path));
    super.dispose();
  }

  void _updateModeDevice(String? address) {
    final target =
        ref.read(deviceManagerProvider.notifier).currentDeviceKind ==
            DeviceKind.xiaomi
        ? address
        : null;
    if (target == _modeAddress) return;
    setState(() {
      _modeAddress = target;
      _mode = null;
      _modeGeneration++;
    });
    if (target != null) unawaited(_readMode());
  }

  Future<void> _readMode() async {
    final generation = _modeGeneration;
    if (_modeAddress == null || _readingMode == generation) return;
    _readingMode = generation;
    try {
      final result = await _host.execute(
        const OronBoxCommand(method: 'miwear.engineering.mode.get'),
      );
      if (mounted && generation == _modeGeneration && result.ok) {
        final value = result.value;
        if (value is Map) setState(() => _mode = value['mode'] as int?);
      }
    } finally {
      if (_readingMode == generation) _readingMode = null;
    }
  }

  Future<void> _run(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final scanning = method == 'scan';
    final cancelling = method == 'cancel';
    if ((_busy && !cancelling) || (scanning && _scanning)) return;
    setState(() {
      if (scanning) {
        _scanning = true;
      } else if (!cancelling) {
        _busy = true;
        _installing = method == 'install';
      }
      _error = null;
      if (method == 'mode.set') {
        _mode = null;
        _modeGeneration++;
      }
    });
    try {
      final result = await _host.execute(
        OronBoxCommand(method: 'miwear.engineering.$method', params: params),
      );
      if (!mounted || (scanning && _busy)) return;
      if (!result.ok) {
        if (result.error!.code != 'cancelled') {
          final text = localizedErrorMessage(
            AppLocalizations.of(context)!,
            result.error,
          );
          setState(() => _error = text);
          if (method != 'install') {
            appScaffoldMessengerOf(context)
                .showSnackBar(SnackBar(content: Text(text)));
          }
        }
      } else if (result.value is Map) {
        final value = Map<String, Object?>.from(result.value as Map);
        if (!scanning) setState(() => _state = value);
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = localizedErrorMessage(
            AppLocalizations.of(context)!,
            error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          if (scanning) {
            _scanning = false;
          } else if (!cancelling) {
            _busy = false;
            _installing = false;
          }
        });
      }
    }
  }

  Future<bool> _confirm(String text) async =>
      await OronBoxDialog.show<bool>(
        context: context,
        builder: (context) {
          final l10n = AppLocalizations.of(context)!;
          return AlertDialog(
            title: Text(l10n.engineeringTitle),
            content: Text(text),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.creatorConfirm),
              ),
            ],
          );
        },
      ) ??
      false;

  Future<void> _pick() async {
    try {
      await _pickFile();
    } catch (error) {
      if (mounted) {
        final text = localizedErrorMessage(
          AppLocalizations.of(context)!,
          error,
        );
        setState(() => _error = text);
        appScaffoldMessengerOf(context)
            .showSnackBar(SnackBar(content: Text(text)));
      }
    }
  }

  Future<void> _pickFile() async {
    final file = await pickFileData(
      type: FileType.custom,
      allowedExtensions: ['bin'],
      loadBytes: shouldLoadPickedFileData,
    );
    if (file == null) return;
    if (!mounted) {
      if (file.path != null) {
        await ManagedTemporaryFiles.releaseImport(file.path!);
      }
      return;
    }
    final oldPath = _file?.path;
    setState(() => _file = file);
    if (oldPath != null && oldPath != file.path) {
      await ManagedTemporaryFiles.releaseImport(oldPath);
    }
  }

  Future<void> _install() async {
    final file = _file;
    if (file == null ||
        !await _confirm(AppLocalizations.of(context)!.engineeringOtaConfirm) ||
        !mounted) {
      return;
    }
    await _run('install', {
      if (file.path != null) 'path': file.path,
      if (file.path == null && file.bytes != null)
        'bytes': base64Encode(file.bytes!),
      'label': AppLocalizations.of(context)!.deviceFeaturesInstallFirmware,
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final device = ref.watch(deviceManagerProvider);
    final normal =
        device.protocolState == ProtocolState.ready &&
        ref.read(deviceManagerProvider.notifier).currentDeviceKind ==
            DeviceKind.xiaomi;
    final connected = _state['connected'] == true;
    final phase = _state['phase']?.toString() ?? 'idle';
    final status = switch (phase) {
      'scanning' => l10n.engineeringScanning,
      'connecting' => l10n.engineeringConnecting,
      'connected' => l10n.deviceConnected,
      'uploading' => l10n.engineeringUploading,
      'restarting' => l10n.engineeringRestarting,
      'waiting' => l10n.engineeringWaiting,
      'failed' => l10n.engineeringFailed,
      'disconnected' => l10n.deviceDisconnected,
      _ => l10n.engineeringIdle,
    };
    final progress = (_state['progress'] as num?)?.toDouble() ?? 0;
    final updating =
        phase == 'uploading' ||
        phase == 'restarting' ||
        (phase == 'waiting' &&
            _state['totalBytes'] is num &&
            (_state['totalBytes'] as num) > 0 &&
            _state['waitingForEngineering'] != true);
    String megabytes(String key) =>
        (((_state[key] as num?) ?? 0) / 1000000).toStringAsFixed(1);
    final speed = (((_state['bytesPerSecond'] as num?) ?? 0) / 1000)
        .toStringAsFixed(0);
    final devices = (_state['devices'] as List? ?? const []).whereType<Map>();
    final labels = [
      l10n.engineeringUser,
      l10n.engineeringUserDebug,
      l10n.engineeringEng,
    ];
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_busy || _returnNoticeVisible) return;
        _returnNoticeVisible = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final notice = appScaffoldMessengerOf(context).showSnackBar(
            SnackBar(
              content: Text(
                updating || _installing
                    ? l10n.engineeringUpdateBackBlocked
                    : l10n.engineeringBusyError,
              ),
            ),
          );
          unawaited(notice.closed.then((_) => _returnNoticeVisible = false));
        });
        WidgetsBinding.instance.ensureVisualUpdate();
      },
      child: Scaffold(
        appBar: SysAppBar(secondary: true, title: Text(l10n.engineeringTitle)),
        body: SegmentedList(
          maxWidth: StyleConstants.pageMaxWidth,
          contentPadding: EdgeInsets.only(
            top: 8,
            bottom: bottomContentPadding(context, extra: 16),
          ),
          sections: [
            if (!updating || _error != null)
              SegmentedSection(
                tiles: [
                  if (!updating)
                    SegmentedTile(
                      title: Text(_state['name']?.toString() ?? status),
                      description: _state['name'] == null ? null : Text(status),
                    ),
                  if (_error != null)
                    SegmentedTile(
                      leading: const Icon(Icons.error_outline),
                      title: Text(_error!),
                    ),
                ],
              ),
            SegmentedSection(
              title: Text(l10n.engineeringMode),
              tiles: [
                SegmentedTile(
                  title: Text(
                    device.currentDevice?.name ?? l10n.engineeringMode,
                  ),
                  description: Text(
                    _mode != null && _mode! >= 0 && _mode! < labels.length
                        ? labels[_mode!]
                        : normal
                        ? '—'
                        : l10n.deviceNotConnected,
                  ),
                  trailing: IconButton(
                    onPressed: normal && !_busy ? _readMode : null,
                    icon: const Icon(Icons.refresh),
                  ),
                ),
                for (var mode = 0; mode < labels.length; mode++)
                  SegmentedTile(
                    title: Text(labels[mode]),
                    description: Text(['USER', 'USER DEBUG', 'ENG'][mode]),
                    enabled: normal && !_busy,
                    onPressed: (_) async {
                      if (await _confirm(l10n.engineeringModeConfirm) &&
                          mounted) {
                        await _run('mode.set', {'mode': mode});
                      }
                    },
                  ),
              ],
            ),
            SegmentedSection(
              title: Text(l10n.engineeringConnectDevice),
              tiles: [
                SegmentedTile(
                  title: Text(_scanning ? l10n.engineeringScanning : l10n.scan),
                  leading: const Icon(Icons.bluetooth_searching),
                  enabled: !_busy && !_scanning && !connected,
                  onPressed: (_) => _run('scan'),
                ),
                if (!connected &&
                    devices.isEmpty &&
                    _state['hasScanned'] == true &&
                    phase != 'scanning')
                  SegmentedTile(
                    title: Text(l10n.engineeringEmpty),
                    enabled: false,
                  ),
                for (final endpoint in connected ? const <Map>[] : devices)
                  SegmentedTile(
                    title: Text(endpoint['name'].toString()),
                    description: Text(
                      '${endpoint['address']} · ${endpoint['type']}',
                    ),
                    enabled: !_busy && !connected,
                    onPressed: (_) async {
                      if ((!normal ||
                              await _confirm(l10n.engineeringConnectConfirm)) &&
                          mounted) {
                        await _run('connect', {
                          'address': endpoint['address'],
                          'type': endpoint['type'],
                        });
                      }
                    },
                  ),
                if (connected) ...[
                  SegmentedTile(
                    title: Text(_state['name']?.toString() ?? ''),
                    description: Text(_state['address']?.toString() ?? ''),
                    trailing: IconButton(
                      onPressed: !_busy ? () => _run('refresh') : null,
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                  SegmentedTile(
                    title: Text(l10n.firmwareCurrentVersion),
                    description: Text(_state['version']?.toString() ?? '—'),
                  ),
                  SegmentedTile(
                    title: Text(l10n.fieldBattery),
                    description: Text(
                      _state['battery'] == null ? '—' : '${_state['battery']}%',
                    ),
                  ),
                  SegmentedTile(
                    title: Text(l10n.engineeringReturn),
                    enabled: !_busy,
                    onPressed: (_) async {
                      if (await _confirm(l10n.engineeringModeConfirm) &&
                          mounted) {
                        await _run('return');
                      }
                    },
                  ),
                  SegmentedTile(
                    title: Text(l10n.deviceActionsDisconnect),
                    enabled: !_busy,
                    onPressed: (_) => _run('close'),
                  ),
                ],
              ],
            ),
            SegmentedSection(
              title: Text(l10n.deviceFeaturesInstallFirmware),
              tiles: [
                SegmentedTile(
                  leading: const Icon(Icons.file_open_outlined),
                  title: Text(_file?.name ?? l10n.selectFile),
                  description: Text(l10n.engineeringFirmwareHint),
                  enabled: !_busy,
                  onPressed: (_) => _pick(),
                ),
                SegmentedTile(
                  leading: const Icon(Icons.system_update_outlined),
                  title: Text(
                    updating ? status : l10n.deviceFeaturesInstallFirmware,
                  ),
                  description: phase == 'uploading'
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${(progress * 100).floor()}% · '
                              '${megabytes('sentBytes')} MB / '
                              '${megabytes('totalBytes')} MB · $speed KB/s',
                            ),
                            LinearProgressIndicator(value: progress),
                          ],
                        )
                      : null,
                  enabled: !updating && !_busy && connected && _file != null,
                  onPressed: (_) => _install(),
                ),
                if (_busy || _scanning)
                  SegmentedTile(
                    title: Text(l10n.cancel),
                    onPressed: (_) => _run('cancel'),
                  ),
              ],
            ),
            SegmentedSection(
              title: Text(l10n.logs),
              tiles: [
                SegmentedTile(
                  title: Text(l10n.copy),
                  enabled: (_state['logs'] as List?)?.isNotEmpty ?? false,
                  onPressed: (_) async {
                    await Clipboard.setData(
                      ClipboardData(text: (_state['logs'] as List).join('\n')),
                    );
                    if (context.mounted) {
                      appScaffoldMessengerOf(context)
                          .showSnackBar(SnackBar(content: Text(l10n.copied)));
                    }
                  },
                ),
                if ((_state['logs'] as List?)?.isNotEmpty ?? false)
                  SegmentedTile(
                    title: SelectableText(
                      (_state['logs'] as List).reversed.take(12).join('\n'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
