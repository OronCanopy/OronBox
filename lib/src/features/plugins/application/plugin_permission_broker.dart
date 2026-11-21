import 'dart:async';

import '../domain/plugin_package.dart';
import '../domain/plugin_permission.dart';

typedef PluginPermissionPrompt = Future<PluginPermissionDecision> Function(
  PluginPermissionRequest request,
);
typedef PluginPermissionGrantReader = Future<Set<String>> Function(String id);
typedef PluginPermissionGrantWriter = Future<void> Function(
  String id,
  Set<String> grants,
);
typedef PluginPolicyReader = Future<Map<String, Object?>> Function(String id);
typedef PluginPolicyWriter = Future<void> Function(
  String id,
  Map<String, Object?> policies,
);

class PluginPermissionBroker {
  PluginPermissionBroker({
    required this._prompt,
    required this._readPersistentGrants,
    required this._writePersistentGrants,
    required this._readPolicies,
    required this._writePolicies,
  });

  final PluginPermissionPrompt _prompt;
  final PluginPermissionGrantReader _readPersistentGrants;
  final PluginPermissionGrantWriter _writePersistentGrants;
  final PluginPolicyReader _readPolicies;
  final PluginPolicyWriter _writePolicies;
  final _sessionGrants = <String, Set<String>>{};
  final _policies = <String, Map<String, Object?>>{};
  final _loads = <String, Future<Map<String, Object?>>>{};
  final _writes = <String, Future<void>>{};
  final _pending = <String, Future<void>>{};
  final _generations = <String, int>{};
  final _revisions = <String, int>{};

  int revision(String id) => _revisions[id] ?? 0;

  void requireRevision(String id, int expected) {
    if (revision(id) != expected) {
      throw const PluginPermissionException(
        'permission_changed',
        'Plugin permissions changed',
      );
    }
  }

  Future<Map<String, Object?>> policies(String id) async =>
      Map.of(await _policiesFor(id));

  Future<Map<String, Object?>> _policiesFor(String id) async {
    if (_policies[id] case final existing?) return existing;
    if (_loads[id] case final pending?) return pending;
    late final Future<Map<String, Object?>> loading;
    loading =
        () async {
          final rules = Map<String, Object?>.of(await _readPolicies(id));
          final legacy = await _readPersistentGrants(id);
          final originalCount = rules.length;
          rules.removeWhere(isRetiredPluginPermissionPolicy);
          final hadRetiredRules = rules.length != originalCount;
          for (final key in legacy) {
            if (!isRetiredPluginPermissionKey(key)) {
              rules.putIfAbsent(key, () => _legacyPolicy(key));
            }
          }
          if (hadRetiredRules || legacy.isNotEmpty) {
            await _writePolicies(id, rules);
          }
          if (legacy.isNotEmpty) await _writePersistentGrants(id, {});
          _policies[id] = rules;
          return rules;
        }().whenComplete(() {
          if (identical(_loads[id], loading)) _loads.remove(id);
        });
    _loads[id] = loading;
    return loading;
  }

  Map<String, Object?> _legacyPolicy(String key) {
    final fields = key.split(':');
    return {
      'decision': 'allow',
      'legacy': true,
      if (fields.length >= 2) 'capability': fields[0],
      if (fields.length >= 2) 'operation': fields[1],
      if (fields.length > 2) 'scope': fields.skip(2).join(':'),
      'resource': fields.length > 2 ? fields.skip(2).join(':') : key,
    };
  }

  String? _decision(
    Map<String, Object?> rules,
    PluginPermissionRequest request,
  ) {
    final exact = rules[request.grantKey] as Map?;
    if (exact != null) return exact['decision'] as String?;
    final capability = rules[request.capability] as Map?;
    if (capability != null) return capability['decision'] as String?;
    final legacy = rules['${request.capability}:${request.operation}'] as Map?;
    final legacyScoped =
        rules['${request.capability}:${request.operation}:${request.scope}']
            as Map?;
    return legacyScoped?['decision'] as String? ??
        legacy?['decision'] as String?;
  }

  Future<void> authorize(
    InstalledPlugin plugin,
    PluginPermissionRequest request,
  ) async {
    final id = plugin.manifest.id;
    final generation = _generations[id] ?? 0;
    if (!plugin.manifest.permissions.any(
      (value) => value.trim().toLowerCase() == request.capability,
    )) {
      throw PluginPermissionException(
        'permission_not_declared',
        '${plugin.manifest.name} did not declare ${request.capability}',
      );
    }
    final rules = await _policiesFor(id);
    _requireCurrent(id, generation);
    switch (_decision(rules, request)) {
      case 'deny':
        throw PluginPermissionException(
          'permission_denied',
          'Permission denied for ${request.operation}',
        );
      case 'allow' when request.capability != 'mass.firmware':
        if (request.scope != null && !rules.containsKey(request.grantKey)) {
          final expectedRevision = this.revision(id);
          await _updatePolicies(id, (current) {
            _requireCurrent(id, generation);
            requireRevision(id, expectedRevision);
            current.putIfAbsent(
              request.grantKey,
              () => {...request.toJson(), 'decision': 'allow'},
            );
          });
          _requireCurrent(id, generation);
          requireRevision(id, expectedRevision);
        }
        return;
    }
    if (request.risk == PluginPermissionRisk.low &&
        _decision(rules, request) == null) {
      return;
    }
    if (request.capability != 'mass.firmware' &&
        _sessionGrants[id]?.contains(request.grantKey) == true) {
      return;
    }
    final revision = _revisions[id] ?? 0;
    final key = '$id:$generation:$revision:${request.grantKey}';
    if (request.operation != 'browser.open' &&
        request.capability != 'mass.firmware') {
      if (_pending[key] case final pending?) return pending;
    }
    late final Future<void> authorization;
    authorization = _ask(request, generation, revision).whenComplete(() {
      if (identical(_pending[key], authorization)) _pending.remove(key);
    });
    _pending[key] = authorization;
    return authorization;
  }

