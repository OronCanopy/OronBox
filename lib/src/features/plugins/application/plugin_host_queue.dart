part of 'plugin_manager.dart';

extension PluginTaskQueue on PluginManager {
  void attachTaskQueue(HostTaskQueue queue) {
    if (_taskQueue != null) {
      throw StateError('Plugin task queue already attached');
    }
    _taskQueue = queue;
    _taskSubscription = queue.events.listen((event) {
      if (event.event != 'task') return;
      final task = queue.get(event.data['id']?.toString() ?? '');
      if (task == null) return;
      final id = task.command.params['pluginId'] as String?;
      final session = _sessions[id];
      if (id == null || session == null) return;
      session.queueDelivery = session.queueDelivery
          .then((_) async {
            if (!identical(_sessions[id], session)) return;
            final error = task.result?['error'] as Map?;
            await _runtimes[id]?.dispatchEvent(
              'plugin-message',
              jsonEncode({
                'eventName': 'queue.task',
                'host': true,
                'payload': jsonEncode({
                  'taskId': task.id,
                  'status': switch (task.status) {
                    'held' => 'pending',
                    'completed' => 'succeeded',
                    'cancelled' => 'canceled',
                    final status => status,
                  },
                  'progress': task.progress,
                  'errorCode': error?['code'],
                  'errorDetail': error?['message'],
                }),
              }),
            );
          })
          .catchError((Object error) {
            PluginManager._log.fine('Plugin task event delivery failed', error);
          });
    });
  }
}

extension _PluginInstallQueue on PluginManager {
  Future<String> _enqueuePluginInstall(
    String id,
    _PluginSession session,
    Map<String, Object?> options,
  ) => _withSessionFiles(id, session, () async {
    final queue = _taskQueue;
    if (queue == null) throw StateError('Install queue is unavailable');
    await queue.ready;
    String cleanText(Object? value, int limit) => String.fromCharCodes(
      (value?.toString() ?? '').runes
          .where((rune) => rune >= 32 && (rune < 127 || rune > 159))
          .take(limit),
    ).trim();
    final name = cleanText(options['name'], 120);
    final description = cleanText(options['description'], 240);
    final addr = options['device-addr']?.toString().trim() ?? '';
    final type = options['res-type']?.toString() ?? '';
    final watchface = (options['watchface-id'] as String?)?.trim();
    if (name.isEmpty ||
        addr.isEmpty ||
        !{'quickapp', 'watchface', 'firmware'}.contains(type)) {
      throw const FormatException(
        'Install task requires a name, device and resource type',
      );
    }
    if (watchface != null &&
        watchface.isNotEmpty &&
        (type != 'watchface' ||
            !RegExp(r'^[A-Za-z0-9]{1,16}$').hasMatch(watchface))) {
      throw const FormatException('Invalid watchface-id');
    }
    final icon = (options['icon'] as String?)?.trim();
    if (icon != null &&
        icon.isNotEmpty &&
        !(icon.startsWith('https://') &&
            icon.length <= 2048 &&
            !RegExp(r'\s', unicode: true).hasMatch(icon)) &&
        !(icon.startsWith('data:image/') &&
            utf8.encode(icon).length <= 256 * 1024)) {
      throw const FormatException(
        'Install task icon requires an HTTPS or image data URL',
      );
    }
    final source = _jsonMap(options['source']);
    final storage = await _storage;
    PluginStoragePath? origin;
    if (source['case'] == 'file') {
      final relative = (source['value'] as String).trim();
      if (relative.startsWith('/') || relative.contains('\\')) {
        throw const FormatException(
          'Install source must be relative to the plugin directory',
        );
      }
      origin = _ngPath(relative);
    } else if (source['case'] != 'bytes') {
      throw const FormatException('Unknown install source');
    }
    final bytes = origin == null ? _bytes(source['value']) : null;
    if (bytes?.isEmpty == true) {
      throw const FormatException('Install source is empty');
    }
    final fileName = origin?.relativePath.split('/').last ?? 'plugin.bin';
    final path = await ManagedTemporaryFiles.create(
      TemporaryFilePurpose.installs,
      fileName,
      (destination) async {
        if (origin != null) {
          await storage.moveToHost(id, origin, destination);
        } else {
          await writePluginInstallBytes(destination, bytes!);
        }
      },
    );

    try {
      if (!identical(_sessions[id], session) || _closed || maintainingData) {
        throw StateError('Plugin session ended');
      }
      return queue.enqueue(
        OronBoxCommand(
          method: 'install.local',
          params: {
            'pluginId': id,
            'title': name,
            'description': description.isEmpty ? null : description,
            'icon': icon?.isEmpty == true ? null : icon,
            'device': addr,
            'type': type,
            'path': path,
            if (watchface != null && watchface.isNotEmpty)
              'identifier': watchface,
          },
        ),
        held: SharedPrefsService.instance.getBool('auto_install') == false,
      );
    } catch (_) {
      if (origin != null) {
        try {
          await storage.restoreFromHost(id, origin, path);
        } catch (error) {
          PluginManager._log.warning(
            'Plugin install source restore failed',
            error,
          );
        }
      }
      await ManagedTemporaryFiles.release(path);
      rethrow;
    }
  });
}
