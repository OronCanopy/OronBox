import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oronbox/src/features/plugins/application/plugin_permission_broker.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_package.dart';
import 'package:oronbox/src/features/plugins/domain/plugin_permission.dart';

final _policies = <String, Object?>{};

void main() {
  setUp(_policies.clear);
  group('PluginPermissionBroker', () {
    test('firmware MASS always requests confirmation even after persistent or session approval', () async {
      var prompts = 0;
      final broker = _broker((_) async {
        prompts++;
        return PluginPermissionDecision.session;
      });
      _policies['mass.firmware'] = {'decision': 'allow'};
      final plugin = _plugin(['mass.firmware']);
      final request = _request(
        capability: 'mass.firmware',
        operation: 'mass.send',
      );
      await broker.authorize(plugin, request);
      await broker.authorize(plugin, request);
      expect(prompts, 2);
    });
    test('rejects capabilities missing from the manifest', () async {
      final broker = _broker((_) async => PluginPermissionDecision.once);

      await expectLater(
        broker.authorize(_plugin(const []), _request()),
        throwsA(isA<PluginPermissionException>()),
      );
    });

    test('does not prompt for low-risk sandbox access', () async {
      var prompts = 0;
      final broker = _broker((_) async {
        prompts++;
        return PluginPermissionDecision.deny;
      });

      await broker.authorize(
        _plugin(const ['file']),
        _request(
          capability: 'file',
          operation: 'file.read',
          risk: PluginPermissionRisk.low,
        ),
      );

      expect(prompts, 0);
    });

    test('once grants only the current operation', () async {
      var prompts = 0;
      final broker = _broker((_) async {
        prompts++;
        return PluginPermissionDecision.once;
      });
      final plugin = _plugin(const ['device']);

      await broker.authorize(plugin, _request());
      await broker.authorize(plugin, _request());

      expect(prompts, 2);
    });

    test('session grant lasts until the runtime session ends', () async {
      var prompts = 0;
      final broker = _broker((_) async {
        prompts++;
        return PluginPermissionDecision.session;
      });
      final plugin = _plugin(const ['device']);

      await broker.authorize(plugin, _request());
      await broker.authorize(plugin, _request());
      broker.endSession(plugin.manifest.id);
      await broker.authorize(plugin, _request());

      expect(prompts, 2);
    });

    test('always grant is persisted', () async {
      final grants = <String>{};
      var prompts = 0;
      final broker = PluginPermissionBroker(
        readPolicies: (_) async => Map.of(_policies),
        writePolicies: (_, rules) async {
          _policies
            ..clear()
            ..addAll(rules);
        },
        prompt: (_) async {
          prompts++;
          return PluginPermissionDecision.always;
        },
        readPersistentGrants: (_) async => Set<String>.of(grants),
        writePersistentGrants: (_, values) async {
          final copy = Set<String>.of(values);
          grants
            ..clear()
            ..addAll(copy);
        },
      );
      final plugin = _plugin(const ['device']);

      await broker.authorize(plugin, _request());
      broker.endSession(plugin.manifest.id);
      await broker.authorize(plugin, _request());

      expect(prompts, 1);
      expect((_policies[_request().grantKey] as Map)['decision'], 'allow');
    });

    test(
      'browser openings each require a prompt including concurrent calls',
      () async {
        var prompts = 0;
        final broker = _broker((_) async {
          prompts++;
          return PluginPermissionDecision.always;
        });
        final plugin = _plugin(const ['browser']);
        final request = _request(
          capability: 'browser',
          operation: 'browser.open',
        );
        await broker.authorize(plugin, request);
        await Future.wait([
          broker.authorize(plugin, request),
          broker.authorize(plugin, request),
        ]);
        expect(prompts, 3);
      },
    );

    test(
      'a prompt from a stopped session cannot grant the next session',
      () async {
        final decision = Completer<PluginPermissionDecision>();
        var prompts = 0;
        final broker = _broker((_) {
          prompts++;
          return prompts == 1
              ? decision.future
              : Future.value(PluginPermissionDecision.once);
        });
        final plugin = _plugin(const ['device']);
        final pending = broker.authorize(plugin, _request());
        final rejected = expectLater(
          pending,
          throwsA(isA<PluginPermissionException>()),
        );
        await Future<void>.delayed(Duration.zero);
        broker.endSession(plugin.manifest.id);
        decision.complete(PluginPermissionDecision.session);
        await rejected;
        await broker.authorize(plugin, _request());
        expect(prompts, 2);
      },
    );

    test(
      'stopping during a persistent grant read rejects the old call',
      () async {
        final grants = Completer<Set<String>>();
        final broker = PluginPermissionBroker(
          readPolicies: (_) async => Map.of(_policies),
          writePolicies: (_, rules) async {
            _policies
              ..clear()
              ..addAll(rules);
          },
          prompt: (_) async => PluginPermissionDecision.deny,
          readPersistentGrants: (_) => grants.future,
          writePersistentGrants: (_, _) async {},
        );
        final plugin = _plugin(const ['device']);
        final pending = broker.authorize(plugin, _request());
        final rejected = expectLater(
          pending,
          throwsA(isA<PluginPermissionException>()),
        );
        broker.endSession(plugin.manifest.id);
        grants.complete({_request().grantKey});
        await rejected;
        await broker.authorize(plugin, _request());
      },
    );

    test('target grants stay isolated and capability denial revokes previous grants', () async {
      var prompts = 0;
      final broker = _broker((_) async {
        prompts++;
        return PluginPermissionDecision.always;
      });
      final plugin = _plugin(const ['device']);
      final first = _request(scope: '["watch-one","app"]');
      final second = _request(scope: '["watch-two","app"]');
      await broker.authorize(plugin, first);
      await broker.authorize(plugin, first);
      await broker.authorize(plugin, second);
      expect(prompts, 2);
      await broker.setPolicy(plugin.manifest.id, 'device', {
        'capability': 'device',
        'operation': '*',
        'decision': 'deny',
      });
      await expectLater(
        broker.authorize(plugin, first),
        throwsA(isA<PluginPermissionException>()),
      );
      expect((await broker.policies(plugin.manifest.id)).keys, ['device']);
    });

    test('capability approval records encountered targets for individual revocation', () async {
      final broker = _broker((_) async => PluginPermissionDecision.deny);
      final plugin = _plugin(const ['device']);
      await broker.setPolicy(plugin.manifest.id, 'device', {
        'capability': 'device',
        'operation': '*',
        'decision': 'allow',
      });
      final first = _request(scope: 'watch-one');
      final second = _request(scope: 'watch-two');
      await broker.authorize(plugin, first);
      await broker.authorize(plugin, second);
      final rules = await broker.policies(plugin.manifest.id);
      expect((rules[first.grantKey] as Map)['scope'], 'watch-one');
      await broker.setPolicy(plugin.manifest.id, first.grantKey, {
        ...first.toJson(),
        'decision': 'deny',
      });
      await expectLater(
        broker.authorize(plugin, first),
        throwsA(isA<PluginPermissionException>()),
      );
      await broker.authorize(plugin, second);
    });

    test(
      'ask after an allow or session grant requires another prompt',
      () async {
        var prompts = 0;
        final broker = _broker((_) async {
          prompts++;
          return PluginPermissionDecision.session;
        });
        final plugin = _plugin(const ['device']);
        await broker.authorize(plugin, _request());
        await broker.setPolicy(plugin.manifest.id, 'device', {
          'capability': 'device',
          'operation': '*',
          'decision': 'ask',
        });
        await broker.authorize(plugin, _request());
        expect(prompts, 2);
      },
    );

    test(
      'explicit denial also blocks previously automatic sandbox operations',
      () async {
        final broker = _broker((_) async => PluginPermissionDecision.once);
        final plugin = _plugin(const ['file']);
        await broker.setPolicy(plugin.manifest.id, 'file', {
          'capability': 'file',
          'operation': '*',
          'decision': 'deny',
        });
        await expectLater(
          broker.authorize(
            plugin,
            _request(
              capability: 'file',
              operation: 'file.read',
              risk: PluginPermissionRisk.low,
            ),
          ),
          throwsA(isA<PluginPermissionException>()),
        );
      },
    );

    test('policy changes invalidate a pending persistent approval', () async {
      final prompt = Completer<PluginPermissionDecision>();
      final reached = Completer<void>();
      final broker = _broker((_) {
        reached.complete();
        return prompt.future;
      });
      final plugin = _plugin(const ['device']);
      final authorization = broker.authorize(plugin, _request());
      final rejected = expectLater(
        authorization,
        throwsA(isA<PluginPermissionException>()),
      );
      await reached.future;
      await broker.setPolicy(plugin.manifest.id, 'device', {
        'capability': 'device',
        'operation': '*',
        'decision': 'deny',
      });
      prompt.complete(PluginPermissionDecision.always);
      await rejected;
      expect((_policies['device'] as Map)['decision'], 'deny');
      expect(_policies.containsKey(_request().grantKey), false);
    });

    test('concurrent persistent grants retain both targets', () async {
      final broker = _broker((_) async => PluginPermissionDecision.always);
      final plugin = _plugin(const ['device']);
      final first = _request(scope: 'watch-one');
      final second = _request(scope: 'watch-two');
      await Future.wait([
        broker.authorize(plugin, first),
        broker.authorize(plugin, second),
      ]);
      expect((_policies[first.grantKey] as Map)['decision'], 'allow');
      expect((_policies[second.grantKey] as Map)['decision'], 'allow');
    });

    test('legacy grants migrate without broadening scoped access', () async {
      final legacy = <String>{'device:device.connect:watch-one'};
      var prompts = 0;
      final broker = PluginPermissionBroker(
        prompt: (_) async {
          prompts++;
          return PluginPermissionDecision.once;
        },
        readPersistentGrants: (_) async => Set.of(legacy),
        writePersistentGrants: (_, values) async {
          legacy
            ..clear()
            ..addAll(values);
        },
        readPolicies: (_) async => Map.of(_policies),
        writePolicies: (_, values) async {
          _policies
            ..clear()
            ..addAll(values);
        },
      );
      final plugin = _plugin(const ['device']);
      await broker.authorize(plugin, _request(scope: 'watch-one'));
      await broker.authorize(plugin, _request(scope: 'watch-two'));
      expect(prompts, 1);
      expect(legacy, isEmpty);
      expect(
        (_policies['device:device.connect:watch-one'] as Map)['scope'],
        'watch-one',
      );
    });

    test(
      'a failed settings write restores the previous authorization decision',
      () async {
        var failWrite = false;
        final broker = PluginPermissionBroker(
          prompt: (_) async => PluginPermissionDecision.deny,
          readPersistentGrants: (_) async => {},
          writePersistentGrants: (_, _) async {},
          readPolicies: (_) async => Map.of(_policies),
          writePolicies: (_, values) async {
            if (failWrite) throw StateError('disk full');
            _policies
              ..clear()
              ..addAll(values);
          },
        );
        final plugin = _plugin(const ['device']);
        await broker.setPolicy(plugin.manifest.id, 'device', {
          'capability': 'device',
          'operation': '*',
          'decision': 'deny',
        });
        failWrite = true;
        await expectLater(
          broker.setPolicy(plugin.manifest.id, 'device', {
            'capability': 'device',
            'operation': '*',
            'decision': 'allow',
          }),
          throwsStateError,
        );
        await expectLater(
          broker.authorize(plugin, _request()),
          throwsA(isA<PluginPermissionException>()),
        );
        expect(
          ((await broker.policies(plugin.manifest.id))['device']
              as Map)['decision'],
          'deny',
        );
      },
    );

    test('coalesces concurrent identical prompts', () async {
      final decision = Completer<PluginPermissionDecision>();
      var prompts = 0;
      final broker = _broker((_) {
        prompts++;
        return decision.future;
      });
      final plugin = _plugin(const ['device']);

      final first = broker.authorize(plugin, _request());
      final second = broker.authorize(plugin, _request());
      await Future<void>.delayed(Duration.zero);
      decision.complete(PluginPermissionDecision.once);
      await Future.wait([first, second]);

      expect(prompts, 1);
    });
  });
}

