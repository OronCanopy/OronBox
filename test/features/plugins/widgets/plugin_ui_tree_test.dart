import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/app_localizations_delegates.dart';
import 'package:oronbox/src/features/plugins/widgets/plugin_ui_tree.dart';

void main() {
  Future<void> render(
    WidgetTester tester,
    Map<String, Object?> root, {
    Future<void> Function(String, [Object?])? invoke,
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PluginUITree(
            root: root,
            onInvoke: invoke ?? (_, [value]) async {},
          ),
        ),
      ),
    );
  }

  testWidgets(
    'unchanged image updates preserve their decoded provider and painted frame',
    (tester) async {
      final image = img.Image(width: 8, height: 8)
        ..clear(img.ColorRgba8(220, 30, 40, 255));
      final encoded = base64Encode(img.encodePng(image));
      Map<String, Object?> tree(String id) => {
        'type': 'IMAGE',
        'id': id,
        'props': {
          'src': 'data:image/png;base64,$encoded',
          'width': 80,
          'height': 80,
        },
      };
      await render(tester, tree('first'));
      final imageFinder = find.byType(Image);
      final provider = tester.widget<Image>(imageFinder).image;
      final configuration = createLocalImageConfiguration(
        tester.element(imageFinder),
      );
      await tester.runAsync(() async {
        final stream = provider.resolve(configuration);
        final decoded = Completer<void>();
        final listener = ImageStreamListener((image, _) {
          image.dispose();
          decoded.complete();
        }, onError: decoded.completeError);
        stream.addListener(listener);
        try {
          await decoded.future;
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pumpAndSettle();
      final painted = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(painted, isNotNull);
      await render(tester, tree('new-resource-id'));
      expect(tester.widget<Image>(find.byType(Image)).image, provider);
      expect(
        tester.widget<RawImage>(find.byType(RawImage)).image,
        same(painted),
      );
    },
  );

  testWidgets('recreated resource IDs retain input focus and editing state', (
    tester,
  ) async {
    Map<String, Object?> tree(String id) => {
      'type': 'INPUT',
      'id': id,
      'props': {'value': 'initial'},
      'events': {'INPUT': 'input'},
    };
    await render(tester, tree('first'));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'editing');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, true);
    await render(tester, tree('next'));
    final updated = tester.widget<TextField>(find.byType(TextField));
    expect(updated.focusNode, same(field.focusNode));
    expect(updated.controller!.text, 'editing');
    expect(updated.focusNode!.hasFocus, true);
  });

  testWidgets(
    'explicit sibling keys retain state when a conditional node is inserted',
    (tester) async {
      Map<String, Object?> tree(bool insert) => {
        'type': 'Column',
        'children': [
          if (insert)
            {
              'type': 'Text',
              'props': {'key': 'status', 'value': 'status'},
            },
          {
            'type': 'TextField',
            'props': {'key': 'name', 'value': 'initial'},
          },
        ],
      };
      await render(tester, tree(false));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'draft');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      await render(tester, tree(true));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(controller),
      );
      expect(controller!.text, 'draft');
    },
  );

  testWidgets(
    'unchanged SVG updates reuse their loader and real image changes replace content',
    (tester) async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="5"><rect width="4" height="5" fill="red"/></svg>';
      final source =
          'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';
      Map<String, Object?> tree(String data) => {
        'type': 'IMAGE',
        'props': {'src': data, 'width': 80, 'height': 80},
      };
      await render(tester, tree(source));
      await tester.pumpAndSettle();
      final loader = tester
          .widget<SvgPicture>(find.byType(SvgPicture))
          .bytesLoader;
      for (var i = 0; i < 10; i++) {
        await render(tester, tree(source));
        expect(
          tester.widget<SvgPicture>(find.byType(SvgPicture)).bytesLoader,
          loader,
        );
      }
      final png = base64Encode(img.encodePng(img.Image(width: 3, height: 2)));
      await render(tester, tree(png));
      expect(find.byType(SvgPicture), findsNothing);
      await tester.runAsync(() async {
        await precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        );
      });
      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 3);
      final previous = tester.widget<Image>(find.byType(Image)).image;
      final replacement = base64Encode(
        img.encodePng(img.Image(width: 6, height: 7)),
      );
      await render(tester, tree(replacement));
      expect(tester.widget<Image>(find.byType(Image)).image, isNot(previous));
      await tester.runAsync(() async {
        await precacheImage(
          tester.widget<Image>(find.byType(Image)).image,
          tester.element(find.byType(Image)),
        );
      });
      await tester.pumpAndSettle();
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 6);
      await render(tester, tree(source));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'programmatic controlled tab updates preserve input state and select the returned value',
    (tester) async {
      Map<String, Object?> tree(String value) => {
        'type': 'TABS-ROOT',
        'props': {'value': value},
        'children': [
          {
            'type': 'TABS-LIST',
            'children': [
              {
                'type': 'TABS-TRIGGER',
                'props': {'value': 'a'},
                'content': 'First',
              },
              {
                'type': 'TABS-TRIGGER',
                'props': {'value': 'b'},
                'content': 'Second',
              },
            ],
          },
          {
            'type': 'TABS-CONTENT',
            'props': {'value': value},
            'children': [
              {
                'type': 'INPUT',
                'props': {'key': 'shared-input', 'default-value': 'initial'},
              },
            ],
          },
        ],
      };
      await render(tester, tree('a'));
      await tester.enterText(find.byType(TextField), 'draft');
      final controller = tester
          .widget<TextField>(find.byType(TextField))
          .controller;
      await render(tester, tree('b'));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(TabBar));
      expect(DefaultTabController.of(context).index, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller,
        same(controller),
      );
      expect(controller!.text, 'draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'UI updates retain scrolling and removing the tree releases control state',
    (tester) async {
      Map<String, Object?> tree(String status) => {
        'type': 'COLUMN',
        'children': [
          {
            'type': 'SWITCH',
            'props': {'key': 'enabled', 'default-checked': false},
            'events': {'CHANGE': 'change'},
          },
          for (var i = 0; i < 60; i++)
            {'type': 'TEXT', 'content': '$status row $i'},
        ],
      };
      await render(tester, tree('before'));
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, true);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final offset = position.pixels;
      expect(offset, greaterThan(0));
      await render(tester, tree('after'));
      expect(position.pixels, offset);
      expect(tester.widget<Switch>(find.byType(Switch)).value, true);
      await tester.pumpWidget(const SizedBox());
      await render(tester, tree('fresh'));
      expect(tester.widget<Switch>(find.byType(Switch)).value, false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('viewport measurement follows the embedded plugin area', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 360,
                child: PluginViewport(
                  pluginId: 'fixture',
                  child: const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(PluginViewport));
    final key = ProviderScope.containerOf(context)
        .read(pluginViewportKeyProvider('fixture'));
    expect(key.currentContext!.size, const Size(280, 360));
  });

  testWidgets(
    'comic card keeps fixed icons and gives remaining width to text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await render(tester, {
        'type': 'DIV',
        'styles': {'flex_direction': 'row', 'width': '100%', 'gap': 12},
        'children': [
          {
            'type': 'DIV',
            'styles': {'width': 36, 'height': 36, 'flex_shrink': 0},
            'content': '图',
          },
          {
            'type': 'DIV',
            'styles': {
              'flex_direction': 'column',
              'flex_grow': 1,
              'width': '100%',
            },
            'children': [
              {'type': 'P', 'content': '正文页面'},
              {'type': 'P', 'content': '暂无图片 · 点击添加或整理页面'},
            ],
          },
          {
            'type': 'DIV',
            'styles': {'width': 20, 'height': 20, 'flex_shrink': 0},
            'content': '›',
          },
        ],
      });
      final description = tester.getSize(find.text('暂无图片 · 点击添加或整理页面'));
      expect(description.width, greaterThan(220));
      expect(description.height, lessThan(50));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a growing row can share width with a lazy list', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await render(tester, {
      'type': 'DIV',
      'styles': {'flex_direction': 'row'},
      'children': [
        {
          'type': 'INPUT',
          'styles': {'flex_grow': 1},
        },
        {
          'type': 'LAZYCOLUMN',
          'children': [
            {'type': 'TEXT', 'content': 'Playlist'},
          ],
        },
      ],
    });
    expect(find.text('Playlist'), findsOneWidget);
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'implicit flex rows preserve growing space and trailing actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final calls = <String>[];
      await render(tester, {
        'type': 'DIV',
        'styles': {'display': 'flex', 'gap': 8},
        'children': [
          {
            'type': 'INPUT',
            'styles': {'flex-grow': 1},
          },
          {
            'type': 'BUTTON',
            'content': 'Search',
            'events': {'CLICK': 'search'},
          },
          {
            'type': 'BUTTON',
            'content': 'Playlists',
            'events': {'CLICK': 'lists'},
          },
        ],
      }, invoke: (callback, [_]) async => calls.add(callback));
      final input = tester.getRect(find.byType(TextField));
      final search = tester.getRect(find.text('Search'));
      final playlists = tester.getRect(find.text('Playlists'));
      expect(search.center.dy, closeTo(input.center.dy, 2));
      expect(playlists.center.dy, search.center.dy);
      final actions = find.byType(FilledButton);
      final actionsWidth =
          tester.getSize(actions.first).width +
          tester.getSize(actions.last).width;
      expect(input.width, closeTo(360 - 16 - actionsWidth, .01));
      expect(input.right, lessThan(search.left));
      await tester.tap(find.text('Playlists'));
      expect(calls, ['lists']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inline badges leave their unused width for adjacent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const text = 'Artist One / Artist Two / Artist Three · 1:56';
    await render(tester, {
      'type': 'ROW',
      'styles': {'justify_content': 'start', 'gap': 6},
      'children': [
        {'type': 'SPAN', 'content': text},
        {'type': 'BADGE', 'content': '封面'},
        {'type': 'BADGE', 'content': '歌词'},
      ],
    });
    final artist = tester.getRect(find.text(text));
    final cover = tester.getRect(find.text('封面'));
    final lyrics = tester.getRect(find.text('歌词'));
    expect(artist.width, greaterThan(220));
    expect(cover.center.dy, artist.center.dy);
    expect(lyrics.right, inInclusiveRange(335, 360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('action rows wrap only when their buttons no longer fit', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final root = <String, Object?>{
      'type': 'DIV',
      'styles': {'display': 'flex', 'gap': 6},
      'children': [
        for (final text in ['Preview', 'Edit', 'Lyrics', 'Cover', 'Remove'])
          {
            'type': 'BUTTON',
            'content': text,
            'events': {'CLICK': text},
          },
      ],
    };
    await tester.binding.setSurfaceSize(const Size(600, 700));
    await render(tester, root);
    expect(
      tester.getCenter(find.text('Preview')).dy,
      tester.getCenter(find.text('Remove')).dy,
    );
    await tester.binding.setSurfaceSize(const Size(275, 640));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('Remove')).dy,
      greaterThan(tester.getCenter(find.text('Preview')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugin buttons retain their visible geometry across platforms', (
    tester,
  ) async {
    final root = <String, Object?>{
      'type': 'BUTTON',
      'content': 'Search',
      'events': {'CLICK': 'search'},
    };
    Rect? mobileRect;
    for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
      await render(tester, root, theme: ThemeData(platform: platform));
      final button = find.byType(FilledButton);
      final material = find
          .descendant(of: button, matching: find.byType(Material))
          .first;
      final rect = tester.getRect(material);
      expect(rect.height, 36);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      final shape =
          tester.widget<Material>(material).shape as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(10));
      if (mobileRect != null) expect(rect, mobileRect);
      mobileRect = rect;
    }
  });

  testWidgets('growing app details preserve the trailing action width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await render(tester, {
      'type': 'DIV',
      'styles': {'flex_direction': 'row', 'gap': 12},
      'children': [
        {
          'type': 'DIV',
          'styles': {'flex_grow': 1},
          'children': [
            {'type': 'P', 'content': 'A long application name'},
            {'type': 'P', 'content': 'com.example.application'},
          ],
        },
        {
          'type': 'DIV',
          'children': [
            {
              'type': 'BUTTON',
              'content': 'Listen',
              'events': {'CLICK': 'listen'},
            },
          ],
        },
      ],
    });
    expect(tester.getSize(find.text('Listen')).width, greaterThan(30));
    expect(tester.getSize(find.byType(FilledButton)).width, greaterThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'location search input and icon button are visible before focus',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await render(tester, {
        'type': 'DIV',
        'styles': {'flex_direction': 'row', 'gap': 8, 'width': '100%'},
        'children': [
          {
            'type': 'INPUT',
            'styles': {'flex_grow': 1, 'height': 36},
          },
          {
            'type': 'BUTTON',
            'styles': {'width': 44, 'padding_left': 10, 'padding_right': 10},
            'events': {'CLICK': 'search'},
            'children': [
              {
                'type': 'SVG',
                'styles': {'width': 16, 'height': 16},
                'content': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#fff" d="M0 0h24v24H0z"/></svg>',
              },
            ],
          },
        ],
      });
      final input = tester.widget<TextField>(find.byType(TextField));
      expect(input.decoration?.border, isA<OutlineInputBorder>());
      expect(
        tester.getSize(find.byType(FilledButton)).width,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.widget<SvgPicture>(find.byType(SvgPicture)).colorFilter,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('SVG image preserves its corners inside nested containers', (
    tester,
  ) async {
    const svg =
        '<?xml version="1.0" standalone="yes"?>'
        '<svg xmlns="http://www.w3.org/2000/svg" width="260" height="260" viewBox="0 0 26 26">'
        '<rect width="26" height="26" fill="#fff"/>'
        '<path d="M0 0h3v3H0z M23 0h3v3h-3z M0 23h3v3H0z M23 23h3v3h-3z" fill="#000"/>'
        '</svg>';
    final uri = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';
    final boundaryKey = GlobalKey();
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [400.0, 320.0, 800.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: RepaintBoundary(
                key: boundaryKey,
                child: PluginUITree(
                  root: {
                    'type': 'DIV',
                    'styles': {'width': '100%', 'flex_direction': 'column'},
                    'children': [
                      {
                        'type': 'CARD',
                        'styles': {
                          'flex-direction': 'column',
                          'align-items': 'center',
                          'padding': '28px',
                          'gap': '12px',
                        },
                        'children': [
                          {'type': 'P', 'content': 'Login'},
                          {
                            'type': 'DIV',
                            'styles': {
                              'padding': '12px',
                              'border-radius': '16px',
                              if (theme.brightness == Brightness.dark)
                                'background_color': '#ffffff'
                              else
                                'background': '#ffffff',
                            },
                            'children': [
                              {
                                'type': 'IMAGE',
                                'content': uri,
                                'styles': {'width': '196px', 'height': '196px'},
                              },
                            ],
                          },
                          {'type': 'P', 'content': 'Scan with the app'},
                        ],
                      },
                    ],
                  },
                  onInvoke: (_, [value]) async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final picture = find.byType(SvgPicture);
        expect(tester.widget<SvgPicture>(picture).colorFilter, isNull);
        final rect = tester.getRect(picture);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final snapshotWidth = boundary.size.width.ceil();
        final origin = tester.getTopLeft(find.byKey(boundaryKey));
        final pixels = await tester.runAsync(() async {
          final snapshot = await boundary.toImage();
          try {
            return await snapshot.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
          } finally {
            snapshot.dispose();
          }
        });
        expect(pixels, isNotNull);
        final rgba = pixels!.buffer.asUint8List();
        List<int> pixelAt(Offset point) {
          final local = point - origin;
          final offset =
              (local.dy.toInt() * snapshotWidth + local.dx.toInt()) * 4;
          return rgba.sublist(offset, offset + 4);
        }

        for (final point in [
          rect.topLeft + const Offset(8, 8),
          rect.topRight + const Offset(-8, 8),
          rect.bottomLeft + const Offset(8, -8),
          rect.bottomRight + const Offset(-8, -8),
        ]) {
          expect(pixelAt(point), [0, 0, 0, 255]);
        }
        expect(rect.size, const Size(196, 196));
        expect(pixelAt(rect.center), [255, 255, 255, 255]);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets(
    'cards apply the requested inset once and keep vertical child order',
    (tester) async {
      await render(tester, {
        'type': 'CARD',
        'styles': {
          'flex_direction': 'row',
          'align_items': 'end',
          'gap': 24,
          'padding': 28,
        },
        'children': [
          {'type': 'P', 'content': 'First'},
          {'type': 'P', 'content': 'Second'},
        ],
      });
      final first = tester.getRect(find.text('First'));
      final second = tester.getRect(find.text('Second'));
      final surface = find.descendant(
        of: find.byType(Card),
        matching: find.byType(Material),
      );
      final card = tester.getRect(surface.first);
      expect(first.top - card.top, 28);
      expect(card.top, 0);
      expect(second.top, closeTo(first.bottom, .01));
      expect(first.center.dx, closeTo(second.center.dx, .01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a container keeps its layout with one or multiple children', (
    tester,
  ) async {
    for (final count in [1, 2]) {
      await render(tester, {
        'type': 'DIV',
        'styles': {'width': 240},
        'children': [
          for (var i = 0; i < count; i++) {'type': 'P', 'content': 'Item $i'},
        ],
      });
      expect(tester.getSize(find.text('Item 0')).width, 240);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('container backgrounds follow the host theme for every shape', (
    tester,
  ) async {
    final png = base64Encode(img.encodePng(img.Image(width: 3, height: 2)));
    for (final nested in [false, true]) {
      final image = <String, Object?>{'type': 'IMAGE', 'content': png};
      await render(tester, {
        'type': 'DIV',
        'styles': {'background_color': '#ff0000', 'border_radius': 16},
        'children': [
          if (nested)
            {
              'type': 'DIV',
              'children': [image],
            }
          else
            image,
        ],
      });
      final decorations = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(PluginUITree),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect(
        decorations.where(
          (widget) =>
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).color ==
                  const Color(0xffff0000),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('image data keeps rendering raster bytes and data URIs', (
    tester,
  ) async {
    final png = img.encodePng(img.Image(width: 3, height: 2));
    final base64 = base64Encode(png);
    for (final source in [base64, 'data:image/png;base64,$base64']) {
      await render(tester, {
        'type': 'IMAGE',
        'content': source,
        'styles': {'width': 60, 'height': 40},
      });
      await tester.runAsync(() async {
        final provider = tester.widget<Image>(find.byType(Image)).image;
        await precacheImage(provider, tester.element(find.byType(Image)));
      });
      await tester.pumpAndSettle();
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(image, isNotNull);
      expect(image!.width, 3);
      expect(image.height, 2);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('stretched image parents preserve explicit size and fit', (
    tester,
  ) async {
    final png = img.encodePng(img.Image(width: 3, height: 2));
    await render(tester, {
      'type': 'DIV',
      'styles': {'flex_direction': 'column', 'width': '100%'},
      'children': [
        {
          'type': 'IMAGE',
          'content': base64Encode(png),
          'styles': {'width': 196, 'height': 196},
          'props': {'fit': 'cover'},
        },
      ],
    });
    expect(tester.getSize(find.byType(Image)), const Size(196, 196));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugin text inherits host typography and explicit alignment', (
    tester,
  ) async {
    await render(tester, {
      'type': 'P',
      'content': 'An intentionally long line of text',
      'props': {
        'class': 'rt-truncate rt-r-ta-center rt-r-weight-bold',
        'align': 'end',
        'maxLines': 2,
      },
      'styles': {
        'font-size': '30px',
        'font-weight': '900',
        'text-align': 'right',
        'width': 120,
      },
    });
    final text = tester.widget<Text>(
      find.text('An intentionally long line of text'),
    );
    expect(text.style?.fontSize, isNull);
    expect(text.style?.fontWeight, isNull);
    expect(text.style?.color, isNull);
    expect(text.textAlign, TextAlign.end);
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SELECT preserves labels and dispatches option values', (
    tester,
  ) async {
    Object? selected;
    await render(
      tester,
      {
        'type': 'SELECT',
        'events': {'CHANGE': 'select'},
        'children': [
          {
            'type': 'OPTION',
            'props': {'value': 'internal'},
            'content': 'Display label',
          },
        ],
      },
      invoke: (_, [value]) async {
        selected = value;
      },
    );
    final menu = tester.widget<DropdownMenu<String>>(
      find.byType(DropdownMenu<String>),
    );
    expect(menu.dropdownMenuEntries.single.label, 'Display label');
    menu.onSelected!('internal');
    expect(selected, {
      'eventType': 'CHANGE',
      'payload': {'value': 'internal'},
    });
  });

  testWidgets('SELECT preserves property options and respects visibility', (
    tester,
  ) async {
    await render(tester, {
      'type': 'SELECT',
      'props': {
        'options': ['One', 'Two'],
      },
    });
    final menu = tester.widget<DropdownMenu<String>>(
      find.byType(DropdownMenu<String>),
    );
    expect(menu.dropdownMenuEntries.map((entry) => entry.value), [
      'One',
      'Two',
    ]);
    await render(tester, {
      'type': 'SELECT',
      'props': {
        'visible': 'false',
        'options': ['Hidden'],
      },
    });
    expect(find.byType(DropdownMenu<String>), findsNothing);
  });

  testWidgets('media uses placeholders and disabled controls remain disabled', (
    tester,
  ) async {
    await render(tester, {
      'type': 'COLUMN',
      'children': [
        {'type': 'AUDIO'},
        {'type': 'VIDEO'},
        {
          'type': 'BUTTON',
          'content': 'Disabled',
          'props': {'disabled': 'true'},
          'events': {'CLICK': 'ignored'},
        },
      ],
    });
    expect(find.byIcon(Icons.audiotrack), findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Disabled'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('text input preserves both INPUT and CHANGE callbacks', (
    tester,
  ) async {
    final callbacks = <String>[];
    await render(
      tester,
      {
        'type': 'INPUT',
        'events': {'INPUT': 'input', 'CHANGE': 'change'},
      },
      invoke: (id, [value]) async {
        callbacks.add(id);
      },
    );
    await tester.enterText(find.byType(TextField), 'value');
    expect(callbacks, ['input', 'change']);
  });

  testWidgets('default-value input keeps edits across unrelated UI updates', (
    tester,
  ) async {
    final root = <String, Object?>{
      'id': 4,
      'type': 'INPUT',
      'props': {'default-value': 'initial'},
      'events': {'INPUT': 'mac_input'},
    };
    await render(tester, root);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'initial',
    );
    await tester.enterText(find.byType(TextField), 'edited');
    tester.widget<TextField>(find.byType(TextField)).focusNode!.unfocus();
    await tester.pump();
    await render(tester, root);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'edited',
    );
  });

  testWidgets('keyboard Enter reaches the input callback with its key', (
    tester,
  ) async {
    final values = <Object?>[];
    await render(
      tester,
      {
        'type': 'INPUT',
        'events': {'KEY-DOWN': 'search'},
      },
      invoke: (_, [value]) async {
        values.add(value);
      },
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(
      values.single,
      equals({
        'eventType': 'KEY-DOWN',
        'payload': {
          'key': 'Enter',
          'repeat': false,
          'altKey': false,
          'ctrlKey': false,
          'shiftKey': false,
          'metaKey': false,
        },
      }),
    );
  });

  testWidgets(
    'mobile keyboard submission dispatches Enter with the current value',
    (tester) async {
      final values = <Object?>[];
      await render(
        tester,
        {
          'type': 'INPUT',
          'events': {'KEY-DOWN': 'search'},
        },
        invoke: (_, [value]) async {
          values.add(value);
        },
      );
      await tester.enterText(find.byType(TextField), 'Shanghai');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(values, [
        {
          'eventType': 'KEY-DOWN',
          'payload': {'key': 'Enter', 'value': 'Shanghai'},
        },
      ]);
    },
  );

  testWidgets('SVG button preserves its label and invokes once', (
    tester,
  ) async {
    var calls = 0;
    await render(
      tester,
      {
        'type': 'BUTTON',
        'content': 'Sync',
        'events': {'CLICK': 'sync'},
        'styles': {'height': 3, 'background_color': '#000000'},
        'children': [
          {
            'type': 'SVG',
            'content': '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>',
          },
        ],
      },
      invoke: (_, [value]) async {
        calls++;
      },
    );
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.text('Sync'), findsOneWidget);
    await tester.tap(find.text('Sync'));
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unlock algorithm switch retains its default-checked interaction',
    (tester) async {
      final values = <Object?>[];
      final root = <String, Object?>{
        'id': 9,
        'type': 'SWITCH',
        'props': {'default-checked': 'false'},
        'events': {'CHANGE': 'algo_switch'},
      };
      Future<void> invoke(String id, [Object? value]) async =>
          values.add(value);
      await render(tester, root, invoke: invoke);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await render(tester, root, invoke: invoke);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(values, [
        {
          'eventType': 'CHANGE',
          'payload': {'value': true, 'checked': true},
        },
        {
          'eventType': 'CHANGE',
          'payload': {'value': false, 'checked': false},
        },
      ]);
    },
  );

  testWidgets('WIT string checked state is respected', (tester) async {
    await render(tester, {
      'type': 'SWITCH',
      'props': {'checked': 'true'},
      'events': {'CHANGE': 'switch'},
    });
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('dialog trigger opens native dialog and close dismisses it', (
    tester,
  ) async {
    await render(tester, {
      'type': 'DIALOG_ROOT',
      'children': [
        {'type': 'DIALOG_TRIGGER', 'content': 'Edit'},
        {
          'type': 'DIALOG_CONTENT',
          'children': [
            {'type': 'P', 'content': 'Dialog body'},
            {'type': 'DIALOG_CLOSE', 'content': 'Done'},
          ],
        },
      ],
    });
    expect(find.text('Dialog body'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('menu item dispatches its callback once', (tester) async {
    var calls = 0;
    await render(
      tester,
      {
        'type': 'DROPDOWN-MENU-ROOT',
        'children': [
          {'type': 'DROPDOWN-MENU-TRIGGER', 'content': 'Actions'},
          {
            'type': 'DROPDOWN-MENU-CONTENT',
            'children': [
              {
                'type': 'DROPDOWN-MENU-ITEM',
                'content': 'Send',
                'events': {'CLICK': 'send'},
              },
            ],
          },
        ],
      },
      invoke: (_, [value]) async {
        calls++;
      },
    );
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuItem<int>));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('tabs select the matching content', (tester) async {
    await render(tester, {
      'type': 'TABS-ROOT',
      'children': [
        {
          'type': 'TABS-LIST',
          'children': [
            {
              'type': 'TABS-TRIGGER',
              'content': 'First',
              'props': {'value': 'a'},
            },
            {
              'type': 'TABS-TRIGGER',
              'children': [
                {'type': 'SPAN', 'content': 'Second'},
              ],
              'props': {'value': 'b'},
            },
          ],
        },
        {
          'type': 'TABS-CONTENT',
          'props': {'value': 'a'},
          'children': [
            {'type': 'P', 'content': 'Panel A'},
          ],
        },
        {
          'type': 'TABS-CONTENT',
          'props': {'value': 'b'},
          'children': [
            {'type': 'P', 'content': 'Panel B'},
          ],
        },
      ],
    });
    expect(find.text('Panel A'), findsOneWidget);
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(find.text('Panel B'), findsOneWidget);
    expect(find.text('Panel A'), findsNothing);
  });

  testWidgets('controlled tabs retain content until the guest updates it', (
    tester,
  ) async {
    final callbacks = <String>[];
    await render(tester, {
      'type': 'TABS-ROOT',
      'props': {'value': 'cloud'},
      'children': [
        {
          'type': 'TABS-LIST',
          'children': [
            {
              'type': 'TABS-TRIGGER',
              'content': 'Cloud',
              'props': {'value': 'cloud'},
              'events': {'CLICK': 'tab.cloud'},
            },
            {
              'type': 'TABS-TRIGGER',
              'content': 'Library',
              'props': {'value': 'library'},
              'events': {'CLICK': 'tab.library'},
            },
          ],
        },
        {
          'type': 'TABS-CONTENT',
          'props': {'value': 'cloud'},
          'children': [
            {'type': 'P', 'content': 'Cloud content'},
          ],
        },
      ],
    }, invoke: (callback, [value]) async => callbacks.add(callback));
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(callbacks, ['tab.library']);
    expect(find.text('Cloud content'), findsOneWidget);
    await tester.tap(find.text('Cloud'));
    await tester.pumpAndSettle();
    expect(callbacks, ['tab.library', 'tab.cloud']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders a centered tree with flexible rows and callbacks', (
    tester,
  ) async {
    String? callback;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PluginUITree(
            root: {
              'type': 'Column',
              'props': const <String, Object?>{},
              'children': [
                {
                  'type': 'Image',
                  'props': {
                    'data':
                        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
                        'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
                    'width': 1,
                    'height': 1,
                  },
                },
                {
                  'type': 'Row',
                  'props': const <String, Object?>{},
                  'children': [
                    {
                      'type': 'Text',
                      'props': {'value': 'left'},
                    },
                    {'type': 'Spacer'},
                    {
                      'type': 'Button',
                      'props': {'text': 'run', 'onClick': 'callback-1'},
                    },
                  ],
                },
              ],
            },
            onInvoke: (id, [value]) async => callback = id,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('left'), findsOneWidget);
    await tester.tap(find.text('run'));
    expect(callback, 'callback-1');
  });

  testWidgets('passes typed values from interactive controls', (tester) async {
    final values = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PluginUITree(
            root: {
              'type': 'Column',
              'children': [
                {
                  'type': 'Switch',
                  'props': {'checked': false, 'onChange': 'switch'},
                },
                {
                  'type': 'Checkbox',
                  'props': {'checked': false, 'onChange': 'checkbox'},
                },
              ],
            },
            onInvoke: (id, [value]) async => values.add(value),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.tap(find.byType(Checkbox));

    expect(values, [
      {
        'eventType': 'CHANGE',
        'payload': {'value': true, 'checked': true},
      },
      {
        'eventType': 'CHANGE',
        'payload': {'value': true, 'checked': true},
      },
    ]);
  });

  testWidgets('publishes text changes before the field loses focus', (
    tester,
  ) async {
    final values = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PluginUITree(
            root: {
              'type': 'TextField',
              'props': {'onChange': 'change', 'placeholder': 'city'},
            },
            onInvoke: (id, [value]) async => values.add(value),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '北京');

    expect(values, [
      {
        'eventType': 'CHANGE',
        'payload': {'value': '北京'},
      },
    ]);
  });

  testWidgets(
    'renders AstroBox Component Model UI tree with styles and events',
    (tester) async {
      final events = <String, Object?>{};
      final abTree = {
        'target_id': 'root',
        'root': {
          'id': 1,
          'type': 'DIV',
          'styles': {
            'display': 'flex',
            'flex_direction': 'COLUMN',
            'padding': 16,
            'background_color': '#f0f0f0',
          },
          'children': [
            {
              'id': 2,
              'type': 'P',
              'content': 'AstroBox Headline',
              'styles': {
                'font_size': 18,
                'color': '#112233',
                'font_weight': 'bold',
              },
            },
            {
              'id': 3,
              'type': 'BUTTON',
              'content': 'Astro Submit',
              'events': {'CLICK': 'btn_event_1'},
            },
            {
              'id': 4,
              'type': 'INPUT',
              'props': {'placeholder': 'Type here'},
              'events': {'CHANGE': 'input_event_1'},
            },
            {
              'id': 5,
              'type': 'CARD',
              'children': [
                {'id': 6, 'type': 'BADGE', 'content': 'Official'},
              ],
            },
            {'id': 7, 'type': 'SEPARATOR'},
          ],
        },
      };

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PluginUITree(
              root: abTree,
              onInvoke: (id, [value]) async => events[id] = value,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('AstroBox Headline'), findsOneWidget);
      expect(find.text('Astro Submit'), findsOneWidget);
      expect(find.text('Official'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.tap(find.text('Astro Submit'));
      expect(events.containsKey('btn_event_1'), isTrue);

      await tester.enterText(find.byType(TextField), 'Hello AstroBox');
      expect(events['input_event_1'], {
        'eventType': 'CHANGE',
        'payload': {'value': 'Hello AstroBox'},
      });
    },
  );
}
