import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/modal/global_modal_models.dart';
import 'package:oronbox/src/app/modal/wasm_compatibility_dialog.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    WasmCompatibilityModalRequest request,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    WasmCompatibilityDialog(modal: request, onComplete: () {}),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'defer waits for persistence, closes the dialog and never starts native code',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final persisted = Completer<void>();
      bool? passed;
      await show(
        tester,
        WasmCompatibilityModalRequest(
          test: () async => fail('Deferral started the runtime'),
          defer: () => persisted.future,
          onComplete: (value) => passed = value,
        ),
      );
      expect(find.textContaining('Android 8~9'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('暂不测试'));
      await tester.pump();
      expect(passed, isNull);
      expect(find.byType(WasmCompatibilityDialog), findsOneWidget);
      persisted.complete();
      await tester.pumpAndSettle();
      expect(passed, isFalse);
      expect(find.byType(WasmCompatibilityDialog), findsNothing);
    },
  );

  testWidgets(
    'testing prevents duplicate starts and back, then resumes on success',
    (tester) async {
      final tested = Completer<void>();
      var starts = 0;
      bool? passed;
      await show(
        tester,
        WasmCompatibilityModalRequest(
          test: () {
            starts++;
            return tested.future;
          },
          defer: () async {},
          onComplete: (value) => passed = value,
        ),
      );
      await tester.tap(find.text('开始测试'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('正在测试，请稍候'), findsOneWidget);
      await tester.tap(find.text('开始测试'));
      final context = tester.element(find.byType(WasmCompatibilityDialog));
      await Navigator.of(context).maybePop();
      await tester.pump();
      expect(starts, 1);
      expect(passed, isNull);
      tested.complete();
      await tester.pumpAndSettle();
      expect(passed, isTrue);
      expect(find.byType(WasmCompatibilityDialog), findsNothing);
      expect(find.text('兼容性测试通过'), findsOneWidget);
    },
  );

  testWidgets(
    'catchable errors keep the dialog available for retry or deferral',
    (tester) async {
      bool? passed;
      await show(
        tester,
        WasmCompatibilityModalRequest(
          test: () async => throw StateError('Asset read failed'),
          defer: () async {},
          onComplete: (value) => passed = value,
        ),
      );
      await tester.tap(find.text('开始测试'));
      await tester.pumpAndSettle();
      expect(passed, isNull);
      expect(find.byType(WasmCompatibilityDialog), findsOneWidget);
      expect(find.text('测试未完成，请重试或暂不测试'), findsOneWidget);
      await tester.tap(find.text('暂不测试'));
      await tester.pumpAndSettle();
      expect(passed, isFalse);
    },
  );
}
