import 'package:cad_view/app/cad_view_app.dart';
import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_viewer_page.dart';
import 'package:cad_view/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  testWidgets('language can be changed from system default in settings', (
    tester,
  ) async {
    await tester.pumpWidget(CadViewApp(engine: _FakeCadEngine()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simplified Chinese'));
    await tester.pumpAndSettle();

    expect(find.text('打开图纸'), findsOneWidget);
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

      await tester.tap(find.text('Annotate'));
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byType(CustomPaint).first));
      await tester.pumpAndSettle();
      expect(find.text('Add annotation'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Add annotation'), findsNothing);
    },
  );
}

class _FakeCadEngine implements CadEngine {
  final List<bool> backgroundStates = [];

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
  ) => throw UnimplementedError();

  @override
  Future<CadDocumentModel> loadViewport(BigInt sessionId, Rect worldBounds) =>
      throw UnimplementedError();

  @override
  Future<CadHit?> hitTest(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async => null;

  @override
  double measureDistance(double x1, double y1, double x2, double y2) => 0;

  @override
  double measureDistance3D(
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
  ) => 0;
}
