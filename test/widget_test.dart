import 'dart:async';
import 'dart:math' as math;

import 'package:cad_view/app/cad_view_app.dart';
import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/core/recent_files.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_entity_metrics.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:cad_view/features/viewer/cad_viewer_page.dart';
import 'package:cad_view/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multilingual_fixture.dart';

Finder cadScenePaintFinder() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is CadScenePainter,
  description: 'CAD scene paint surface',
);

void main() {
  testWidgets(
    'image export supports cancellation, save failure and retry from compact menu',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      final previousPicker = FilePickerPlatform.instance;
      final picker = _ImageSavePicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() {
        FilePickerPlatform.instance = previousPicker;
        tester.binding.setSurfaceSize(null);
      });
      final document = multilingualCadDocument();
      final opened = OpenedCadDocument(
        sessionId: BigInt.one,
        formatId: 'dxf',
        sceneKind: 'two_d',
        displayName: 'R20-0000_1.dxf',
        fingerprint: 'test',
        document: document,
        annotations: const [],
        sourcePath: '/tmp/very/long/path/R20-0000_1.dxf',
        totalEntityCount: BigInt.from(document.entities.length),
        isPartial: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: CadViewerPage(
            engine: _FakeCadEngine()..viewportDocument = document,
            opened: opened,
            decimalPlaces: 2,
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        if (i == 0) {
          picker.pending = Completer<Uri?>();
        } else if (i == 1) {
          picker.error = PlatformException(code: 'save_failed');
        } else if (i == 2) {
          picker.error = null;
          picker.result = Uri.file('/tmp/R20-0000_1.png');
        }
        await tester.tap(find.byKey(const ValueKey('viewer_more_actions')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export image (PNG)'));
        // An in-progress export intentionally animates its status indicator.
        // Wait for the menu transition, not for all animations to stop.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        for (var attempt = 0; picker.calls <= i && attempt < 20; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        if (i == 0) {
          await tester.pump();
        } else {
          await tester.pumpAndSettle();
        }
        expect(picker.calls, i + 1);
        if (i == 0) {
          // The system save dialog may remain open for a long time. A second
          // export must stay disabled until save/cancel finishes.
          await tester.tap(find.byKey(const ValueKey('viewer_more_actions')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          final item = tester.widget<PopupMenuItem<dynamic>>(
            find.ancestor(
              of: find.text('Export image (PNG)'),
              matching: find.byWidgetPredicate(
                (widget) => widget is PopupMenuItem<dynamic>,
              ),
            ),
          );
          expect(item.enabled, isFalse);
          expect(
            find.descendant(
              of: find.byWidget(item),
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          await tester.tap(find.text('Export image (PNG)'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(picker.calls, 1);
          await tester.tapAt(const Offset(10, 700));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          picker.pending!.complete(null);
          picker.pending = null;
          await tester.pumpAndSettle();
        }
        expect(picker.name, 'R20-0000_1.png');
        expect(picker.mime, 'image/png');
        expect(picker.bytes!.take(8).toList(), [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ]);
        expect(
          find.text('Image exported'),
          i < 2 ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('R20-0000_1.dxf'));
      await tester.pumpAndSettle();
      expect(find.text('/tmp/very/long/path/R20-0000_1.dxf'), findsOneWidget);
      expect(find.byType(SelectableText), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'all supported locales fit compact home and settings at large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      tester.binding.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(() {
        tester.binding.setSurfaceSize(null);
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
        tester.binding.platformDispatcher.clearLocalesTestValue();
      });
      for (final locale in AppLocalizations.supportedLocales) {
        tester.binding.platformDispatcher.localesTestValue = [locale];
        await tester.pumpWidget(
          CadViewApp(
            key: ValueKey(locale.toString()),
            engine: _FakeCadEngine(),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'home: $locale');
        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'settings: $locale');
        await tester.tapAt(const Offset(8, 8));
        await tester.pumpAndSettle();
      }
    },
  );

  test('locale resolution follows system order and falls back to English', () {
    expect(
      AppLocalizations.resolve(const [Locale('en'), Locale('zh', 'CN')]),
      const Locale('en'),
    );
    expect(
      AppLocalizations.resolve(const [Locale('fr'), Locale('zh', 'HK')]),
      const Locale('fr'),
    );
    expect(
      AppLocalizations.resolve(const [Locale('de'), Locale('zh', 'HK')]),
      const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    );
    for (final language in const ['es', 'ja', 'fr', 'ko', 'ru']) {
      expect(AppLocalizations.resolve([Locale(language)]), Locale(language));
    }
    expect(AppLocalizations.resolve(const [Locale('de')]), const Locale('en'));
    expect(AppLocalizations.translationsComplete, isTrue);
  });

  test(
    'property clipboard text keeps labels and multiline engineering values',
    () {
      expect(
        cadPropertiesClipboardText('Entity properties', const [
          (label: 'Width (X)', value: '20.000'),
          (label: 'Position', value: 'X: 1.000\nY: 2.000'),
        ]),
        'Entity properties\nWidth (X): 20.000\nPosition: X: 1.000\nY: 2.000',
      );
    },
  );

  testWidgets('home page stays focused on opening a drawing', (tester) async {
    await tester.pumpWidget(CadViewApp(engine: _FakeCadEngine()));
    await tester.pumpAndSettle();

    expect(find.text('CADView'), findsOneWidget);
    expect(find.text('Open drawing'), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.text('DXF'), findsNothing);
    expect(find.text('Dual scene core'), findsNothing);
  });

  testWidgets('foreground lifecycle is synchronized to the native engine', (
    tester,
  ) async {
    final engine = _FakeCadEngine();
    await tester.pumpWidget(CadViewApp(engine: engine));
    await tester.pumpAndSettle();
    engine.backgroundStates.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(engine.backgroundStates, contains(true));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.backgroundStates.last, isFalse);
  });

  testWidgets('home page shows locally persisted recent files', (tester) async {
    await tester.pumpWidget(
      CadViewApp(
        engine: _FakeCadEngine(),
        recentFiles: const _InMemoryRecentFilesStore([
          RecentFileEntry(
            path: '/drawings/example.dwg',
            displayName: 'example.dwg',
            openedAtEpochMs: 1,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recent files'), findsOneWidget);
    expect(find.text('example.dwg'), findsOneWidget);
    expect(find.byTooltip('Remove from recent'), findsOneWidget);
  });

  testWidgets('language can be changed from system default in settings', (
    tester,
  ) async {
    await tester.pumpWidget(CadViewApp(engine: _FakeCadEngine()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Language'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simplified Chinese'));
    await tester.pumpAndSettle();

    expect(find.text('打开图纸'), findsOneWidget);
  });

  testWidgets('measurement precision can be changed with one numeric choice', (
    tester,
  ) async {
    await tester.pumpWidget(CadViewApp(engine: _FakeCadEngine()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Measurement precision'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '5'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Digits after decimal: 5'), findsOneWidget);
  });

  testWidgets(
    'cancelling annotation editor does not use a disposed controller',
    (tester) async {
      final engine = _FakeCadEngine();
      final document = CadDocumentModel.fromJson({
        'metadata': {'format': 'dxf', 'display_name': 'note.dxf'},
        'scene': {
          'scene_kind': 'two_d',
          'scene': {
            'layers': [
              {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
            ],
            'entities': <Object>[],
            'bounds': {
              'min': {'x': 0, 'y': 0},
              'max': {'x': 100, 'y': 100},
            },
          },
        },
        'diagnostics': <Object>[],
      });
      final opened = OpenedCadDocument(
        sessionId: BigInt.one,
        formatId: 'dxf',
        sceneKind: 'two_d',
        displayName: 'note.dxf',
        fingerprint: 'test',
        document: document,
        annotations: const [],
        sourcePath: '/tmp/note.dxf',
        totalEntityCount: BigInt.zero,
        isPartial: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: CadViewerPage(engine: engine, opened: opened),
        ),
      );

      expect(find.byType(AppBar), findsNothing);
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Measure'), findsOneWidget);
      await tester.tap(find.text('Annotate'));
      await tester.pump();
      await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
      await tester.pumpAndSettle();
      expect(find.text('Add annotation'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Add annotation'), findsNothing);
    },
  );

  testWidgets('layer isolation and restore-all use one native batch each', (
    tester,
  ) async {
    final engine = _FakeCadEngine();
    final document = CadDocumentModel.fromJson({
      'metadata': {'format': 'dxf', 'display_name': 'layers.dxf'},
      'scene': {
        'scene_kind': 'two_d',
        'scene': {
          'layers': [
            {
              'id': 1,
              'name': 'Walls',
              'visible': true,
              'color_argb': 0xffffffff,
            },
            {
              'id': 2,
              'name': 'Dimensions',
              'visible': true,
              'color_argb': 0xffffffff,
            },
            {
              'id': 3,
              'name': 'Notes',
              'visible': false,
              'color_argb': 0xffffffff,
            },
          ],
          'entities': <Object>[],
          'bounds': {
            'min': {'x': 0, 'y': 0},
            'max': {'x': 100, 'y': 100},
          },
        },
      },
      'diagnostics': <Object>[],
    });
    engine.viewportDocument = document;
    final opened = OpenedCadDocument(
      sessionId: BigInt.one,
      formatId: 'dxf',
      sceneKind: 'two_d',
      displayName: 'layers.dxf',
      fingerprint: 'layers-test',
      document: document,
      annotations: const [],
      sourcePath: '/tmp/layers.dxf',
      totalEntityCount: BigInt.zero,
      isPartial: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: CadViewerPage(engine: engine, opened: opened),
      ),
    );
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    if (find
        .byKey(const ValueKey('viewer_more_actions'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('viewer_more_actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Layers / assembly'));
    } else {
      await tester.tap(find.byIcon(Icons.layers_outlined));
    }
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Isolate layer').at(1));
    await tester.pumpAndSettle();
    expect(engine.visibilityBatches, hasLength(1));
    expect(engine.visibilityBatches.single, {
      BigInt.one: false,
      BigInt.from(2): true,
      BigInt.from(3): false,
    });

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(engine.visibilityBatches, hasLength(2));
    expect(engine.visibilityBatches.last, {
      BigInt.one: true,
      BigInt.from(2): true,
      BigInt.from(3): true,
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('3D standard views remain simple on a compact screen', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final document = CadDocumentModel.fromJson({
      'metadata': {'format': 'stl', 'display_name': 'triangle.stl'},
      'scene': {
        'scene_kind': 'three_d',
        'scene': {
          'meshes': [
            {
              'id': 7,
              'name': 'Triangle',
              'positions': [
                {'x': -1, 'y': -1, 'z': 0},
                {'x': 1, 'y': -1, 'z': 0},
                {'x': 0, 'y': 1, 'z': 0},
              ],
              'indices': [0, 1, 2],
              'surface_area': 2.0,
              'closed_manifold': true,
              'enclosed_volume': 1.5,
              'volume_centroid': {'x': 0.25, 'y': -0.5, 'z': 0.75},
            },
          ],
          'root_nodes': [
            {
              'id': 1,
              'name': 'Root',
              'visible': true,
              'mesh_ids': [7],
              'children': <Object>[],
            },
          ],
          'bounds': {
            'min': {'x': -1, 'y': -1, 'z': 0},
            'max': {'x': 1, 'y': 1, 'z': 0},
          },
        },
      },
      'diagnostics': <Object>[],
    });
    final opened = OpenedCadDocument(
      sessionId: BigInt.one,
      formatId: 'stl',
      sceneKind: 'three_d',
      displayName: 'triangle.stl',
      fingerprint: '3d-views',
      document: document,
      annotations: const [],
      sourcePath: '/tmp/triangle.stl',
      totalEntityCount: BigInt.zero,
      isPartial: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: CadViewerPage(engine: _FakeCadEngine(), opened: opened),
      ),
    );
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(find.text('Views'), findsOneWidget);

    if (find
        .byKey(const ValueKey('viewer_more_actions'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const ValueKey('viewer_more_actions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drawing overview'));
    } else {
      await tester.tap(find.byTooltip('Drawing overview'));
    }
    await tester.pumpAndSettle();
    expect(find.text('Source unit'), findsOneWidget);
    expect(find.text('Not specified'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('document_overview_list')),
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    expect(find.text('Meshes'), findsOneWidget);
    expect(find.text('Assembly nodes'), findsOneWidget);
    expect(find.text('Vertices'), findsOneWidget);
    expect(find.text('Triangles'), findsOneWidget);
    expect(find.text('Total mesh surface area'), findsOneWidget);
    expect(find.text('2.000 DU²'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('document_overview_list')),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    expect(find.text('Width (X)'), findsOneWidget);
    expect(find.text('Height (Y)'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('document_overview_list')),
      const Offset(0, -90),
    );
    await tester.pumpAndSettle();
    expect(find.text('Depth (Z)'), findsOneWidget);
    expect(find.text('2.000 DU'), findsWidgets);
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Views'));
    await tester.pumpAndSettle();
    expect(find.text('Standard views'), findsOneWidget);
    expect(find.text('Isometric'), findsOneWidget);
    expect(find.text('Front'), findsOneWidget);
    expect(find.text('Top'), findsOneWidget);
    expect(find.text('Right'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('standard_view_isometric')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('standard_view_top')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Views'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('standard_view_top')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('standard_view_top')));
    await tester.pumpAndSettle();
    final paintFinder = cadScenePaintFinder();
    final paintRect = tester.getRect(paintFinder);
    final orientation = cadStandardViewOrientation(CadStandardView.top);
    final transform = Cad3DViewTransform.forScene(
      document,
      paintRect.size,
      1,
      Offset.zero,
      orientation.yaw,
      orientation.pitch,
    );
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0, 0, 0)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Selected face'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('property_list')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();
    expect(find.text('Triangulated surface area'), findsOneWidget);
    expect(find.text('2.000 DU²'), findsWidgets);
    expect(find.text('Closed manifold'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('Enclosed mesh volume'), findsOneWidget);
    expect(find.text('1.500 DU³'), findsOneWidget);
    expect(find.text('Volume centroid (uniform material)'), findsOneWidget);
    expect(
      find.text('X: 0.250 DU · Y: -0.500 DU · Z: 0.750 DU'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Face area'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Face area'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Face perimeter'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Face perimeter'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Face edge lengths'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Face edge lengths'), findsOneWidget);
    expect(find.text('6.472 DU'), findsOneWidget);
    expect(find.text('2.000 DU · 2.236 DU · 2.236 DU'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Face centroid'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Face centroid'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Unit face normal'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Unit face normal'), findsOneWidget);
    expect(find.textContaining('Y: -0.333 DU'), findsOneWidget);
    expect(find.textContaining('Z: 1.000'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Face inclination (from horizontal)'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Face inclination (from horizontal)'), findsOneWidget);
    expect(find.text('Face grade'), findsOneWidget);
    expect(find.text('0.000°'), findsOneWidget);
    expect(find.text('0.000%'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Downslope azimuth (+Y, CW)'),
      100,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Downslope azimuth (+Y, CW)'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(clipboardText, contains('Selected face: 1'));
    expect(clipboardText, contains('Face area: 2.000 DU²'));
    expect(clipboardText, contains('Face perimeter: 6.472 DU'));
    expect(clipboardText, contains('Unit face normal: X: 0.000'));
    expect(
      clipboardText,
      contains('Face inclination (from horizontal): 0.000°'),
    );
    expect(clipboardText, contains('Face grade: 0.000%'));
    expect(clipboardText, contains('Downslope azimuth (+Y, CW): —'));
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    expect(find.text('Distance'), findsOneWidget);
    expect(find.text('Angle'), findsOneWidget);
    await tester.tap(find.text('Angle'));
    await tester.pumpAndSettle();

    for (final point in const [
      CadPoint3(0, 0, 0),
      CadPoint3(0.3, 0, 0),
      CadPoint3(0, 0.3, 0),
    ]) {
      await tester.tapAt(paintRect.topLeft + transform.project(point));
      await tester.pump();
    }
    expect(find.textContaining('Angle: 90.000°'), findsOneWidget);

    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Angle: 90.000°'), findsNothing);
    expect(find.text('Select a point on the second ray'), findsOneWidget);
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0, 0.3, 0)),
    );
    await tester.pump();
    expect(find.textContaining('Angle: 90.000°'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinates'));
    await tester.pumpAndSettle();
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0.2, 0.1, 0)),
    );
    await tester.pump();
    expect(find.textContaining('X:'), findsOneWidget);
    expect(find.textContaining('Y:'), findsOneWidget);
    expect(find.textContaining('Z: 0.000'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinate reference'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('set_local_origin')));
    await tester.pumpAndSettle();
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0, 0, 0)),
    );
    await tester.pump();
    expect(find.text('Local coordinate origin set'), findsOneWidget);
    final originPainter =
        tester.widget<CustomPaint>(paintFinder).painter! as CadScenePainter;
    expect(originPainter.coordinateOrigin3D, isNotNull);
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0.3, 0.2, 0)),
    );
    await tester.pump();
    expect(find.textContaining('Local X:'), findsOneWidget);
    expect(find.textContaining('Z: 0.000 DU'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scale calibration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calibrate_scale')));
    await tester.pumpAndSettle();
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0, 0, 0)),
    );
    await tester.pump();
    expect(find.text('Select the second calibration point'), findsOneWidget);
    await tester.tapAt(
      paintRect.topLeft + transform.project(const CadPoint3(0.3, 0, 0)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enter known length'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('known_calibration_length')),
      '300',
    );
    await tester.tap(find.byKey(const ValueKey('apply_scale_calibration')));
    await tester.pump();
    expect(find.textContaining('Scale calibrated'), findsOneWidget);
    expect(find.textContaining('L: 300.000 mm'), findsOneWidget);
    expect(
      find.textContaining('Grade: 0.000% · Slope: 1:∞ · Angle: 0.000°'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Horizontal azimuth(+Y, CW): 90.000° · Bearing: E'),
      findsOneWidget,
    );
    expect(find.textContaining('Midpoint: Local X:'), findsOneWidget);
    final distance3DPainter =
        tester.widget<CustomPaint>(paintFinder).painter! as CadScenePainter;
    expect(distance3DPainter.measurementMidpoint, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two face taps measure a winding-neutral plane angle', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final document = CadDocumentModel.fromJson({
      'metadata': {'format': 'stl', 'display_name': 'faces.stl'},
      'scene': {
        'scene_kind': 'three_d',
        'scene': {
          'meshes': [
            {
              'id': 9,
              'name': 'Perpendicular faces',
              'positions': [
                {'x': -1, 'y': -1, 'z': 0},
                {'x': 1, 'y': -1, 'z': 0},
                {'x': 0, 'y': 1, 'z': 0},
                {'x': -1, 'y': 2, 'z': -1},
                {'x': 1, 'y': 2, 'z': -1},
                {'x': 0, 'y': 2, 'z': 1},
                {'x': 1.5, 'y': -1, 'z': -1},
                {'x': 2.5, 'y': -1, 'z': -1},
                {'x': 2, 'y': -1, 'z': 1},
              ],
              'indices': [0, 1, 2, 3, 4, 5, 6, 7, 8],
              'surface_area': 5.0,
            },
          ],
          'root_nodes': [
            {
              'id': 1,
              'name': 'Root',
              'visible': true,
              'mesh_ids': [9],
              'children': <Object>[],
            },
          ],
          'bounds': {
            'min': {'x': -1, 'y': -1, 'z': -1},
            'max': {'x': 2.5, 'y': 2, 'z': 1},
          },
        },
      },
      'diagnostics': <Object>[],
    });
    final opened = OpenedCadDocument(
      sessionId: BigInt.from(9),
      formatId: 'stl',
      sceneKind: 'three_d',
      displayName: 'faces.stl',
      fingerprint: 'face-angle',
      document: document,
      annotations: const [],
      sourcePath: '/tmp/faces.stl',
      totalEntityCount: BigInt.zero,
      isPartial: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: CadViewerPage(engine: _FakeCadEngine(), opened: opened),
      ),
    );
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Views'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('standard_view_top')));
    await tester.pumpAndSettle();

    final paintFinder = cadScenePaintFinder();
    final paintRect = tester.getRect(paintFinder);
    final top = cadStandardViewOrientation(CadStandardView.top);
    final topTransform = Cad3DViewTransform.forScene(
      document,
      paintRect.size,
      1,
      Offset.zero,
      top.yaw,
      top.pitch,
    );
    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final faceAngleTool = find.byKey(const ValueKey('measure_face_angle'));
    await tester.ensureVisible(faceAngleTool);
    await tester.tap(faceAngleTool);
    await tester.pumpAndSettle();
    expect(find.text('Select the first face'), findsOneWidget);
    await tester.tapAt(
      paintRect.topLeft + topTransform.project(const CadPoint3(0, -1 / 3, 0)),
    );
    await tester.pump();
    expect(find.text('Select the second face'), findsOneWidget);
    var painter =
        tester.widget<CustomPaint>(paintFinder).painter! as CadScenePainter;
    expect(painter.measurement3DFaces, hasLength(1));

    await tester.tap(find.text('Views'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('standard_view_front')));
    await tester.pumpAndSettle();
    final front = cadStandardViewOrientation(CadStandardView.front);
    final frontTransform = Cad3DViewTransform.forScene(
      document,
      paintRect.size,
      1,
      Offset.zero,
      front.yaw,
      front.pitch,
    );
    await tester.tapAt(
      paintRect.topLeft + frontTransform.project(const CadPoint3(0, 2, -1 / 3)),
    );
    await tester.pump();
    expect(find.text('Smaller plane angle: 90.000°'), findsOneWidget);
    painter =
        tester.widget<CustomPaint>(paintFinder).painter! as CadScenePainter;
    expect(painter.measurement3DFaces, hasLength(2));
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, 'Smaller plane angle: 90.000°');

    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.text('Smaller plane angle: 90.000°'), findsNothing);
    expect(find.text('Select the second face'), findsOneWidget);
    painter =
        tester.widget<CustomPaint>(paintFinder).painter! as CadScenePainter;
    expect(painter.measurement3DFaces, hasLength(1));
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    expect(find.text('Select the first face'), findsOneWidget);
    painter =
        tester.widget<CustomPaint>(paintFinder).painter! as CadScenePainter;
    expect(painter.measurement3DFaces, isEmpty);

    await tester.tapAt(
      paintRect.topLeft + frontTransform.project(const CadPoint3(0, 2, -1 / 3)),
    );
    await tester.pump();
    await tester.tapAt(
      paintRect.topLeft +
          frontTransform.project(const CadPoint3(2, -1, -1 / 3)),
    );
    await tester.pump();
    expect(find.textContaining('Smaller plane angle: 0.000°'), findsOneWidget);
    expect(
      find.textContaining('Parallel-face spacing: 3.000 DU'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(
      clipboardText,
      'Smaller plane angle: 0.000°\nParallel-face spacing: 3.000 DU',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact viewer toolbar does not overflow and area taps snap', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final engine = _FakeCadEngine();
    final document = CadDocumentModel.fromJson({
      'metadata': {
        'format': 'dxf',
        'display_name': 'compact.dxf',
        'units': 'mm',
      },
      'scene': {
        'scene_kind': 'two_d',
        'scene': {
          'layers': [
            {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
          ],
          'entities': <Object>[
            {
              'id': 1,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'circle',
                'center': {'x': 50, 'y': 50},
                'radius': 10,
              },
            },
            {
              'id': 2,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'arc',
                'center': {'x': 80, 'y': 50},
                'radius': 10,
                'start_angle': 6.1086523819801535,
                'end_angle': 0.17453292519943295,
              },
            },
            {
              'id': 3,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'line',
                'start': {'x': 0, 'y': 0},
                'end': {'x': 30, 'y': 40},
              },
            },
            {
              'id': 4,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'polyline',
                'closed': false,
                'points': [
                  {'x': 0, 'y': 0},
                  {'x': 0, 'y': 30},
                  {'x': 40, 'y': 30},
                ],
              },
            },
            {
              'id': 5,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'polyline',
                'closed': true,
                'points': [
                  {'x': 0, 'y': 0},
                  {'x': 20, 'y': 0},
                  {'x': 20, 'y': 10},
                  {'x': 0, 'y': 10},
                ],
              },
            },
            {
              'id': 6,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'circle',
                'center': {'x': 30, 'y': 30},
                'radius': 5,
              },
            },
            {
              'id': 7,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'line',
                'start': {'x': 0, 'y': 20},
                'end': {'x': 20, 'y': 20},
              },
            },
            {
              'id': 8,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'line',
                'start': {'x': 30, 'y': 30},
                'end': {'x': 30, 'y': 40},
              },
            },
            {
              'id': 9,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'line',
                'start': {'x': 30, 'y': 23},
                'end': {'x': 50, 'y': 23},
              },
            },
            {
              'id': 10,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'circle',
                'center': {'x': 62, 'y': 50},
                'radius': 5,
              },
            },
            {
              'id': 11,
              'layer_id': 1,
              'color_argb': 0xffffffff,
              'stroke_width': 0,
              'filled': false,
              'geometry': {
                'kind': 'arc',
                'center': {'x': 0, 'y': 0},
                'radius': 10,
                'start_angle': 0,
                'end_angle': 1.5707963267948966,
              },
            },
          ],
          'bounds': {
            'min': {'x': 0, 'y': 0},
            'max': {'x': 100, 'y': 100},
          },
        },
      },
      'diagnostics': <Object>[],
    });
    final opened = OpenedCadDocument(
      sessionId: BigInt.one,
      formatId: 'dxf',
      sceneKind: 'two_d',
      displayName: 'compact.dxf',
      fingerprint: 'test',
      document: document,
      annotations: const [],
      sourcePath: '/tmp/compact.dxf',
      totalEntityCount: BigInt.from(500001),
      isPartial: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: CadViewerPage(engine: engine, opened: opened, decimalPlaces: 2),
      ),
    );

    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2.5;
    await tester.pump();
    expect(find.byKey(const ValueKey('viewer_more_actions')), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.pump();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    expect(find.text('Measurement unit'), findsOneWidget);
    expect(find.text('Source: mm · Display: mm'), findsOneWidget);
    await tester.tap(find.text('Measurement unit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('display_unit_cm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2D scene · cm'), findsOneWidget);

    final compactActions = find.byKey(const ValueKey('viewer_more_actions'));
    if (compactActions.evaluate().isNotEmpty) {
      await tester.tap(compactActions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drawing overview'));
    } else {
      await tester.tap(find.byTooltip('Drawing overview'));
    }
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('document_overview_list')),
      findsOneWidget,
    );
    expect(find.text('Entities in drawing'), findsOneWidget);
    expect(find.text('500001'), findsOneWidget);
    expect(find.text('Layers'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('document_overview_list')),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();
    expect(find.text('Minimum coordinate'), findsOneWidget);
    expect(find.text('Maximum coordinate'), findsOneWidget);
    expect(find.text('Width (X)'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('document_overview_list')),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    expect(find.text('Height (Y)'), findsOneWidget);
    expect(find.text('10.00 cm'), findsWidgets);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(clipboardText, startsWith('Drawing overview\nFormat: DXF'));
    expect(clipboardText, contains('Local file path: /tmp/compact.dxf'));
    expect(clipboardText, contains('Entities in drawing: 500001'));
    expect(clipboardText, contains('Width (X): 10.00 cm'));
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Area'));
    await tester.pumpAndSettle();
    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    engine.snapPositionOverride = const Offset(25, 75);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(engine.intersectionSnapRequests, hasLength(1));
    expect(engine.intersectionSnapRequests.single.$3, greaterThan(0));
    expect(engine.snapRequests, isEmpty);
    final intersectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(intersectionPainter.measurementPoints, [const Offset(25, 75)]);
    expect(intersectionPainter.measurementIntersectionPoints, [
      const Offset(25, 75),
    ]);
    expect(find.textContaining('Area:'), findsNothing);
    engine.hitResult = null;
    engine.snapPositionOverride = null;
    engine.snapKind = 'endpoint';
    await tester.tapAt(const Offset(80, 220));
    await tester.pump();
    await tester.tapAt(const Offset(180, 320));
    await tester.pump();
    expect(engine.intersectionSnapRequests, hasLength(3));
    expect(engine.snapRequests, hasLength(2));
    expect(find.textContaining('Centroid:'), findsOneWidget);
    final manualAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(
      manualAreaPainter.measurementCentroid,
      cadPolygonCentroid2D(manualAreaPainter.measurementPoints),
    );
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2.5;
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
    await tester.binding.setSurfaceSize(const Size(590, 320));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    await tester.pump();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final rectangleTool = find.text('Axis-aligned rectangle (2 points)');
    await tester.ensureVisible(rectangleTool);
    await tester.tap(rectangleTool);
    await tester.pumpAndSettle();
    final snapsBeforeRectangle = engine.snapRequests.length;
    await tester.tapAt(const Offset(80, 220));
    await tester.pump();
    expect(find.text('Select the opposite rectangle corner'), findsOneWidget);
    await tester.tapAt(const Offset(180, 320));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeRectangle + 2));
    expect(find.textContaining('W:'), findsOneWidget);
    expect(find.textContaining('Diagonal:'), findsOneWidget);
    expect(find.textContaining('Center:'), findsOneWidget);
    expect(find.textContaining('Area:'), findsOneWidget);
    final rectanglePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(rectanglePainter.measurementRectangle, isTrue);
    expect(rectanglePainter.measurementPoints, hasLength(2));
    expect(
      rectanglePainter.measurementCentroid,
      cadRectangleMeasurement2D(
        rectanglePainter.measurementPoints[0],
        rectanglePainter.measurementPoints[1],
      )?.center,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('W:'));
    expect(clipboardText, contains('Diagonal:'));
    expect(clipboardText, contains('Center:'));
    expect(clipboardText, contains('Perimeter:'));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final rotatedRectangleTool = find.text('Rotated rectangle (3 points)');
    await tester.ensureVisible(rotatedRectangleTool);
    await tester.tap(rotatedRectangleTool);
    await tester.pumpAndSettle();
    final snapsBeforeRotatedRectangle = engine.snapRequests.length;
    await tester.tapAt(const Offset(80, 220));
    await tester.pump();
    expect(find.text('Select a point along the width edge'), findsOneWidget);
    await tester.tapAt(const Offset(180, 270));
    await tester.pump();
    expect(
      find.text('Select a point to set perpendicular height'),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(100, 330));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeRotatedRectangle + 3));
    expect(find.textContaining('Direction(+X):'), findsOneWidget);
    expect(find.textContaining('Diagonal:'), findsOneWidget);
    expect(find.textContaining('Center:'), findsOneWidget);
    expect(find.textContaining('Area:'), findsOneWidget);
    final rotatedRectanglePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(rotatedRectanglePainter.measurementOrientedRectangle, isTrue);
    expect(rotatedRectanglePainter.measurementPoints, hasLength(3));
    expect(
      rotatedRectanglePainter.measurementCentroid,
      cadOrientedRectangleMeasurement2D(
        rotatedRectanglePainter.measurementPoints[0],
        rotatedRectanglePainter.measurementPoints[1],
        rotatedRectanglePainter.measurementPoints[2],
      )?.center,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Direction(+X):'));
    expect(clipboardText, contains('Diagonal:'));
    expect(clipboardText, contains('Center:'));
    expect(clipboardText, contains('Perimeter:'));
    final snapsBeforeRejectedWidth = engine.snapRequests.length;
    engine.snapPositionOverride = const Offset(42, 42);
    await tester.tapAt(const Offset(120, 260));
    await tester.pump();
    await tester.tapAt(const Offset(120, 260));
    await tester.pump(const Duration(milliseconds: 400));
    engine.snapPositionOverride = null;
    expect(engine.snapRequests, hasLength(snapsBeforeRejectedWidth + 2));
    expect(find.text('Select a point along the width edge'), findsOneWidget);
    final rejectedWidthPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(rejectedWidthPainter.measurementPoints, hasLength(1));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final circleTool = find.text('Circle through 3 points');
    await tester.ensureVisible(circleTool);
    await tester.tap(circleTool);
    await tester.pumpAndSettle();
    final snapsBeforeCircle = engine.snapRequests.length;
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(find.text('Select the second circumference point'), findsOneWidget);
    await tester.tapAt(const Offset(180, 260));
    await tester.pump();
    expect(find.text('Select a non-collinear third point'), findsOneWidget);
    await tester.tapAt(const Offset(110, 330));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeCircle + 3));
    expect(find.textContaining('Center:'), findsOneWidget);
    expect(find.textContaining('Circumference:'), findsOneWidget);
    final circlePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(circlePainter.measurementCircle3Point, isTrue);
    expect(circlePainter.measurementPoints, hasLength(3));
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Center:'));
    expect(clipboardText, contains('Circumference:'));
    expect(clipboardText, contains('Area:'));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final arcTool = find.text('Arc through 3 points');
    await tester.ensureVisible(arcTool);
    await tester.tap(arcTool);
    await tester.pumpAndSettle();
    expect(find.text('Select the arc start point'), findsOneWidget);
    final snapsBeforeArc = engine.snapRequests.length;
    engine.snapPositionOverride = const Offset(10, 0);
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(find.text('Select a point on the arc'), findsOneWidget);
    engine.snapPositionOverride = const Offset(0, 10);
    await tester.tapAt(const Offset(140, 220));
    await tester.pump();
    expect(find.text('Select the arc end point'), findsOneWidget);
    engine.snapPositionOverride = const Offset(-10, 0);
    await tester.tapAt(const Offset(180, 220));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeArc + 3));
    expect(find.textContaining('Central angle: 180.00°'), findsOneWidget);
    expect(find.textContaining('Arc: 3.14 cm'), findsOneWidget);
    expect(find.textContaining('Chord: 2.00 cm'), findsOneWidget);
    expect(find.textContaining('Direction: Counterclockwise'), findsOneWidget);
    expect(
      find.textContaining('Sector area: 1.57 cm² · Segment area: 1.57 cm²'),
      findsOneWidget,
    );
    expect(find.textContaining('Sagitta: 1.00 cm'), findsOneWidget);
    expect(
      find.textContaining('Chord azimuth (+Y, CW): 270.00°'),
      findsOneWidget,
    );
    expect(find.textContaining('Chord bearing: W'), findsOneWidget);
    var arcPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(arcPainter.measurementArc3Point, isTrue);
    expect(arcPainter.measurementPoints, const [
      Offset(10, 0),
      Offset(0, 10),
      Offset(-10, 0),
    ]);
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Central angle: 180.00°'));
    expect(clipboardText, contains('Direction: Counterclockwise'));
    expect(
      clipboardText,
      contains('Sector area: 1.57 cm² · Segment area: 1.57 cm²'),
    );
    expect(clipboardText, contains('Sagitta: 1.00 cm'));
    expect(clipboardText, contains('Chord azimuth (+Y, CW): 270.00°'));
    expect(clipboardText, contains('Chord bearing: W'));

    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Central angle:'), findsNothing);
    expect(find.text('Select the arc end point'), findsOneWidget);
    arcPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(arcPainter.measurementPoints, hasLength(2));
    await tester.tapAt(const Offset(180, 220));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeArc + 4));
    expect(find.textContaining('Central angle: 180.00°'), findsOneWidget);
    engine.snapPositionOverride = null;

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final intersectionTool = find.text('Extended-line intersection');
    await tester.ensureVisible(intersectionTool);
    await tester.tap(intersectionTool);
    await tester.pumpAndSettle();
    expect(find.text('Select the first line segment'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(7),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select the second line segment'), findsOneWidget);
    var lineIntersectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(lineIntersectionPainter.selectedEntityIds, {BigInt.from(7)});
    expect(lineIntersectionPainter.measurementPoints, const [
      Offset(0, 20),
      Offset(20, 20),
    ]);

    engine.hitResult = CadHit(
      entityId: BigInt.from(8),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Intersection: X: 3.00 cm'), findsOneWidget);
    expect(find.textContaining('Included angle: 90.00°'), findsOneWidget);
    expect(
      find.textContaining('Extension: 1 1.00 cm · 2 1.00 cm'),
      findsOneWidget,
    );
    expect(find.textContaining('Segments: 1/1 · 2/1'), findsOneWidget);
    expect(
      find.textContaining('Both segments require extension'),
      findsOneWidget,
    );
    lineIntersectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(lineIntersectionPainter.measurementLineIntersection, isTrue);
    expect(lineIntersectionPainter.selectedEntityIds, {
      BigInt.from(7),
      BigInt.from(8),
    });
    expect(lineIntersectionPainter.measurementPoints, const [
      Offset(0, 20),
      Offset(20, 20),
      Offset(30, 30),
      Offset(30, 40),
      Offset(30, 20),
    ]);
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Intersection: X: 3.00 cm'));
    expect(clipboardText, contains('Both segments require extension'));

    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Included angle:'), findsNothing);
    expect(find.text('Select the second line segment'), findsOneWidget);
    lineIntersectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(lineIntersectionPainter.selectedEntityIds, {BigInt.from(7)});
    expect(lineIntersectionPainter.measurementPoints, hasLength(2));

    engine.hitResult = CadHit(
      entityId: BigInt.from(7),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.text('The selected segments are parallel or too nearly parallel'),
      findsOneWidget,
    );
    expect(find.text('Select the second line segment'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final parallelSpacingTool = find.text('Parallel-line spacing');
    await tester.ensureVisible(parallelSpacingTool);
    await tester.tap(parallelSpacingTool);
    await tester.pumpAndSettle();
    expect(find.text('Select the first parallel segment'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(7),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select the second parallel segment'), findsOneWidget);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select a different parallel segment'), findsOneWidget);
    expect(find.text('Select the second parallel segment'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(9),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Perpendicular spacing: 0.30 cm'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Undirected direction(+X): 0.00°'),
      findsOneWidget,
    );
    final parallelSpacingPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(parallelSpacingPainter.measurementParallelLineSpacing, isTrue);
    expect(parallelSpacingPainter.selectedEntityIds, {
      BigInt.from(7),
      BigInt.from(9),
    });
    expect(parallelSpacingPainter.measurementPoints, const [
      Offset(0, 20),
      Offset(20, 20),
      Offset(30, 23),
      Offset(50, 23),
      Offset(40, 20),
      Offset(40, 23),
    ]);
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Perpendicular spacing:'), findsNothing);
    expect(find.text('Select the second parallel segment'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(8),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('The selected segments are not parallel'), findsOneWidget);
    expect(find.text('Select the second parallel segment'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final segmentClearanceTool = find.text('Finite-segment clearance');
    await tester.ensureVisible(segmentClearanceTool);
    await tester.tap(segmentClearanceTool);
    await tester.pumpAndSettle();
    expect(find.text('Select the first finite segment'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(7),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select the second finite segment'), findsOneWidget);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select a different finite segment'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(8),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Finite-segment clearance: 1.41 cm'),
      findsOneWidget,
    );
    expect(find.textContaining('Nearest point 1: X: 2.00 cm'), findsOneWidget);
    expect(find.textContaining('Nearest point 2: X: 3.00 cm'), findsOneWidget);
    expect(
      find.textContaining('Direction 1→2: 45.00° · N 45.00° E'),
      findsOneWidget,
    );
    expect(
      find.textContaining('The selected finite segments are separated'),
      findsOneWidget,
    );
    var segmentClearancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(segmentClearancePainter.measurementSegmentClearance, isTrue);
    expect(segmentClearancePainter.selectedEntityIds, {
      BigInt.from(7),
      BigInt.from(8),
    });
    expect(segmentClearancePainter.measurementPoints, const [
      Offset(0, 20),
      Offset(20, 20),
      Offset(30, 30),
      Offset(30, 40),
      Offset(20, 20),
      Offset(30, 30),
    ]);
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Finite-segment clearance: 1.41 cm'));
    expect(clipboardText, contains('Direction 1→2: 45.00°'));
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Finite-segment clearance:'), findsNothing);
    expect(find.text('Select the second finite segment'), findsOneWidget);
    segmentClearancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(segmentClearancePainter.measurementPoints, hasLength(2));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final offsetTool = find.text('Baseline offset (3 points)');
    await tester.ensureVisible(offsetTool);
    await tester.tap(offsetTool);
    await tester.pumpAndSettle();
    final snapsBeforeOffset = engine.snapRequests.length;
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(find.text('Select the baseline direction point'), findsOneWidget);
    await tester.tapAt(const Offset(180, 220));
    await tester.pump();
    expect(
      find.text('Select the point to measure from the baseline'),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(140, 300));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeOffset + 3));
    expect(find.textContaining('Perpendicular:'), findsOneWidget);
    expect(find.textContaining('Offset(L+):'), findsOneWidget);
    expect(find.textContaining('Foot:'), findsOneWidget);
    final offsetPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(offsetPainter.measurementPointLineOffset, isTrue);
    expect(offsetPainter.measurementPoints, hasLength(3));
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Station from start:'));
    expect(clipboardText, contains('Direction(+X):'));
    expect(clipboardText, contains('Foot:'));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Angle'));
    await tester.pumpAndSettle();
    final snapsBeforeAngle = engine.snapRequests.length;
    for (final point in const [
      Offset(100, 220),
      Offset(160, 220),
      Offset(100, 280),
    ]) {
      await tester.tapAt(point);
      await tester.pump();
    }
    expect(engine.snapRequests, hasLength(snapsBeforeAngle + 3));
    expect(find.textContaining('Angles A/B/C:'), findsOneWidget);
    expect(find.textContaining('Sides AB/AC/BC:'), findsOneWidget);
    expect(find.textContaining('Area:'), findsOneWidget);
    expect(find.textContaining('Height A→BC:'), findsOneWidget);
    expect(find.textContaining('Inradius:'), findsOneWidget);
    expect(find.textContaining('Circumradius:'), findsOneWidget);
    final trianglePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(trianglePainter.measurementAngle, isTrue);
    expect(trianglePainter.measurementPoints, hasLength(3));
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Angles A/B/C:'));
    expect(clipboardText, contains('Sides AB/AC/BC:'));
    expect(clipboardText, contains('Perimeter:'));
    expect(clipboardText, contains('Height A→BC:'));
    expect(clipboardText, contains('Circumradius:'));

    engine.snapPositionOverride = const Offset(42, 42);
    final snapsBeforeRejectedAngle = engine.snapRequests.length;
    await tester.tapAt(const Offset(120, 260));
    await tester.pump();
    await tester.tapAt(const Offset(120, 260));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeRejectedAngle + 2));
    expect(
      find.text('A ray point must differ from the angle vertex'),
      findsOneWidget,
    );
    final rejectedAnglePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(rejectedAnglePainter.measurementPoints, hasLength(1));
    engine.snapPositionOverride = null;

    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Radius / diameter'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Center: X: 5.00 cm · Y: 5.00 cm'),
      findsOneWidget,
    );
    expect(find.textContaining('R: 1.00 cm · Ø: 2.00 cm'), findsOneWidget);
    expect(
      find.textContaining('Circumference: 6.28 cm · Area: 3.14 cm²'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Circumference:'));
    expect(clipboardText, contains('Area:'));

    engine.hitResult = CadHit(
      entityId: BigInt.two,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'arc',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Center: X: 8.00 cm'), findsOneWidget);
    expect(find.textContaining('Sweep: 20.00°'), findsOneWidget);
    expect(find.textContaining('Arc length: 0.35 cm'), findsOneWidget);
    expect(find.textContaining('Chord: 0.35 cm'), findsOneWidget);
    expect(
      find.textContaining(
        'Simple curve (Δ < 180°): T 0.18 cm · E 0.02 cm · M 0.02 cm',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('PI: X: 9.02 cm · Y: 5.00 cm'), findsOneWidget);
    expect(
      find.textContaining(
        'Tangents start→PI / PI→end: 10.00° N 10.00° E · 350.00° N 10.00° W',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Sweep: 20.00°'));
    expect(clipboardText, contains('Chord: 0.35 cm'));
    expect(clipboardText, contains('Simple curve (Δ < 180°):'));
    expect(clipboardText, contains('PI: X: 9.02 cm · Y: 5.00 cm'));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final radialClearanceTool = find.text('Circle / arc clearance');
    await tester.ensureVisible(radialClearanceTool);
    await tester.tap(radialClearanceTool);
    await tester.pumpAndSettle();
    expect(find.text('Select the first circle or arc'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select the second circle or arc'), findsOneWidget);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Select a different circle or arc'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(10),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Center distance: 1.20 cm'), findsOneWidget);
    expect(
      find.textContaining('Signed edge clearance: -0.30 cm · overlap'),
      findsOneWidget,
    );
    expect(find.textContaining('R1: 1.00 cm · R2: 0.50 cm'), findsOneWidget);
    expect(find.textContaining('Direction 1→2(+X): 0.00°'), findsOneWidget);
    final radialClearancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(radialClearancePainter.selectedEntityIds, {
      BigInt.one,
      BigInt.from(10),
    });
    expect(radialClearancePainter.measurementPoints, const [
      Offset(50, 50),
      Offset(62, 50),
    ]);
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Signed edge clearance: -0.30 cm'));
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Signed edge clearance:'), findsNothing);
    expect(find.text('Select the second circle or arc'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final entityLengthTool = find.text('Entity length total');
    await tester.ensureVisible(entityLengthTool);
    await tester.tap(entityLengthTool);
    await tester.pumpAndSettle();
    expect(find.textContaining('0 selected'), findsOneWidget);

    engine.hitResult = CadHit(
      entityId: BigInt.from(3),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 1 · Total length: 5.00 cm'),
      findsOneWidget,
    );

    engine.hitResult = CadHit(
      entityId: BigInt.from(4),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'polyline',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 2 · Total length: 12.00 cm'),
      findsOneWidget,
    );
    var lengthPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(lengthPainter.selectedEntityIds, {BigInt.from(3), BigInt.from(4)});

    engine.hitResult = CadHit(
      entityId: BigInt.from(3),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 1 · Total length: 7.00 cm'),
      findsOneWidget,
    );

    engine.hitResult = CadHit(
      entityId: BigInt.two,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'arc',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 2 · Total length: 7.35 cm'),
      findsOneWidget,
    );
    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 3 · Total length: 13.63 cm'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Undo last entity'));
    await tester.pump();
    expect(
      find.textContaining('Selected: 2 · Total length: 7.35 cm'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Total length: 7.35 cm'));
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quantity_linear_material')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('quantity_plan_slope')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quantity_plan_slope')));
    await tester.pumpAndSettle();
    expect(find.text('Slope from plan run'), findsOneWidget);
    expect(
      find.text(
        'Treats the measured 2D length as horizontal run. Enter a '
        'non-negative vertical rise; uphill/downhill direction is not '
        'inferred.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calculate_plan_slope')));
    await tester.pump();
    expect(
      find.text('Enter a finite vertical rise of zero or greater'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('plan_slope_rise')), '4');
    await tester.tap(find.byKey(const ValueKey('calculate_plan_slope')));
    await tester.pumpAndSettle();
    expect(find.text('Horizontal plan run'), findsOneWidget);
    expect(find.text('7.35 cm'), findsOneWidget);
    expect(find.text('Vertical rise'), findsOneWidget);
    expect(find.text('4.00 cm'), findsOneWidget);
    expect(find.text('Slope length'), findsOneWidget);
    expect(find.text('8.37 cm'), findsOneWidget);
    expect(find.text('Grade'), findsOneWidget);
    expect(find.text('54.43%'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Slope angle'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Slope ratio (V:H)'), findsOneWidget);
    expect(find.text('1:1.84'), findsOneWidget);
    expect(find.text('Slope angle'), findsOneWidget);
    expect(find.text('28.56°'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Slope from plan run\n'
      'Horizontal plan run: 7.35 cm\n'
      'Vertical rise: 4.00 cm\n'
      'Slope length: 8.37 cm\n'
      'Grade: 54.43%\n'
      'Slope ratio (V:H): 1:1.84\n'
      'Slope angle: 28.56°',
    );
    await tester.tap(find.byKey(const ValueKey('property_sheet_action')));
    await tester.pumpAndSettle();
    expect(find.text('Linear material quantity'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_linear_material')));
    await tester.pumpAndSettle();
    expect(find.text('Linear material quantity'), findsOneWidget);
    expect(
      find.text(
        'Aggregate estimator: assumes splicing is allowed and offcuts are '
        'fully reusable; this is not a cut-list optimizer. Enter usable '
        'length per whole unit and optional 0–100% waste.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calculate_linear_quantity')));
    await tester.pump();
    expect(
      find.text(
        'Enter a length per unit greater than zero and waste from 0% to 100%',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('linear_length_per_unit')),
      '2,0',
    );
    await tester.enterText(
      find.byKey(const ValueKey('linear_waste_percent')),
      '10',
    );
    await tester.tap(find.byKey(const ValueKey('calculate_linear_quantity')));
    await tester.pumpAndSettle();
    expect(find.text('Source length'), findsOneWidget);
    expect(find.text('7.35 cm'), findsOneWidget);
    expect(find.text('Length per unit'), findsOneWidget);
    expect(find.text('2.00 cm'), findsOneWidget);
    expect(find.text('Waste allowance'), findsOneWidget);
    expect(find.text('10.00%'), findsOneWidget);
    expect(find.text('Length including waste'), findsOneWidget);
    expect(find.text('8.08 cm'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Procured total length'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Exact units required'), findsOneWidget);
    expect(find.text('4.04'), findsOneWidget);
    expect(find.text('Whole units to procure'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('Procured total length'), findsOneWidget);
    expect(find.text('10.00 cm'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Length remaining'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('1.92 cm'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Calculation basis'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      find.text('Aggregate length · Splicing allowed · Offcuts fully reusable'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Linear material quantity\n'
      'Source length: 7.35 cm\n'
      'Length per unit: 2.00 cm\n'
      'Waste allowance: 10.00%\n'
      'Length including waste: 8.08 cm\n'
      'Exact units required: 4.04\n'
      'Whole units to procure: 5\n'
      'Procured total length: 10.00 cm\n'
      'Length remaining: 1.92 cm\n'
      'Calculation basis: Aggregate length · Splicing allowed · '
      'Offcuts fully reusable',
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear entity selection'));
    await tester.pump();
    lengthPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(lengthPainter.selectedEntityIds, isEmpty);
    expect(find.textContaining('Total length:'), findsNothing);

    engine.hitResult = CadHit(
      entityId: BigInt.from(99),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'text',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(
      find.text('This entity has no measurable curve length'),
      findsOneWidget,
    );

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final entityAreaTool = find.text('Area takeoff (gross / net)');
    await tester.ensureVisible(entityAreaTool);
    await tester.tap(entityAreaTool);
    await tester.pumpAndSettle();
    expect(find.textContaining('Mode: Add'), findsOneWidget);

    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Net area: 3.14 cm²'), findsOneWidget);
    expect(find.textContaining('Added: 3.14 cm²'), findsOneWidget);
    expect(find.textContaining('Deducted: 0.00 cm²'), findsOneWidget);
    expect(find.textContaining('Boundary total: 6.28 cm'), findsOneWidget);

    engine.hitResult = CadHit(
      entityId: BigInt.from(5),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'polyline',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 2 · Net area: 5.14 cm²'),
      findsOneWidget,
    );
    expect(find.textContaining('Boundary total: 12.28 cm'), findsOneWidget);
    var grossAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(grossAreaPainter.selectedEntityIds, {BigInt.one, BigInt.from(5)});

    await tester.tap(
      find.byTooltip('Adding boundaries · switch to deduct openings'),
    );
    await tester.pump();
    expect(find.textContaining('Mode: Deduct'), findsOneWidget);
    engine.hitResult = CadHit(
      entityId: BigInt.from(6),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 3 · Net area: 4.36 cm²'),
      findsOneWidget,
    );
    expect(find.textContaining('Added: 5.14 cm²'), findsOneWidget);
    expect(find.textContaining('Deducted: 0.79 cm²'), findsOneWidget);
    expect(find.textContaining('Boundary total: 15.42 cm'), findsOneWidget);
    grossAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(grossAreaPainter.subtractedEntityIds, {BigInt.from(6)});
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Selected: 2 · Net area: 5.14 cm²'),
      findsOneWidget,
    );
    grossAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(grossAreaPainter.subtractedEntityIds, isEmpty);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    await tester.tap(find.byTooltip('Undo last entity'));
    await tester.pump();
    expect(
      find.textContaining('Selected: 2 · Net area: 5.14 cm²'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Net area: 5.14 cm²'));
    expect(clipboardText, contains('Added: 5.14 cm²'));
    expect(clipboardText, contains('Deducted: 0.00 cm²'));
    await tester.tap(find.byTooltip('Clear entity selection'));
    await tester.pump();
    grossAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(grossAreaPainter.selectedEntityIds, isEmpty);
    expect(grossAreaPainter.subtractedEntityIds, isEmpty);
    expect(find.textContaining('Net area:'), findsNothing);

    engine.hitResult = CadHit(
      entityId: BigInt.from(6),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    await tester.tap(
      find.byTooltip('Adding boundaries · switch to deduct openings'),
    );
    await tester.pump();
    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Net area: -2.36 cm²'), findsOneWidget);
    grossAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(grossAreaPainter.subtractedEntityIds, {BigInt.one});
    await tester.tap(find.byTooltip('Clear entity selection'));
    await tester.pump();

    engine.hitResult = CadHit(
      entityId: BigInt.from(3),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'line',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.text('Select a circle or a valid simple closed polyline'),
      findsOneWidget,
    );

    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Area'));
    await tester.pumpAndSettle();
    final snapsBeforeEntityArea = engine.snapRequests.length;
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.textContaining('Area: 3.14 cm² · Perimeter: 6.28 cm'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Centroid: X: 5.00 cm · Y: 5.00 cm'),
      findsOneWidget,
    );
    expect(find.textContaining('Equivalent circle Ø: 2.00 cm'), findsOneWidget);
    expect(
      find.textContaining(
        'Hydraulic radius A/P: 0.50 cm · '
        'Hydraulic diameter 4A/P: 2.00 cm',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Compactness 4πA/P²: 1.00'), findsOneWidget);
    expect(
      find.text('Tap another closed boundary to measure it'),
      findsOneWidget,
    );
    expect(engine.snapRequests, hasLength(snapsBeforeEntityArea + 1));
    final entityAreaPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(entityAreaPainter.measurementCentroid, const Offset(50, 50));
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    expect(find.text('Engineering quantities'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quantity_linear_material')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('quantity_coverage')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('quantity_volume')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('engineering_quantity_list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const ValueKey('quantity_volume')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('quantity_average_end_area')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('engineering_quantity_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('engineering_quantity_list')),
      const Offset(0, -100),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quantity_average_end_area')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('quantity_average_end_area')));
    await tester.pumpAndSettle();
    expect(find.text('Average-end-area volume'), findsOneWidget);
    expect(
      find.text(
        'Enter the other end area and section interval. '
        'Uses V = L × (A₁ + A₂) / 2; the drawing is unchanged.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calculate_average_end_area')));
    await tester.pump();
    expect(
      find.text(
        'Enter an end area of zero or greater and a section interval greater '
        'than zero',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('average_end_second_area')),
      '5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('average_end_interval')),
      '2',
    );
    await tester.tap(find.byKey(const ValueKey('calculate_average_end_area')));
    await tester.pumpAndSettle();
    expect(find.text('First end area'), findsOneWidget);
    expect(find.text('3.14 cm²'), findsOneWidget);
    expect(find.text('Second end area'), findsOneWidget);
    expect(find.text('5.00 cm²'), findsOneWidget);
    expect(find.text('Section interval'), findsOneWidget);
    expect(find.text('2.00 cm'), findsOneWidget);
    expect(find.text('Mean end area'), findsOneWidget);
    expect(find.text('4.07 cm²'), findsOneWidget);
    expect(find.text('Computed volume'), findsOneWidget);
    expect(find.text('8.14 cm³'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Average-end-area volume\n'
      'First end area: 3.14 cm²\n'
      'Second end area: 5.00 cm²\n'
      'Section interval: 2.00 cm\n'
      'Mean end area: 4.07 cm²\n'
      'Computed volume: 8.14 cm³',
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('quantity_prismoidal_volume')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('engineering_quantity_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('engineering_quantity_list')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_prismoidal_volume')));
    await tester.pumpAndSettle();
    expect(find.text('Prismoidal volume'), findsOneWidget);
    expect(
      find.text(
        'Enter the section area measured exactly halfway along the interval '
        '(L/2) and the other end area. Uses V = L × (A₁ + 4Aₘ + A₂) / '
        '6; the midpoint section must be at L/2.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calculate_prismoidal_volume')));
    await tester.pump();
    expect(
      find.text(
        'Enter midpoint and other end areas of zero or greater, and an '
        'interval greater than zero',
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('prismoidal_midpoint_area')),
      '4,0',
    );
    await tester.enterText(
      find.byKey(const ValueKey('prismoidal_second_area')),
      '5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('prismoidal_interval')),
      '2',
    );
    await tester.tap(find.byKey(const ValueKey('calculate_prismoidal_volume')));
    await tester.pumpAndSettle();
    expect(find.text('First end area'), findsOneWidget);
    expect(find.text('3.14 cm²'), findsOneWidget);
    expect(find.text('Midpoint area (L/2)'), findsOneWidget);
    expect(find.text('4.00 cm²'), findsOneWidget);
    expect(find.text('Second end area'), findsOneWidget);
    expect(find.text('5.00 cm²'), findsOneWidget);
    expect(find.text('Section interval'), findsOneWidget);
    expect(find.text('2.00 cm'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Prismoidal weighted mean area'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('4.02 cm²'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Computed volume'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Computed volume'), findsOneWidget);
    expect(find.text('8.05 cm³'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Prismoidal volume\n'
      'First end area: 3.14 cm²\n'
      'Midpoint area (L/2): 4.00 cm²\n'
      'Second end area: 5.00 cm²\n'
      'Section interval: 2.00 cm\n'
      'Prismoidal weighted mean area: 4.02 cm²\n'
      'Computed volume: 8.05 cm³',
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('quantity_section_properties')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('engineering_quantity_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('engineering_quantity_list')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_section_properties')));
    await tester.pumpAndSettle();
    expect(find.text('Section properties'), findsOneWidget);
    expect(find.text('Drawing origin (absolute)'), findsOneWidget);
    expect(find.text('3.14 cm²'), findsOneWidget);
    expect(find.text('X: 5.00 cm · Y: 5.00 cm'), findsOneWidget);
    expect(find.text('Ix,c = ∫y² dA'), findsOneWidget);
    expect(find.text('0.79 cm⁴'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Jc = Ix,c + Iy,c'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('1.57 cm⁴'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Imax axis direction (+X, CCW)'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Imax'), findsOneWidget);
    expect(find.text('Imin'), findsOneWidget);
    expect(
      find.text('Undefined (all centroidal axes are principal)'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('ky = √(Iy,c / A)'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('0.50 cm'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Sy(−X) = Iy,c / c(−X)'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('0.79 cm³'), findsWidgets);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(clipboardText, startsWith('Section properties\n'));
    expect(clipboardText, contains('Ix,c = ∫y² dA: 0.79 cm⁴'));
    expect(clipboardText, contains('Jc = Ix,c + Iy,c: 1.57 cm⁴'));
    expect(clipboardText, contains('Imax: 0.79 cm⁴'));
    expect(clipboardText, contains('Imin: 0.79 cm⁴'));
    expect(
      clipboardText,
      contains(
        'Imax axis direction (+X, CCW): '
        'Undefined (all centroidal axes are principal)',
      ),
    );
    expect(clipboardText, contains('kx = √(Ix,c / A): 0.50 cm'));
    expect(clipboardText, contains('Sx(+Y) = Ix,c / c(+Y): 0.79 cm³'));
    expect(clipboardText, contains('Sx(−Y) = Ix,c / c(−Y): 0.79 cm³'));
    expect(clipboardText, contains('Sy(+X) = Iy,c / c(+X): 0.79 cm³'));
    expect(clipboardText, contains('Sy(−X) = Iy,c / c(−X): 0.79 cm³'));
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_coverage')));
    await tester.pumpAndSettle();
    expect(find.text('Material coverage quantity'), findsOneWidget);
    expect(
      find.text(
        'Enter the area covered by one whole unit and optional 0–100% waste; '
        'procurement units are rounded up',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('coverage_waste_percent')),
          )
          .controller!
          .text,
      '0',
    );
    await tester.tap(find.byKey(const ValueKey('calculate_coverage_quantity')));
    await tester.pump();
    expect(
      find.text('Enter coverage greater than zero and waste from 0% to 100%'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('coverage_area_per_unit')),
      '0,5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('coverage_waste_percent')),
      '10',
    );
    await tester.tap(find.byKey(const ValueKey('calculate_coverage_quantity')));
    await tester.pumpAndSettle();
    expect(find.text('Source area'), findsOneWidget);
    expect(find.text('3.14 cm²'), findsOneWidget);
    expect(find.text('Coverage per unit'), findsOneWidget);
    expect(find.text('0.50 cm²'), findsOneWidget);
    expect(find.text('Waste allowance'), findsOneWidget);
    expect(find.text('10.00%'), findsOneWidget);
    expect(find.text('Area including waste'), findsOneWidget);
    expect(find.text('3.46 cm²'), findsOneWidget);
    expect(find.text('Exact units required'), findsOneWidget);
    expect(find.text('6.91'), findsOneWidget);
    expect(find.text('Whole units to procure'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Procured coverage area'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Procured coverage area'), findsOneWidget);
    expect(find.text('3.50 cm²'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Coverage remaining'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Coverage remaining'), findsOneWidget);
    expect(find.text('0.04 cm²'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Material coverage quantity\n'
      'Source area: 3.14 cm²\n'
      'Coverage per unit: 0.50 cm²\n'
      'Waste allowance: 10.00%\n'
      'Area including waste: 3.46 cm²\n'
      'Exact units required: 6.91\n'
      'Whole units to procure: 7\n'
      'Procured coverage area: 3.50 cm²\n'
      'Coverage remaining: 0.04 cm²',
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('quantity_volume')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('engineering_quantity_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('engineering_quantity_list')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_volume')));
    await tester.pumpAndSettle();
    expect(find.text('Volume from area'), findsOneWidget);
    expect(
      find.text(
        'Enter one positive constant thickness or depth. '
        'The source drawing is unchanged.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calculate_volume')));
    await tester.pump();
    expect(
      find.text('Enter a thickness or depth greater than zero'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('volume_depth')), '2');
    await tester.tap(find.byKey(const ValueKey('calculate_volume')));
    await tester.pumpAndSettle();
    expect(find.text('Source area'), findsOneWidget);
    expect(find.text('3.14 cm²'), findsOneWidget);
    expect(find.text('Thickness / depth'), findsOneWidget);
    expect(find.text('2.00 cm'), findsOneWidget);
    expect(find.text('Prismatic volume'), findsOneWidget);
    expect(find.text('6.28 cm³'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Volume from area\n'
      'Source area: 3.14 cm²\n'
      'Thickness / depth: 2.00 cm\n'
      'Prismatic volume: 6.28 cm³',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const ValueKey('property_sheet_action')));
    await tester.pumpAndSettle();
    expect(find.text('Mass from density'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('calculate_mass')));
    await tester.pump();
    expect(find.text('Enter a density greater than zero'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('density_unit')));
    await tester.pumpAndSettle();
    expect(find.text('lb/ft³'), findsOneWidget);
    await tester.tap(find.text('t/m³').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('density_value')), '2.4');
    await tester.tap(find.byKey(const ValueKey('calculate_mass')));
    await tester.pumpAndSettle();
    expect(find.text('Source volume'), findsOneWidget);
    expect(find.text('6.28 cm³'), findsOneWidget);
    expect(find.text('Material density'), findsOneWidget);
    expect(find.text('2.40 t/m³'), findsOneWidget);
    expect(find.text('Material mass'), findsOneWidget);
    expect(find.text('0.02 kg · 0.00 t · 0.03 lb'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Mass from density\n'
      'Source volume: 6.28 cm³\n'
      'Material density: 2.40 t/m³\n'
      'Material mass: 0.02 kg · 0.00 t · 0.03 lb',
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('quantity_lateral_area')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('engineering_quantity_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('engineering_quantity_list')),
      const Offset(0, -60),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_lateral_area')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Enter one positive constant height. Computes perimeter × height only; '
        'end caps are excluded.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('calculate_lateral_area')));
    await tester.pump();
    expect(find.text('Enter a height greater than zero'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('perimeter_height')), '3');
    await tester.tap(find.byKey(const ValueKey('calculate_lateral_area')));
    await tester.pumpAndSettle();
    expect(find.text('Source perimeter'), findsOneWidget);
    expect(find.text('6.28 cm'), findsOneWidget);
    expect(find.text('Height'), findsOneWidget);
    expect(find.text('3.00 cm'), findsOneWidget);
    expect(find.text('Lateral area'), findsOneWidget);
    expect(find.text('18.85 cm²'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Lateral area from perimeter\n'
      'Source perimeter: 6.28 cm\n'
      'Height: 3.00 cm\n'
      'Lateral area: 18.85 cm²',
    );
    await tester.tap(find.byKey(const ValueKey('property_sheet_action')));
    await tester.pumpAndSettle();
    expect(find.text('Material coverage quantity'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('coverage_area_per_unit')),
      '1',
    );
    await tester.tap(find.byKey(const ValueKey('calculate_coverage_quantity')));
    await tester.pumpAndSettle();
    expect(find.text('Source area'), findsOneWidget);
    expect(find.text('18.85 cm²'), findsWidgets);
    expect(find.text('Coverage per unit'), findsOneWidget);
    expect(find.text('1.00 cm²'), findsOneWidget);
    expect(find.text('Area including waste'), findsOneWidget);
    expect(find.text('Exact units required'), findsOneWidget);
    expect(find.text('18.85'), findsOneWidget);
    expect(find.text('Whole units to procure'), findsOneWidget);
    expect(find.text('19'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Procured coverage area'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('19.00 cm²'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Coverage remaining'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('property_list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('0.15 cm²'), findsOneWidget);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(
      clipboardText,
      'Material coverage quantity\n'
      'Source area: 18.85 cm²\n'
      'Coverage per unit: 1.00 cm²\n'
      'Waste allowance: 0.00%\n'
      'Area including waste: 18.85 cm²\n'
      'Exact units required: 18.85\n'
      'Whole units to procure: 19\n'
      'Procured coverage area: 19.00 cm²\n'
      'Coverage remaining: 0.15 cm²',
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);

    engine.hitResult = CadHit(
      entityId: BigInt.from(5),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'polyline',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    var boundaryPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(boundaryPainter.measurementPoints, isEmpty);
    expect(boundaryPainter.indexedMeasurementPoints, const [
      Offset(0, 0),
      Offset(20, 0),
      Offset(20, 10),
      Offset(0, 10),
    ]);
    await tester.tap(find.byTooltip('View boundary report'));
    await tester.pumpAndSettle();
    expect(find.text('Boundary edges · 4'), findsOneWidget);
    expect(find.text('P1 → P2'), findsOneWidget);
    expect(
      find.textContaining('Length: 2.00 cm · Azimuth: 90.00°'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Interior: 90.00° · Deflection(convex+): 90.00°'),
      findsWidgets,
    );
    expect(find.textContaining('Convex'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('copy_boundary_csv')));
    await tester.pumpAndSettle();
    expect(
      clipboardText,
      'Edge,From,To,Length,Unit,Azimuth_deg,Bearing,'
      'InteriorAngle_deg,Deflection_deg,VertexType,Reference\n'
      'E1,P1,P2,2.00,cm,90.00,E,90.00,90.00,convex,Drawing\n'
      'E2,P2,P3,1.00,cm,0.00,N,90.00,90.00,convex,Drawing\n'
      'E3,P3,P4,2.00,cm,270.00,W,90.00,90.00,convex,Drawing\n'
      'E4,P4,P1,1.00,cm,180.00,S,90.00,90.00,convex,Drawing',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    boundaryPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(boundaryPainter.indexedMeasurementPoints, isEmpty);
    expect(find.byTooltip('View boundary report'), findsNothing);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Path length'));
    await tester.pumpAndSettle();
    final snapsBeforePath = engine.snapRequests.length;
    await tester.tapAt(const Offset(80, 220));
    await tester.pump();
    await tester.tapAt(const Offset(180, 320));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforePath + 2));
    expect(find.textContaining('Length:'), findsOneWidget);
    expect(find.byTooltip('Engineering quantities'), findsOneWidget);
    await tester.tap(find.byTooltip('Engineering quantities'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quantity_linear_material')),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinates'));
    await tester.pumpAndSettle();
    final snapsBeforeCoordinates = engine.snapRequests.length;
    await tester.tapAt(const Offset(120, 260));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeCoordinates + 1));
    expect(find.textContaining('X:'), findsOneWidget);
    expect(find.textContaining('Y:'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Distance'));
    await tester.pumpAndSettle();
    final snapsBeforeDistance = engine.snapRequests.length;
    await tester.tapAt(const Offset(80, 220));
    await tester.pump();
    await tester.tapAt(const Offset(180, 320));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeDistance + 2));
    expect(find.textContaining('ΔX:'), findsOneWidget);
    expect(find.textContaining('ΔY:'), findsOneWidget);
    expect(find.textContaining('θ(+X):'), findsOneWidget);
    expect(find.textContaining('Grade(Y/X):'), findsOneWidget);
    expect(find.textContaining('Slope: 1:'), findsOneWidget);
    expect(find.textContaining('Az(+Y, CW):'), findsOneWidget);
    expect(find.textContaining('Bearing:'), findsOneWidget);
    expect(find.textContaining('Midpoint:'), findsOneWidget);
    final distancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(distancePainter.measurementMidpoint, isTrue);
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('L:'));
    expect(clipboardText, contains('ΔX:'));
    expect(clipboardText, contains('Grade(Y/X):'));
    expect(clipboardText, contains('Slope: 1:'));
    expect(clipboardText, contains('Az(+Y, CW):'));
    expect(clipboardText, contains('Bearing:'));
    expect(clipboardText, contains('Midpoint:'));
    expect(find.text('Copied to clipboard'), findsOneWidget);

    engine.snapPositionOverride = Offset.zero;
    await tester.tapAt(const Offset(80, 220));
    await tester.pump();
    engine.snapPositionOverride = const Offset(0, 10);
    await tester.tapAt(const Offset(180, 320));
    await tester.pump();
    expect(find.textContaining('Grade(Y/X): ∞% · Slope: 1:0'), findsOneWidget);
    expect(
      find.textContaining('Az(+Y, CW): 0.00° · Bearing: N'),
      findsOneWidget,
    );
    engine.snapPositionOverride = null;

    engine.countSummary = CadEntityCountSummary(
      entityKind: 'circle',
      layerId: BigInt.one,
      sameKindInLayer: BigInt.from(4),
      sameKindInDocument: BigInt.from(9),
      sameKindLengthInLayer: 100,
      sameKindLengthInDocument: 250,
      sameKindAreaInLayer: 10000,
      sameKindAreaInDocument: 25000,
    );
    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(find.text('Entity properties'), findsOneWidget);
    expect(find.text('CIRCLE'), findsOneWidget);
    expect(find.text('Same type on this layer'), findsOneWidget);
    expect(find.text('Same type in drawing'), findsOneWidget);
    expect(engine.entityCountRequests, [BigInt.one]);
    await tester.drag(
      find.byKey(const ValueKey('property_list')),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle();
    expect(find.text('Total length on this layer'), findsOneWidget);
    expect(find.text('Total length in drawing'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('property_list')),
      const Offset(0, -160),
    );
    await tester.pumpAndSettle();
    expect(find.text('Validated closed area on this layer'), findsOneWidget);
    expect(find.text('Validated closed area in drawing'), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('property_list')),
      const Offset(0, -220),
    );
    await tester.pumpAndSettle();
    expect(find.text('Width (X)'), findsOneWidget);
    expect(find.text('Height (Y)'), findsOneWidget);
    expect(find.text('2.00 cm'), findsWidgets);
    await tester.tap(find.byTooltip('Copy all properties'));
    await tester.pump();
    expect(clipboardText, startsWith('Entity properties\nID: 1'));
    expect(clipboardText, contains('Same type on this layer: 4'));
    expect(clipboardText, contains('Same type in drawing: 9'));
    expect(clipboardText, contains('Total length on this layer: 10.00 cm'));
    expect(clipboardText, contains('Total length in drawing: 25.00 cm'));
    expect(
      clipboardText,
      contains('Validated closed area on this layer: 100.00 cm²'),
    );
    expect(
      clipboardText,
      contains('Validated closed area in drawing: 250.00 cm²'),
    );
    expect(clipboardText, contains('Width (X): 2.00 cm'));

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinate reference'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('set_local_origin')));
    await tester.pumpAndSettle();
    final snapsBeforeLocalOrigin = engine.snapRequests.length;
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeLocalOrigin + 1));
    expect(find.text('Local coordinate origin set'), findsOneWidget);
    await tester.tapAt(const Offset(160, 260));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeLocalOrigin + 2));
    expect(find.textContaining('Local X:'), findsOneWidget);
    final localPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(localPainter.coordinateOrigin2D, isNotNull);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Area'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Centroid: Local X:'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final localRectangleTool = find.text('Axis-aligned rectangle (2 points)');
    await tester.ensureVisible(localRectangleTool);
    await tester.tap(localRectangleTool);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    await tester.tapAt(const Offset(180, 300));
    await tester.pump();
    expect(find.textContaining('Center: Local X:'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Radius / diameter'));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.textContaining('Center: Local X:'), findsOneWidget);
    expect(find.textContaining('Circumference:'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Distance'));
    await tester.pumpAndSettle();
    final snapsBeforeLocalDistance = engine.snapRequests.length;
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    await tester.tapAt(const Offset(180, 300));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeLocalDistance + 2));
    expect(find.textContaining('Midpoint: Local X:'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final stationTool = find.text('Station / offset');
    await tester.ensureVisible(stationTool);
    await tester.tap(stationTool);
    await tester.pumpAndSettle();
    expect(
      find.text('Select a baseline line, polyline, or circular arc'),
      findsOneWidget,
    );
    engine.hitResult = CadHit(
      entityId: BigInt.from(4),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'polyline',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.text('Tap a point to measure from the selected baseline'),
      findsOneWidget,
    );
    var stationPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stationPainter.selectedEntityId, BigInt.from(4));

    final snapsBeforeStation = engine.snapRequests.length;
    engine.snapPositionOverride = const Offset(20, 20);
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeStation + 1));
    expect(find.textContaining('Station: 5.00 cm / 7.00 cm'), findsOneWidget);
    expect(find.textContaining('Remaining: 2.00 cm'), findsOneWidget);
    expect(find.textContaining('Offset(L+): -1.00 cm'), findsOneWidget);
    expect(find.textContaining('Segment: 2'), findsOneWidget);
    expect(find.textContaining('Direction(+X): 0.00°'), findsOneWidget);
    expect(find.textContaining('Foot: Local X:'), findsOneWidget);
    expect(find.textContaining('Point: Local X:'), findsOneWidget);
    stationPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stationPainter.measurementPoints, const [
      Offset(20, 30),
      Offset(20, 20),
    ]);
    expect(stationPainter.selectedEntityId, BigInt.from(4));
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, contains('Station: 5.00 cm / 7.00 cm'));
    expect(clipboardText, contains('Foot: Local X:'));
    expect(clipboardText, contains('Point: Local X:'));

    engine.snapPositionOverride = const Offset(-10, 15);
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(engine.snapRequests, hasLength(snapsBeforeStation + 2));
    expect(find.textContaining('Station: 1.50 cm / 7.00 cm'), findsOneWidget);
    expect(find.textContaining('Offset(L+): 1.00 cm'), findsOneWidget);
    expect(find.textContaining('Segment: 1'), findsOneWidget);
    expect(find.textContaining('Direction(+X): 90.00°'), findsOneWidget);

    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Station:'), findsNothing);
    expect(
      find.text('Tap a point to measure from the selected baseline'),
      findsOneWidget,
    );
    stationPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stationPainter.selectedEntityId, BigInt.from(4));

    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    expect(
      find.text('Select a baseline line, polyline, or circular arc'),
      findsOneWidget,
    );
    stationPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stationPainter.selectedEntityId, isNull);

    engine.hitResult = CadHit(
      entityId: BigInt.one,
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'circle',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.text('Select a valid non-zero line, polyline, or circular arc'),
      findsOneWidget,
    );
    engine.snapPositionOverride = null;

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinate reference'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('use_drawing_origin')),
    );
    await tester.tap(find.byKey(const ValueKey('use_drawing_origin')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Local X:'), findsNothing);
    final resetPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(resetPainter.coordinateOrigin2D, isNull);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(stationTool);
    await tester.tap(stationTool);
    await tester.pumpAndSettle();
    engine.hitResult = CadHit(
      entityId: BigInt.from(11),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'arc',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    engine.snapPositionOverride = Offset(4 * math.sqrt2, 4 * math.sqrt2);
    await tester.tapAt(const Offset(120, 240));
    await tester.pump();
    expect(find.textContaining('Station: 0.79 cm / 1.57 cm'), findsOneWidget);
    expect(find.textContaining('Remaining: 0.79 cm'), findsOneWidget);
    expect(find.textContaining('Offset(L+): 0.20 cm'), findsOneWidget);
    expect(find.textContaining('Distance: 0.20 cm'), findsOneWidget);
    expect(find.textContaining('Arc: 1'), findsOneWidget);
    expect(find.textContaining('Direction(+X): 135.00°'), findsOneWidget);
    final arcStationPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(arcStationPainter.selectedEntityId, BigInt.from(11));
    expect(
      arcStationPainter.measurementPoints.first.dx,
      closeTo(5 * math.sqrt2, 1e-12),
    );
    expect(
      arcStationPainter.measurementPoints.first.dy,
      closeTo(5 * math.sqrt2, 1e-12),
    );
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    engine.snapPositionOverride = null;

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final polarStakeoutTool = find.text('Polar stakeout');
    await tester.ensureVisible(polarStakeoutTool);
    await tester.tap(polarStakeoutTool);
    await tester.pumpAndSettle();
    expect(find.text('Tap the stakeout origin'), findsOneWidget);
    engine.snapPositionOverride = const Offset(10, 20);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(
      find.text('Azimuth: 0° = +Y, increasing clockwise (0–<360°)'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('apply_polar_stakeout')));
    await tester.pump();
    expect(
      find.textContaining('Enter a distance greater than zero'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('polar_stakeout_distance')),
      '2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('polar_stakeout_azimuth')),
      '360',
    );
    await tester.tap(find.byKey(const ValueKey('apply_polar_stakeout')));
    await tester.pump();
    expect(find.textContaining('less than 360°'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('polar_stakeout_azimuth')),
      '90',
    );
    await tester.tap(find.byKey(const ValueKey('apply_polar_stakeout')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Distance: 2.00 cm'), findsOneWidget);
    expect(find.textContaining('Azimuth: 90.00°'), findsOneWidget);
    expect(find.textContaining('ΔX: 2.00 cm'), findsOneWidget);
    expect(find.textContaining('ΔY: 0.00 cm'), findsOneWidget);
    expect(find.textContaining('Origin: X: 1.00 cm'), findsOneWidget);
    expect(find.textContaining('Target: X: 3.00 cm'), findsOneWidget);
    var polarPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(polarPainter.measurementPoints, const [
      Offset(10, 20),
      Offset(30, 20),
    ]);
    expect(polarPainter.measurementIntersectionPoints, const [Offset(30, 20)]);

    await tester.tap(find.byTooltip('Enter another distance and azimuth'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('polar_stakeout_distance')),
      '1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('polar_stakeout_azimuth')),
      '180',
    );
    await tester.tap(find.byKey(const ValueKey('apply_polar_stakeout')));
    await tester.pumpAndSettle();
    polarPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(polarPainter.measurementPoints.first, const Offset(10, 20));
    expect(polarPainter.measurementPoints.last, const Offset(10, 10));
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    polarPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(polarPainter.measurementPoints, const [Offset(10, 20)]);
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    expect(find.text('Tap the stakeout origin'), findsOneWidget);
    polarPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(polarPainter.measurementPoints, isEmpty);
    engine.snapPositionOverride = null;

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final twoDistanceTool = find.byKey(
      const ValueKey('locate_two_distances_tool'),
    );
    await tester.ensureVisible(twoDistanceTool);
    await tester.tap(twoDistanceTool);
    await tester.pumpAndSettle();
    expect(find.text('Tap reference point A'), findsOneWidget);
    engine.snapPositionOverride = Offset.zero;
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(find.text('Tap reference point B'), findsOneWidget);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pump();
    expect(
      find.text('Reference points A and B must be different'),
      findsOneWidget,
    );
    engine.snapPositionOverride = const Offset(60, 0);
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(find.text('Two-distance location'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('apply_two_distance_location')));
    await tester.pump();
    expect(find.text('Enter two distances greater than zero'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('two_distance_first')),
      '5',
    );
    await tester.enterText(
      find.byKey(const ValueKey('two_distance_second')),
      '5',
    );
    await tester.tap(find.byKey(const ValueKey('apply_two_distance_location')));
    await tester.pumpAndSettle();
    expect(find.textContaining('AB: 6.00 cm'), findsOneWidget);
    expect(find.textContaining('dA: 5.00 cm · dB: 5.00 cm'), findsOneWidget);
    expect(find.textContaining('Left of A→B: X: 3.00 cm'), findsOneWidget);
    expect(find.textContaining('Y: 4.00 cm'), findsOneWidget);
    expect(find.textContaining('Right of A→B: X: 3.00 cm'), findsOneWidget);
    expect(find.textContaining('Y: -4.00 cm'), findsOneWidget);
    var twoDistancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(twoDistancePainter.measurementPoints, const [
      Offset.zero,
      Offset(60, 0),
    ]);
    expect(twoDistancePainter.measurementIntersectionPoints, hasLength(2));
    expect(
      twoDistancePainter.measurementIntersectionPoints.first.dx,
      closeTo(30, 1e-10),
    );
    expect(
      twoDistancePainter.measurementIntersectionPoints.first.dy,
      closeTo(40, 1e-10),
    );
    expect(
      twoDistancePainter.measurementIntersectionPoints.last.dx,
      closeTo(30, 1e-10),
    );
    expect(
      twoDistancePainter.measurementIntersectionPoints.last.dy,
      closeTo(-40, 1e-10),
    );

    await tester.tap(find.byTooltip('Enter another distance pair'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('two_distance_first')),
      '3',
    );
    await tester.enterText(
      find.byKey(const ValueKey('two_distance_second')),
      '3',
    );
    await tester.tap(find.byKey(const ValueKey('apply_two_distance_location')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tangent point: X: 3.00 cm'), findsOneWidget);
    twoDistancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(twoDistancePainter.measurementIntersectionPoints, const [
      Offset(30, 0),
    ]);
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    twoDistancePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(twoDistancePainter.measurementPoints, const [
      Offset.zero,
      Offset(60, 0),
    ]);
    expect(twoDistancePainter.measurementIntersectionPoints, isEmpty);
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    expect(find.text('Tap reference point A'), findsOneWidget);
    engine.snapPositionOverride = null;

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final stationOffsetLocateTool = find.text('Locate by station / offset');
    await tester.ensureVisible(stationOffsetLocateTool);
    await tester.tap(stationOffsetLocateTool);
    await tester.pumpAndSettle();
    expect(
      find.text('Select the stakeout baseline line, polyline, or circular arc'),
      findsOneWidget,
    );
    engine.hitResult = CadHit(
      entityId: BigInt.from(4),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'polyline',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(find.text('Locate station / offset'), findsOneWidget);
    expect(find.text('Baseline total: 7.00 cm'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('apply_station_offset_location')),
    );
    await tester.pump();
    expect(
      find.text('Enter a non-negative station and finite offset'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_station')),
      '8',
    );
    await tester.tap(
      find.byKey(const ValueKey('apply_station_offset_location')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Station must be between 0 and 7.00 cm'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_station')),
      '4',
    );
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_offset')),
      '0.5',
    );
    await tester.tap(
      find.byKey(const ValueKey('apply_station_offset_location')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Station: 4.00 cm / 7.00 cm'), findsOneWidget);
    expect(find.textContaining('Remaining: 3.00 cm'), findsOneWidget);
    expect(find.textContaining('Offset(L+): 0.50 cm'), findsOneWidget);
    expect(find.textContaining('Segment: 2'), findsOneWidget);
    expect(find.textContaining('Direction(+X): 0.00°'), findsOneWidget);
    expect(find.textContaining('Baseline point: X: 1.00 cm'), findsOneWidget);
    expect(find.textContaining('Stakeout point: X: 1.00 cm'), findsOneWidget);
    var stakeoutPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stakeoutPainter.selectedEntityId, BigInt.from(4));
    expect(stakeoutPainter.measurementPoints, const [
      Offset(10, 30),
      Offset(10, 35),
    ]);
    expect(stakeoutPainter.measurementIntersectionPoints, const [
      Offset(10, 35),
    ]);
    final stakeoutSize = tester.getSize(cadScenePaintFinder());
    final stakeoutTransform = CadViewTransform.forScene(
      document,
      stakeoutSize,
      stakeoutPainter.zoom,
      stakeoutPainter.pan,
    );
    final stakeoutScreen = stakeoutTransform.worldToScreen(
      const Offset(10, 35),
    );
    expect(stakeoutScreen.dx, closeTo(stakeoutSize.width / 2, 1e-9));
    expect(stakeoutScreen.dy, closeTo(stakeoutSize.height / 2, 1e-9));
    await tester.tap(find.byTooltip('Enter another station and offset'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_station')),
      '1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_offset')),
      '-0.5',
    );
    await tester.tap(
      find.byKey(const ValueKey('apply_station_offset_location')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Station: 1.00 cm / 7.00 cm'), findsOneWidget);
    expect(find.textContaining('Offset(L+): -0.50 cm'), findsOneWidget);
    expect(find.textContaining('Segment: 1'), findsOneWidget);
    stakeoutPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stakeoutPainter.measurementPoints, const [
      Offset(0, 10),
      Offset(5, 10),
    ]);
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Stakeout point:'), findsNothing);
    expect(
      find.text('Baseline selected · enter station and offset'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    expect(
      find.text('Select the stakeout baseline line, polyline, or circular arc'),
      findsOneWidget,
    );
    engine.hitResult = CadHit(
      entityId: BigInt.from(11),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'arc',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(find.text('Baseline total: 1.57 cm'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_station')),
      '0.7853981634',
    );
    await tester.enterText(
      find.byKey(const ValueKey('station_offset_offset')),
      '0.2',
    );
    await tester.tap(
      find.byKey(const ValueKey('apply_station_offset_location')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Station: 0.79 cm / 1.57 cm'), findsOneWidget);
    expect(find.textContaining('Offset(L+): 0.20 cm'), findsOneWidget);
    expect(find.textContaining('Arc: 1'), findsOneWidget);
    expect(find.textContaining('Direction(+X): 135.00°'), findsOneWidget);
    stakeoutPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(stakeoutPainter.selectedEntityId, BigInt.from(11));
    expect(
      stakeoutPainter.measurementPoints.first.dx,
      closeTo(5 * math.sqrt2, 1e-8),
    );
    expect(
      stakeoutPainter.measurementPoints.first.dy,
      closeTo(5 * math.sqrt2, 1e-8),
    );
    expect(
      stakeoutPainter.measurementPoints.last.dx,
      closeTo(4 * math.sqrt2, 1e-8),
    );
    expect(
      stakeoutPainter.measurementPoints.last.dy,
      closeTo(4 * math.sqrt2, 1e-8),
    );
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final divisionTool = find.text('Equal divisions');
    await tester.ensureVisible(divisionTool);
    await tester.tap(divisionTool);
    await tester.pumpAndSettle();
    expect(
      find.text('Select a line, polyline, or circular arc to divide'),
      findsOneWidget,
    );
    engine.hitResult = CadHit(
      entityId: BigInt.from(4),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'polyline',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    expect(find.text('Equal divisions'), findsOneWidget);
    expect(find.text('Whole number from 2 to 200'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('apply_polyline_division')));
    await tester.pump();
    expect(find.text('Enter a whole number from 2 to 200'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('polyline_division_count')),
      '7',
    );
    await tester.tap(find.byKey(const ValueKey('apply_polyline_division')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Segments: 7 · Markers: 8'), findsOneWidget);
    expect(
      find.textContaining('Total: 7.00 cm · Equal interval: 1.00 cm'),
      findsOneWidget,
    );
    var divisionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(divisionPainter.measurementPoints, isEmpty);
    expect(divisionPainter.measurementIntersectionPoints, const [
      Offset(0, 0),
      Offset(0, 10),
      Offset(0, 20),
      Offset(0, 30),
      Offset(10, 30),
      Offset(20, 30),
      Offset(30, 30),
      Offset(40, 30),
    ]);
    expect(divisionPainter.selectedEntityId, BigInt.from(4));
    await tester.tap(find.byTooltip('View division stakeout table'));
    await tester.pumpAndSettle();
    expect(find.text('Stakeout table · 8 points'), findsOneWidget);
    expect(
      find.textContaining('Total: 7.00 cm · Interval: 1.00 cm'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Station: 0.00 cm · X: 0.00 cm · Y: 0.00 cm\n'
        'Tangent: 0.00° · N · Segment 1',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('copy_division_stakeout_csv')));
    await tester.pumpAndSettle();
    expect(
      clipboardText,
      startsWith('Point,Station,X,Y,Unit,TangentAzimuth_deg,TangentBearing,'),
    );
    expect(
      clipboardText,
      contains('P8,7.00,4.00,3.00,cm,90.00,E,segment_2,,,Drawing'),
    );
    await tester.tap(find.byTooltip('Enter another segment count'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('polyline_division_count')),
      '5',
    );
    await tester.tap(find.byKey(const ValueKey('apply_polyline_division')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Segments: 5 · Markers: 6'), findsOneWidget);
    expect(find.textContaining('Equal interval: 1.40 cm'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    expect(find.textContaining('Segments:'), findsNothing);
    expect(
      find.text('Baseline selected · Enter the segment count'),
      findsOneWidget,
    );
    divisionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(divisionPainter.measurementIntersectionPoints, isEmpty);
    expect(divisionPainter.selectedEntityId, BigInt.from(4));
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    expect(
      find.text('Select a line, polyline, or circular arc to divide'),
      findsOneWidget,
    );
    divisionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(divisionPainter.selectedEntityId, isNull);

    engine.hitResult = CadHit(
      entityId: BigInt.from(11),
      layerId: BigInt.one,
      distance: 0,
      entityKind: 'arc',
    );
    await tester.tapAt(tester.getCenter(cadScenePaintFinder()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('polyline_division_count')),
      '4',
    );
    await tester.tap(find.byKey(const ValueKey('apply_polyline_division')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Segments: 4 · Markers: 5'), findsOneWidget);
    expect(
      find.textContaining('Total: 1.57 cm · Equal interval: 0.39 cm'),
      findsOneWidget,
    );
    divisionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(divisionPainter.selectedEntityId, BigInt.from(11));
    expect(divisionPainter.measurementIntersectionPoints, hasLength(5));
    expect(
      divisionPainter.measurementIntersectionPoints.first,
      const Offset(10, 0),
    );
    expect(
      divisionPainter.measurementIntersectionPoints[2].dx,
      closeTo(5 * math.sqrt2, 1e-8),
    );
    expect(
      divisionPainter.measurementIntersectionPoints[2].dy,
      closeTo(5 * math.sqrt2, 1e-8),
    );
    expect(
      divisionPainter.measurementIntersectionPoints.last.dx,
      closeTo(0, 1e-8),
    );
    expect(
      divisionPainter.measurementIntersectionPoints.last.dy,
      closeTo(10, 1e-8),
    );
    await tester.tap(find.byTooltip('View division stakeout table'));
    await tester.pumpAndSettle();
    expect(find.text('Stakeout table · 5 points'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('P5'),
      180,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('division_stakeout_table_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Deflection from start tangent: 45.00° · Long chord: 1.41 cm',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('copy_division_stakeout_csv')));
    await tester.pumpAndSettle();
    expect(
      clipboardText,
      contains('P5,1.57,0.00,1.00,cm,270.00,W,arc,45.00,1.41,Drawing'),
    );
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    final coordinateCollectionTool = find.byKey(
      const ValueKey('collect_coordinates_tool'),
    );
    await tester.ensureVisible(coordinateCollectionTool);
    await tester.tap(coordinateCollectionTool);
    await tester.pumpAndSettle();
    expect(
      find.text('Tap points to collect coordinates · 0/200'),
      findsOneWidget,
    );
    engine.snapPositionOverride = Offset.zero;
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(find.textContaining('Collected: 1/200'), findsOneWidget);
    expect(find.textContaining('Latest P1: X: 0.00 cm'), findsOneWidget);
    engine.snapPositionOverride = const Offset(10, 20);
    await tester.tapAt(const Offset(140, 260));
    await tester.pump();
    expect(find.textContaining('Collected: 2/200'), findsOneWidget);
    expect(find.textContaining('Latest P2: X: 1.00 cm'), findsOneWidget);
    var collectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(collectionPainter.measurementPoints, isEmpty);
    expect(collectionPainter.indexedMeasurementPoints, const [
      Offset.zero,
      Offset(10, 20),
    ]);
    await tester.tapAt(const Offset(180, 300));
    await tester.pump();
    expect(
      find.text('This coordinate is already in the table'),
      findsOneWidget,
    );
    collectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(collectionPainter.indexedMeasurementPoints, hasLength(2));

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('View coordinate table'));
    await tester.pumpAndSettle();
    expect(find.text('Coordinate table · 2'), findsOneWidget);
    expect(find.text('P1'), findsOneWidget);
    expect(find.text('P2'), findsOneWidget);
    expect(find.text('X: 0.00 cm · Y: 0.00 cm'), findsOneWidget);
    expect(find.text('X: 1.00 cm · Y: 2.00 cm'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('view_traverse_report')));
    await tester.pumpAndSettle();
    expect(find.text('Open traverse · Legs: 1'), findsOneWidget);
    expect(
      find.text(
        'Total: 2.24 cm\n'
        'P1→P2 straight distance: 2.24 cm · '
        'Azimuth: 26.57° · Bearing: N 26.57° E',
      ),
      findsOneWidget,
    );
    expect(find.text('P1 → P2'), findsOneWidget);
    expect(
      find.text('Length: 2.24 cm · Azimuth: 26.57° · Bearing: N 26.57° E'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('check_known_endpoint')));
    await tester.pumpAndSettle();
    expect(find.text('Known endpoint closure'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('apply_known_endpoint')));
    await tester.pump();
    expect(find.text('Enter finite numeric X and Y values'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('known_endpoint_x')),
      '1.3',
    );
    await tester.enterText(
      find.byKey(const ValueKey('known_endpoint_y')),
      '1.6',
    );
    await tester.tap(find.byKey(const ValueKey('apply_known_endpoint')));
    await tester.pumpAndSettle();
    expect(find.text('Observed endpoint P2'), findsOneWidget);
    expect(find.text('X: 1.00 cm · Y: 2.00 cm'), findsOneWidget);
    expect(find.text('Known endpoint'), findsOneWidget);
    expect(find.text('X: 1.30 cm · Y: 1.60 cm'), findsOneWidget);
    expect(find.text('Correction (observed → known)'), findsOneWidget);
    expect(find.text('ΔX: 0.30 cm · ΔY: -0.40 cm'), findsOneWidget);
    expect(find.text('Linear misclosure'), findsOneWidget);
    expect(find.text('0.50 cm'), findsOneWidget);
    final closurePropertyScroll = find
        .descendant(
          of: find.byKey(const ValueKey('property_list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Relative precision'),
      120,
      scrollable: closurePropertyScroll,
    );
    expect(find.text('Relative precision'), findsOneWidget);
    expect(find.text('1:4.47'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Correction direction'),
      120,
      scrollable: closurePropertyScroll,
    );
    expect(find.text('Correction direction'), findsOneWidget);
    expect(find.text('Azimuth: 143.13° · Bearing: S 36.87° E'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Measured traverse length'),
      120,
      scrollable: closurePropertyScroll,
    );
    expect(find.text('Measured traverse length'), findsOneWidget);
    expect(find.text('2.24 cm'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('property_sheet_action')));
    await tester.pumpAndSettle();
    expect(find.text('Bowditch adjustment · 2 points'), findsOneWidget);
    expect(
      find.text(
        'Distributes ΔX/ΔY by observed leg length; '
        'the source drawing is unchanged.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Cumulative: 0.00 cm\n'
        'Observed: X: 0.00 cm · Y: 0.00 cm\n'
        'Correction: ΔX 0.00 cm · ΔY 0.00 cm\n'
        'Adjusted: X: 0.00 cm · Y: 0.00 cm',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Cumulative: 2.24 cm\n'
        'Observed: X: 1.00 cm · Y: 2.00 cm\n'
        'Correction: ΔX 0.30 cm · ΔY -0.40 cm\n'
        'Adjusted: X: 1.30 cm · Y: 1.60 cm',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('copy_bowditch_csv')));
    await tester.pumpAndSettle();
    expect(
      clipboardText,
      'Point,CumulativeLength,ObservedX,ObservedY,CorrectionX,CorrectionY,'
      'AdjustedX,AdjustedY,Unit,Reference,Method\n'
      'P1,0.00,0.00,0.00,0.00,0.00,0.00,0.00,cm,Drawing,Bowditch\n'
      'P2,2.24,1.00,2.00,0.30,-0.40,1.30,1.60,cm,Drawing,Bowditch',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('View coordinate table'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('view_traverse_report')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy_traverse_csv')));
    await tester.pumpAndSettle();
    expect(
      clipboardText,
      'Leg,From,To,Length,Unit,Azimuth_deg,Bearing,Reference\n'
      'L1,P1,P2,2.24,cm,26.57,N 26.57° E,Drawing',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('View coordinate table'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('copy_coordinate_csv')));
    await tester.pumpAndSettle();
    expect(
      clipboardText,
      'Point,X,Y,Unit,Reference\n'
      'P1,0.00,0.00,cm,Drawing\n'
      'P2,1.00,2.00,cm,Drawing',
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Undo last point'));
    await tester.pump();
    collectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(collectionPainter.indexedMeasurementPoints, const [Offset.zero]);
    expect(find.textContaining('Collected: 1/200'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();
    collectionPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(collectionPainter.indexedMeasurementPoints, isEmpty);
    expect(
      find.text('Tap points to collect coordinates · 0/200'),
      findsOneWidget,
    );

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinate reference'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('set_local_axis')));
    await tester.tap(find.byKey(const ValueKey('set_local_axis')));
    await tester.pumpAndSettle();
    expect(find.text('Select the local coordinate origin'), findsOneWidget);
    final snapsBeforeLocalAxis = engine.snapRequests.length;
    engine.snapPositionOverride = const Offset(20, 30);
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(find.text('Select a point on local +X'), findsOneWidget);
    await tester.tapAt(const Offset(120, 240));
    await tester.pump();
    expect(
      find.text('The +X direction point must differ from the origin'),
      findsOneWidget,
    );
    expect(find.text('Select a point on local +X'), findsOneWidget);
    engine.snapPositionOverride = const Offset(20, 40);
    await tester.tapAt(const Offset(120, 240));
    await tester.pump();
    expect(find.text('Local coordinate axes set'), findsOneWidget);
    expect(engine.snapRequests, hasLength(snapsBeforeLocalAxis + 3));

    engine.snapPositionOverride = const Offset(10, 40);
    await tester.tapAt(const Offset(160, 260));
    await tester.pump();
    expect(find.text('Local X: 1.00 cm · Y: 1.00 cm'), findsOneWidget);
    final rotatedFramePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(rotatedFramePainter.coordinateOrigin2D, const Offset(20, 30));
    expect(rotatedFramePainter.coordinateXAxis2D, const Offset(0, 1));
    await tester.tap(find.byTooltip('Copy measurement'));
    await tester.pump();
    expect(clipboardText, 'Local X: 1.00 cm · Y: 1.00 cm');

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Arc through 3 points'));
    await tester.tap(find.text('Arc through 3 points'));
    await tester.pumpAndSettle();
    engine.snapPositionOverride = const Offset(20, 30);
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    engine.snapPositionOverride = const Offset(30, 40);
    await tester.tapAt(const Offset(140, 240));
    await tester.pump();
    engine.snapPositionOverride = const Offset(20, 50);
    await tester.tapAt(const Offset(180, 260));
    await tester.pump();
    expect(find.textContaining('Sagitta: 1.00 cm'), findsOneWidget);
    expect(
      find.textContaining('Chord azimuth (+Y, CW): 90.00°'),
      findsOneWidget,
    );
    expect(find.textContaining('Chord bearing: E'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(coordinateCollectionTool);
    await tester.tap(coordinateCollectionTool);
    await tester.pumpAndSettle();
    engine.snapPositionOverride = const Offset(10, 40);
    await tester.tapAt(const Offset(160, 260));
    await tester.pump();
    expect(
      find.textContaining('Latest P1: Local X: 1.00 cm · Y: 1.00 cm'),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('View coordinate table'));
    await tester.pumpAndSettle();
    expect(find.text('Coordinate table · 1'), findsOneWidget);
    expect(find.textContaining('Local axes · Origin'), findsOneWidget);
    expect(find.text('X: 1.00 cm · Y: 1.00 cm'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy_coordinate_csv')));
    await tester.pumpAndSettle();
    expect(clipboardText, 'Point,X,Y,Unit,Reference\nP1,1.00,1.00,cm,Local');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear measurement'));
    await tester.pump();

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinate reference'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('locate_coordinate')));
    await tester.tap(find.byKey(const ValueKey('locate_coordinate')));
    await tester.pumpAndSettle();
    expect(find.text('Locate coordinate'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('apply_coordinate_location')));
    await tester.pump();
    expect(find.text('Enter finite numeric X and Y values'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('coordinate_location_x')),
      '2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('coordinate_location_y')),
      '-1',
    );
    await tester.tap(find.byKey(const ValueKey('apply_coordinate_location')));
    await tester.pumpAndSettle();
    expect(find.text('Coordinate point located'), findsOneWidget);
    expect(find.text('Local X: 2.00 cm · Y: -1.00 cm'), findsOneWidget);
    final locatedPainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(locatedPainter.measurementPoints, const [Offset(30, 50)]);
    final locatedSize = tester.getSize(cadScenePaintFinder());
    final locatedTransform = CadViewTransform.forScene(
      document,
      locatedSize,
      locatedPainter.zoom,
      locatedPainter.pan,
    );
    final locatedScreen = locatedTransform.worldToScreen(const Offset(30, 50));
    expect(locatedScreen.dx, closeTo(locatedSize.width / 2, 1e-9));
    expect(locatedScreen.dy, closeTo(locatedSize.height / 2, 1e-9));

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Distance'));
    await tester.pumpAndSettle();
    engine.snapPositionOverride = const Offset(20, 30);
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    engine.snapPositionOverride = const Offset(20, 50);
    await tester.tapAt(const Offset(160, 260));
    await tester.pump();
    expect(
      find.textContaining('Midpoint: Local X: 1.00 cm · Y: 0.00 cm'),
      findsOneWidget,
    );

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coordinate reference'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('use_drawing_origin')),
    );
    await tester.tap(find.byKey(const ValueKey('use_drawing_origin')));
    await tester.pumpAndSettle();
    final resetRotatedFramePainter =
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    expect(resetRotatedFramePainter.coordinateOrigin2D, isNull);
    expect(resetRotatedFramePainter.coordinateXAxis2D, isNull);
    engine.snapPositionOverride = null;

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scale calibration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calibrate_scale')));
    await tester.pumpAndSettle();
    final snapsBeforeCalibration = engine.snapRequests.length;
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    expect(find.text('Select the second calibration point'), findsOneWidget);
    await tester.tapAt(const Offset(160, 260));
    await tester.pumpAndSettle();
    expect(engine.snapRequests, hasLength(snapsBeforeCalibration + 2));
    expect(find.text('Enter known length'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('known_calibration_length')),
      '25.4',
    );
    await tester.tap(find.byKey(const ValueKey('calibration_unit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mm').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('apply_scale_calibration')));
    await tester.pump();
    expect(find.textContaining('Scale calibrated'), findsOneWidget);
    expect(find.textContaining('L: 25.40 mm'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Calibrated: 1 DU ='), findsOneWidget);
    await tester.tap(find.text('Scale calibration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset_scale_calibration')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2D scene · mm'), findsOneWidget);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scale calibration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calibrate_scale')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(100, 220));
    await tester.pump();
    await tester.tapAt(const Offset(160, 260));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Distance'));
    await tester.pumpAndSettle();
    CadScenePainter currentPainter() =>
        tester.widget<CustomPaint>(cadScenePaintFinder()).painter
            as CadScenePainter;
    final pickPosition = tester.getCenter(cadScenePaintFinder());
    engine.snapPositionOverride = const Offset(10, 20);
    await tester.tapAt(pickPosition);
    await tester.pump();
    final ordinaryTolerance = engine.snapRequests.last.$3;
    final hold = await tester.startGesture(pickPosition);
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const ValueKey('measurement_precision_loupe')),
      findsOneWidget,
    );
    expect(currentPainter().measurementPoints, const [Offset(10, 20)]);
    expect(engine.snapRequests.last.$3, closeTo(ordinaryTolerance / 3, 1e-9));
    engine.snapPositionOverride = const Offset(30, 40);
    await hold.moveBy(const Offset(8, 5));
    await tester.pump();
    expect(currentPainter().measurementPoints, hasLength(1));
    await hold.up();
    await tester.pump();
    expect(find.byType(RawMagnifier), findsNothing);
    expect(currentPainter().measurementPoints, const [
      Offset(10, 20),
      Offset(30, 40),
    ]);

    // Adding another finger cancels the pick without committing a third point.
    final cancelledHold = await tester.startGesture(pickPosition, pointer: 21);
    await tester.pump(const Duration(milliseconds: 600));
    final secondFinger = await tester.startGesture(
      pickPosition + const Offset(40, 0),
      pointer: 22,
    );
    await tester.pump();
    expect(find.byType(RawMagnifier), findsNothing);
    await secondFinger.up();
    await cancelledHold.up();
    await tester.pump();
    expect(currentPainter().measurementPoints, const [
      Offset(10, 20),
      Offset(30, 40),
    ]);

    // Without an object snap, releasing retains the exact free point and
    // must not retry with the wider ordinary-tap aperture.
    engine.snapEnabled = false;
    final freeHold = await tester.startGesture(pickPosition);
    await tester.pump(const Duration(milliseconds: 600));
    await freeHold.moveBy(const Offset(7, 3));
    await tester.pump();
    final beforeFreeRelease = engine.snapRequests.length;
    final freePainter = currentPainter();
    final freeWorld =
        CadViewTransform.forScene(
          document,
          tester.getSize(cadScenePaintFinder()),
          freePainter.zoom,
          freePainter.pan,
        ).screenToWorld(
          pickPosition +
              const Offset(7, 3) -
              tester.getTopLeft(cadScenePaintFinder()),
        );
    await freeHold.up();
    await tester.pump();
    expect(currentPainter().measurementPoints, [freeWorld]);
    expect(engine.snapRequests, hasLength(beforeFreeRelease + 1));
    expect(engine.snapRequests.last.$3, closeTo(ordinaryTolerance / 3, 1e-9));
    engine.snapEnabled = true;

    // Entity commands magnify the touched geometry without snapping to its center.
    await tester.tap(find.text('Measure'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Radius / diameter'));
    await tester.pumpAndSettle();
    final requestsBeforeEntityHold = engine.snapRequests.length;
    final entityHold = await tester.startGesture(pickPosition);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RawMagnifier), findsOneWidget);
    await entityHold.up();
    await tester.pump();
    expect(engine.snapRequests, hasLength(requestsBeforeEntityHold));
    expect(tester.takeException(), isNull);
  });
}

class _InMemoryRecentFilesStore extends RecentFilesStore {
  const _InMemoryRecentFilesStore(this.entries);

  final List<RecentFileEntry> entries;

  @override
  Future<List<RecentFileEntry>> load() async => entries;
}

class _ImageSavePicker extends FilePickerPlatform {
  Uri? result;
  Completer<Uri?>? pending;
  Object? error;
  int calls = 0;
  String? name;
  String? mime;
  Uint8List? bytes;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    name = fileName;
    mime = mimeType;
    this.bytes = bytes;
    if (error != null) throw error!;
    if (pending != null) return pending!.future;
    return result;
  }
}

class _FakeCadEngine implements CadEngine {
  final List<bool> backgroundStates = [];
  final List<(double, double, double)> snapRequests = [];
  final List<(double, double, double)> intersectionSnapRequests = [];
  Offset? snapPositionOverride;
  String snapKind = 'intersection';
  bool snapEnabled = true;
  final List<Map<BigInt, bool>> visibilityBatches = [];
  final List<BigInt> entityCountRequests = [];
  CadHit? hitResult;
  CadEntityCountSummary? countSummary;
  CadDocumentModel? viewportDocument;

  @override
  Future<List<CadTextAnnotation>> deleteAnnotation(
    BigInt sessionId,
    String annotationId,
  ) async => const [];

  @override
  Future<List<CadTextAnnotation>> addTextAnnotation3D(
    BigInt sessionId,
    String value,
    double x,
    double y,
    double z,
    BigInt? meshId,
  ) async => const [];

  @override
  Future<List<CadTextAnnotation>> addTextAnnotation(
    BigInt sessionId,
    String value,
    double x,
    double y,
    BigInt? entityId,
  ) async => const [];

  @override
  Future<String> exportAnnotations(BigInt sessionId) async =>
      '{"schema_version":1,"source_fingerprint":"","annotations":[]}';

  @override
  Future<List<CadFormatDescriptor>> supportedFormats() async => const [
    CadFormatDescriptor(
      id: 'dxf',
      displayName: 'AutoCAD DXF',
      extensions: ['dxf'],
      sceneKind: 'two_d',
      supportLevel: 'production',
      available: true,
      canMeasure: true,
    ),
    CadFormatDescriptor(
      id: 'dwg',
      displayName: 'AutoCAD DWG',
      extensions: ['dwg'],
      sceneKind: 'two_d',
      supportLevel: 'beta',
      available: true,
      canMeasure: true,
    ),
  ];

  @override
  Future<OpenedCadDocument> openDocument(
    String path, {
    void Function(CadOpenEvent event)? onEvent,
  }) => throw UnimplementedError();

  @override
  void cancelCurrentOpen() {}

  @override
  void setApplicationBackgrounded(bool backgrounded) {
    backgroundStates.add(backgrounded);
  }

  @override
  Future<void> closeDocument(BigInt sessionId) async {}

  @override
  Future<CadDocumentModel> setVisibility(
    BigInt sessionId,
    BigInt itemId,
    bool visible,
  ) => setVisibilities(sessionId, {itemId: visible});

  @override
  Future<CadDocumentModel> setVisibilities(
    BigInt sessionId,
    Map<BigInt, bool> changes,
  ) async {
    visibilityBatches.add(Map<BigInt, bool>.of(changes));
    final current = viewportDocument;
    if (current == null) throw StateError('no viewport document');
    final scene = Map<String, dynamic>.from(current.scene);
    scene['layers'] = (current.scene['layers'] as List<dynamic>)
        .map((value) {
          final layer = Map<String, dynamic>.from(
            value as Map<String, dynamic>,
          );
          final id = BigInt.from(layer['id'] as int);
          if (changes.containsKey(id)) layer['visible'] = changes[id];
          return layer;
        })
        .toList(growable: false);
    viewportDocument = CadDocumentModel(
      format: current.format,
      displayName: current.displayName,
      units: current.units,
      sceneKind: current.sceneKind,
      scene: scene,
      diagnostics: current.diagnostics,
    );
    return viewportDocument!;
  }

  @override
  Future<CadDocumentModel> loadViewport(
    BigInt sessionId,
    Rect worldBounds,
  ) async => viewportDocument ?? (throw StateError('no viewport document'));

  @override
  Future<CadHit?> hitTest(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async => hitResult;

  @override
  Future<CadSnap?> snap(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async {
    snapRequests.add((x, y, tolerance));
    if (!snapEnabled) return null;
    return CadSnap(
      entityId: BigInt.one,
      position: snapPositionOverride ?? Offset(x, y),
      kind: snapKind,
      distance: 0,
    );
  }

  @override
  Future<CadSnap?> snapIntersection(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async {
    intersectionSnapRequests.add((x, y, tolerance));
    if (snapKind != 'intersection') return null;
    return CadSnap(
      entityId: BigInt.one,
      position: snapPositionOverride ?? Offset(x, y),
      kind: 'intersection',
      distance: 0,
    );
  }

  @override
  CadEntityCountSummary? entityCountSummary(BigInt sessionId, BigInt entityId) {
    entityCountRequests.add(entityId);
    return countSummary;
  }

  @override
  double measureDistance(double x1, double y1, double x2, double y2) =>
      (Offset(x2, y2) - Offset(x1, y1)).distance;

  @override
  double measurePath(List<Offset> points, {bool closed = false}) =>
      polylineLength2D(points, closed: closed);

  @override
  double measureAngle(Offset vertex, Offset first, Offset second) =>
      angleDegrees2D(vertex, first, second);

  @override
  double? measureArea(List<Offset> points) => simplePolygonArea2D(points);

  @override
  double measureDistance3D(
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
  ) => math.sqrt(
    math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2) + math.pow(z2 - z1, 2),
  );
}
