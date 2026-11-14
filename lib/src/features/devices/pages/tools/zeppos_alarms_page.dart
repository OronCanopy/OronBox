import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:segmented_list/segmented_list.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/widgets/app_state_view.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/device/core/device_state.dart' as proto;
import 'package:oronbox/src/device/zeppos/systems/zeppos_alarms_system.dart';
import 'package:oronbox/src/features/devices/controllers/device_manager.dart';

class ZeppOsAlarmsPage extends ConsumerWidget {
  const ZeppOsAlarmsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(deviceManagerProvider);
    final ready = state.currentDevice != null &&
        state.protocolState == proto.ProtocolState.ready;
    final address = state.currentDevice?.addr;
    return _AlarmsView(
      key: ValueKey((address, ready)),
      address: address,
      ready: ready,
    );
  }
}

class _AlarmsView extends ConsumerStatefulWidget {
  const _AlarmsView({super.key, required this.address, required this.ready});
  final String? address;
  final bool ready;

  @override
  ConsumerState<_AlarmsView> createState() => _AlarmsViewState();
}

class _AlarmsViewState extends ConsumerState<_AlarmsView> {
  List<ZeppOsAlarm> _alarms = const [];
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  int? _capacity;
  StreamSubscription<List<ZeppOsAlarm>>? _updates;
  bool get _current =>
      mounted &&
      widget.ready &&
      ref.read(deviceManagerProvider).currentDevice?.addr == widget.address &&
      ref.read(deviceManagerProvider).protocolState == proto.ProtocolState.ready;

  @override
  void initState() {
    super.initState();
    if (widget.ready) {
      _updates = ref.read(deviceManagerProvider.notifier).zeppOsAlarmUpdates.listen(
        (alarms) {
          if (_current && !_loading && !_busy) {
            setState(() => _alarms = alarms);
          }
        },
        onError: (Object error) {
          if (_current && !_loading && !_busy) {
            setState(() => _error = error);
          }
        },
      );
      Future.microtask(_load);
    }
  }

  @override
  void dispose() {
    final updates = _updates;
    if (updates != null) unawaited(updates.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current) return;
    setState(() {
      _loading = true;
      _error = null;
      _capacity = null;
    });
    try {
      final manager = ref.read(deviceManagerProvider.notifier);
      final alarms = await manager.loadZeppOsAlarms();
      if (_current) {
        setState(() {
          _alarms = alarms;
          _capacity = manager.zeppOsMaxAlarms;
        });
      }
    } catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _run(Future<void> Function(DeviceManager) operation) async {
    if (!_current || _busy || _loading) return;
    setState(() => _busy = true);
    try {
      await operation(ref.read(deviceManagerProvider.notifier));
      if (_current) await _load();
    } catch (error) {
      if (_current) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              localizedErrorMessage(AppLocalizations.of(context)!, error),
            ),
          ),
        );
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  List<String> _days(AppLocalizations l10n) => [
    l10n.weekdayMonShort,
    l10n.weekdayTueShort,
    l10n.weekdayWedShort,
    l10n.weekdayThuShort,
    l10n.weekdayFriShort,
    l10n.weekdaySatShort,
    l10n.weekdaySunShort,
  ];
  String _time(ZeppOsAlarm alarm) =>
      '${alarm.hour.toString().padLeft(2, '0')}:${alarm.minute.toString().padLeft(2, '0')}';