  Future<void> _ask(
    PluginPermissionRequest request,
    int generation,
    int revision,
  ) async {
    final id = request.pluginId;
    _requireCurrent(id, generation);
    await _updatePolicies(id, (rules) {
      _requireCurrent(id, generation);
      rules.putIfAbsent(
        request.grantKey,
        () => {...request.toJson(), 'decision': 'ask'},
      );
    });
    _requireCurrent(id, generation);
    if ((_revisions[id] ?? 0) != revision) {
      throw const PluginPermissionException(
        'permission_changed',
        'Plugin permissions changed',
      );
    }
    final decision = await _prompt(request);
    _requireCurrent(id, generation);
    if ((_revisions[id] ?? 0) != revision) {
      if (_decision(await _policiesFor(id), request) == 'allow') return;
      throw const PluginPermissionException(
        'permission_changed',
        'Permission changed while awaiting approval',
      );
    }
    switch (decision) {
      case PluginPermissionDecision.once:
        return;
      case PluginPermissionDecision.session:
        if (request.capability == 'mass.firmware') return;
        (_sessionGrants[id] ??= {}).add(request.grantKey);
        return;
      case PluginPermissionDecision.always:
        if (request.operation == 'browser.open' ||
            request.capability == 'mass.firmware') {
          return;
        }
        await _updatePolicies(id, (rules) {
          _requireCurrent(id, generation);
          if ((_revisions[id] ?? 0) != revision) {
            throw const PluginPermissionException(
              'permission_changed',
              'Plugin permissions changed',
            );
          }
          rules[request.grantKey] = {...request.toJson(), 'decision': 'allow'};
        });
        _requireCurrent(id, generation);
        return;
      case PluginPermissionDecision.deny:
        throw PluginPermissionException(
          'permission_denied',
          'Permission denied for ${request.operation}',
        );
    }
  }

  Future<void> setPolicy(
    String id,
    String key,
    Map<String, Object?> policy,
  ) async {
    if (!{'ask', 'allow', 'deny'}.contains(policy['decision'])) {
      throw ArgumentError('Invalid permission policy');
    }
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    _sessionGrants.remove(id);
    await _updatePolicies(id, (rules) {
      rules[key] = Map<String, Object?>.of(policy);
      if (policy['operation'] == '*') {
        rules.removeWhere(
          (entryKey, value) =>
              entryKey != key &&
              value is Map &&
              (value['capability'] == key ||
                  (value['legacy'] == true && entryKey.startsWith('$key:'))),
        );
      }
    });
  }

  Future<void> _updatePolicies(
    String id,
    void Function(Map<String, Object?> rules) update,
  ) {
    final previous = _writes[id] ?? Future<void>.value();
    late final Future<void> writing;
    writing = previous
        .catchError((_) {})
        .then((_) async {
          final old = await _policiesFor(id);
          final rules = Map<String, Object?>.of(old);
          update(rules);
          _policies[id] = rules;
          try {
            await _writePolicies(id, rules);
          } catch (_) {
            if (identical(_policies[id], rules)) _policies[id] = old;
            rethrow;
          }
        })
        .whenComplete(() {
          if (identical(_writes[id], writing)) _writes.remove(id);
        });
    _writes[id] = writing;
    return writing;
  }

  Future<void> drainWrites() async {
    await Future.wait(_loads.values.toList());
    await Future.wait(_writes.values.toList());
  }

  Future<void> reload() async {
    await drainWrites();
    _policies.clear();
    _sessionGrants.clear();
  }

  void _requireCurrent(String id, int generation) {
    if ((_generations[id] ?? 0) != generation) {
      throw const PluginPermissionException(
        'plugin_stopped',
        'Plugin session ended',
      );
    }
  }

  Future<void> clearPlugin(String id) async {
    endSession(id);
    await _updatePolicies(id, (rules) => rules.clear());
    await _writePersistentGrants(id, {});
    _policies.remove(id);
  }

  void endSession(String id) {
    _sessionGrants.remove(id);
    _generations[id] = (_generations[id] ?? 0) + 1;
  }
}