PluginPermissionBroker _broker(PluginPermissionPrompt prompt) {
  return PluginPermissionBroker(
    readPolicies: (_) async => Map.of(_policies),
    writePolicies: (_, rules) async {
      _policies
        ..clear()
        ..addAll(rules);
    },
    prompt: prompt,
    readPersistentGrants: (_) async => <String>{},
    writePersistentGrants: (_, _) async {},
  );
}

InstalledPlugin _plugin(List<String> permissions) => InstalledPlugin(
  manifest: PluginManifest(
    id: 'org.example.plugin',
    name: 'Example',
    version: '1.0.0',
    author: 'OronBox',
    description: '',
    apiLevel: 1,
    runtime: PluginRuntimeType.wasm,
    entry: 'plugin.wasm',
    permissions: permissions,
  ),
  entryBytes: Uint8List(0),
  config: const {},
);

PluginPermissionRequest _request({
  String capability = 'device',
  String operation = 'device.connect',
  PluginPermissionRisk risk = PluginPermissionRisk.high,
  String? scope,
}) => PluginPermissionRequest(
  pluginId: 'org.example.plugin',
  pluginName: 'Example',
  capability: capability,
  operation: operation,
  risk: risk,
  description: 'connect to a device',
  resource: 'watch',
  scope: scope,
);