  Future<void> _edit(ZeppOsAlarm alarm, {bool adding = false}) async {
    final l10n = AppLocalizations.of(context)!;
    var hour = alarm.hour.toString(), minute = alarm.minute.toString();
    var repetition = alarm.repetition;
    final form = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(adding ? l10n.alarmAdd : l10n.alarmEdit),
          content: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: hour,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: l10n.alarmHour),
                          onChanged: (value) => hour = value,
                          validator: (value) => _validateNumber(value, 23),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          initialValue: minute,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: l10n.alarmMinute),
                          onChanged: (value) => minute = value,
                          validator: (value) => _validateNumber(value, 59),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(l10n.alarmRepeat),
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final (index, label) in _days(l10n).indexed)
                        FilterChip(
                          label: Text(label),
                          selected: repetition & (1 << index) != 0,
                          onSelected: (_) => update(
                            () => repetition ^= 1 << index,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    repetition == 0 ? l10n.alarmOnce :
                    repetition == 127 ? l10n.alarmEveryDay : l10n.alarmCustom,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(context, true);
              },
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !_current) return;
    final edited = alarm.copyWith(
      hour: int.parse(hour),
      minute: int.parse(minute),
      repetition: repetition,
    );
    await _run((manager) => adding
        ? manager.addZeppOsAlarm(edited)
        : manager.updateZeppOsAlarm(edited));
  }

  Future<void> _delete(ZeppOsAlarm alarm) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.alarmDeleteTitle),
        content: Text(_time(alarm)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed == true && _current) {
      await _run((manager) => manager.deleteZeppOsAlarm(alarm.position));
    }
  }

  String? _validateNumber(String? value, int maximum) {
    final number = int.tryParse(value ?? '');
    return number == null || number < 0 || number > maximum ? '0–$maximum' : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final free = _capacity == null ? null : Iterable<int>.generate(_capacity!)
        .where((position) => !_alarms.any((alarm) => alarm.position == position)).firstOrNull;
    final editable = !_loading && !_busy && _error == null;
    return Scaffold(
      appBar: SysAppBar(
        secondary: true,
        title: Text(l10n.alarmManagementTitle),
      ),
      floatingActionButton: widget.ready && editable && free != null
          ? FloatingActionButton(
              onPressed: () => _edit(
                ZeppOsAlarm(
                  position: free,
                  hour: TimeOfDay.now().hour,
                  minute: TimeOfDay.now().minute,
                  repetition: 0,
                ),
                adding: true,
              ),
              tooltip: l10n.alarmAdd,
              child: const Icon(Icons.add),
            )
          : null,
      body: !widget.ready
          ? EmptyStateView(
              icon: Icons.bluetooth_disabled_outlined,
              title: l10n.deviceNotConnected,
            )
          : _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? ErrorStateView(
              message: localizedErrorMessage(l10n, _error),
              onRetry: _load,
            )
          : _alarms.isEmpty
          ? EmptyStateView(
              icon: Icons.alarm_off_outlined,
              title: l10n.alarmManagementTitle,
              message: l10n.noContent,
            )
          : SegmentedList(
              maxWidth: StyleConstants.pageMaxWidth,
              contentPadding: const EdgeInsets.only(top: 8, bottom: 96),
              sections: [
                SegmentedSection(
                  tiles: [
                    for (final alarm in _alarms)
                      SegmentedTile.switchTile(
                        key: ValueKey(alarm),
                        leading: const Icon(Icons.alarm_outlined),
                        title: Text(_time(alarm)),
                        description: Text(_repeatDescription(l10n, alarm)),
                        initialValue: alarm.enabled,
                        enabled: editable,
                        onToggle: (enabled) => _run(
                          (manager) => manager.updateZeppOsAlarm(
                            alarm.copyWith(enabled: enabled ?? false),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: l10n.alarmEdit,
                              onPressed: editable ? () => _edit(alarm) : null,
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: l10n.delete,
                              onPressed: editable ? () => _delete(alarm) : null,
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  String _repeatDescription(AppLocalizations l10n, ZeppOsAlarm alarm) {
    if (alarm.repetition == 0) return l10n.alarmOnce;
    if (alarm.repetition == 127) return l10n.alarmEveryDay;
    return l10n.alarmCustomDays([
      for (final (index, day) in _days(l10n).indexed)
        if (alarm.repetition & (1 << index) != 0) day,
    ].join(', '));
  }
}
