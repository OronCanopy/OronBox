import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/widgets/app_checkbox_tile.dart';
import 'package:segmented_list/segmented_list.dart';

void main() {
  for (final kind in ['tile', 'row', 'segmented']) {
    testWidgets(
      '$kind toggles from checkbox, label and row with ink confined to checkbox',
      (tester) async {
        var value = false;
        var enabled = true;
        final changes = <bool?>[];
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  void onChanged(bool? next) => setState(() {
                    value = next == true;
                    changes.add(value);
                  });
                  final callback = enabled ? onChanged : null;
                  final control = switch (kind) {
                    'tile' => AppCheckboxTile(
                      value: value,
                      title: const Text('Agreement'),
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: callback,
                    ),
                    'row' => AppCheckboxRow(
                      value: value,
                      title: const Text('Agreement'),
                      expanded: true,
                      onChanged: callback,
                    ),
                    _ => SegmentedTile.checkboxTile(
                      initialValue: value,
                      title: const Text('Agreement'),
                      onToggle: callback,
                      enabled: enabled,
                    ),
                  };
                  return RepaintBoundary(
                    key: const ValueKey('control'),
                    child: SizedBox(width: 400, child: control),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final control = find.byKey(const ValueKey('control'));
        Future<Uint8List> pixels() async => (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(control);
          final image = await boundary.toImage();
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;

        for (final target in [
          tester.getCenter(find.text('Agreement')),
          tester.getRect(control).center,
        ]) {
          final before = await pixels();
          final gesture = await tester.startGesture(target);
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            listEquals(await pixels(), before),
            isTrue,
            reason: 'Pressing the label or row must not paint ink feedback',
          );
          await gesture.cancel();
          await tester.pumpAndSettle();
        }
        final beforeCheckboxPress = await pixels();
        final checkboxGesture = await tester.startGesture(
          tester.getCenter(find.byType(Checkbox)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          listEquals(await pixels(), beforeCheckboxPress),
          isFalse,
          reason: 'Pressing the checkbox retains its own ink feedback',
        );
        await checkboxGesture.cancel();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agreement'));
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getRect(control).center);
        await tester.pumpAndSettle();
        expect(changes, [true, false, true]);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(changes, [true, false, true, false]);
        update(() => enabled = false);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agreement'));
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(changes, [true, false, true, false]);
      },
    );
  }
}
