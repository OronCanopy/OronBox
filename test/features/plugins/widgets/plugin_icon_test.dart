import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:image/image.dart' as img;
import 'package:oronbox/src/features/plugins/widgets/plugin_icon.dart';

void main() {
  testWidgets(
    'rebuilds and resizing retain the image until its artwork changes',
    (tester) async {
      String png(int width) =>
          base64Encode(img.encodePng(img.Image(width: width, height: 2)));
      Future<void> render(String data, double size, {int revision = 0}) =>
          tester.pumpWidget(
            ProviderScope(
              child: MaterialApp(
                home: Column(
                  children: [
                    Text('$revision'),
                    PluginIcon(base64: data, size: size),
                  ],
                ),
              ),
            ),
          );
      final first = png(2);
      await render(first, 32);
      await tester.pumpAndSettle();
      final original = tester.widget<Image>(find.byType(Image)).image;
      await render(first, 32, revision: 1);
      expect(tester.widget<Image>(find.byType(Image)).image, same(original));
      await render(first, 48);
      expect(tester.widget<Image>(find.byType(Image)).image, same(original));
      await render(png(3), 48);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isNot(same(original)),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
