import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/core/image_export.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:cad_view/features/viewer/pdf_document_viewport.dart';
import 'package:cad_view/l10n/app_localizations.dart';
import 'package:cad_view/src/rust/api/document.dart' as native;
import 'package:cad_view/src/rust/frb_generated.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/multilingual_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'images': <String, String>{},
  };
  binding.reportData = report;

  testWidgets('mobile asset fonts render offline without Ahem replacement', (
    tester,
  ) async {
    await loadCadFontMetrics();
    for (final family in [cadDefaultFontFamily, 'CADView Noto CJK']) {
      expect(await prepareCadTextFontMetrics({'font_family': family}), isTrue);
    }
    for (final asset in cadFontAssets.values) {
      expect((await rootBundle.load(asset)).lengthInBytes, greaterThan(1000));
    }
    for (final group in {
      'base': multilingualSamples,
      'extended': extendedMultilingualSamples,
    }.entries) {
      final prefix = group.key == 'base' ? '' : 'extended-';
      final rasters = <String, Uint8List>{};
      final key = GlobalKey();
      for (final entry in <String, String?>{
        'default': null,
        'missing': 'Missing source CAD font',
        'bundled': cadDefaultFontFamily,
        'source': 'CADView Noto CJK',
      }.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: OverflowBox(
                minWidth: 900,
                maxWidth: 900,
                minHeight: 1100,
                maxHeight: 1100,
                child: RepaintBoundary(
                  key: key,
                  child: CustomPaint(
                    size: const Size(900, 1100),
                    painter: CadScenePainter(
                      document: multilingualCadDocument(
                        fontFamily: entry.value,
                        samples: group.value,
                      ),
                      zoom: 1,
                      pan: Offset.zero,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        rasters[entry.key] = pixels!.buffer.asUint8List();
        _expectVisibleRows(rasters[entry.key]!, group.value.length);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        (report['images'] as Map<String, String>)['$prefix${entry.key}'] =
            base64Encode(png!.buffer.asUint8List());
        image.dispose();
      }
      expect(_sameRaster(rasters['default']!, rasters['bundled']!), isTrue);
      expect(_sameRaster(rasters['missing']!, rasters['bundled']!), isTrue);
      if (group.key == 'base') {
        expect(_sameRaster(rasters['source']!, rasters['bundled']!), isFalse);
        report['fontVariants'] = rasters.keys.toList();
      } else {
        report['extendedFontSamples'] = group.value.keys.toList();
      }
    }
  });

  testWidgets('MTEXT exact baseline spacing preserves the CAD grid on mobile', (
    tester,
  ) async {
    var checks = 0;
    for (final factor in [0.75, 1.0, 2.0, 4.0]) {
      final document = multilingualCadDocument(samples: {'spacing': 'A\nA\nA'});
      final geometry =
          document.entities.single['geometry'] as Map<String, dynamic>;
      geometry.addAll({
        'origin': {'x': 400.0, 'y': 800.0},
        'height': 60.0,
        'line_spacing': {'factor': factor, 'style': 'exact'},
      });
      final recorder = ui.PictureRecorder();
      CadScenePainter(
        document: document,
        zoom: 1,
        pan: Offset.zero,
      ).paint(Canvas(recorder), const Size(900, 1100));
      final picture = recorder.endRecording();
      final image = await picture.toImage(900, 1100);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final pixels = data!.buffer.asUint8List();
        final starts = <int>[];
        var previousInk = false;
        for (var y = 0; y < 1100; y++) {
          var ink = false;
          for (var x = 0; x < 900; x++) {
            final at = (y * 900 + x) * 4;
            if (pixels[at] > 200 &&
                pixels[at + 1] > 200 &&
                pixels[at + 2] > 200) {
              ink = true;
              break;
            }
          }
          if (ink && !previousInk) starts.add(y);
          previousInk = ink;
        }
        expect(starts, hasLength(3));
        for (var i = 1; i < starts.length; i++) {
          expect(
            starts[i] - starts[i - 1],
            closeTo(60 * 5 / 3 * factor * 0.88, 2),
          );
        }
        checks++;
      } finally {
        image.dispose();
        picture.dispose();
      }
    }
    report['mtextBaselinePixelChecks'] = checks;
  });

  testWidgets('CAD cap-height and SVG em-size retain their physical meaning', (
    tester,
  ) async {
    var checks = 0;
    for (final family in [
      cadDefaultFontFamily,
      'CADView Noto CJK',
      'Missing cap-height font',
      'serif',
    ]) {
      for (final reference in ['cap_height', 'em']) {
        for (final factor in [1.0, 2.0]) {
          final document = multilingualCadDocument(samples: {'cap': 'A'});
          final geometry =
              document.entities.single['geometry'] as Map<String, dynamic>;
          geometry.addAll({
            'origin': {'x': 400.0, 'y': 550.0},
            'height': 100.0,
            'height_reference': reference,
            'font_family': family,
            'text_runs': [
              {
                'start': 0,
                'end': 1,
                'style': {'height_factor': factor},
              },
            ],
          });
          expect(await prepareCadTextFontMetrics(geometry), isTrue);
          final recorder = ui.PictureRecorder();
          CadScenePainter(
            document: document,
            zoom: 1,
            pan: Offset.zero,
          ).paint(Canvas(recorder), const Size(900, 1100));
          final picture = recorder.endRecording();
          final image = await picture.toImage(900, 1100);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final pixels = bytes!.buffer.asUint8List();
            var minY = 1100, maxY = -1;
            for (var y = 0; y < 1100; y++) {
              for (var x = 0; x < 900; x++) {
                final at = (y * 900 + x) * 4;
                if (pixels[at] > 200 &&
                    pixels[at + 1] > 200 &&
                    pixels[at + 2] > 200) {
                  if (y < minY) minY = y;
                  if (y > maxY) maxY = y;
                }
              }
            }
            final expected =
                100 *
                factor *
                0.88 *
                (reference == 'em' ? cadFontCapRatio(family) : 1);
            expect(
              maxY - minY + 1,
              closeTo(expected, 2),
              reason: '$family $reference $factor',
            );
            checks++;
          } finally {
            image.dispose();
            picture.dispose();
          }
        }
      }
    }
    report['nativeCapHeightPixelChecks'] = checks;
  });

  testWidgets('native DXF, snap, visibility, measurements and annotations', (
    tester,
  ) async {
    await RustLib.init();
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    final directory = await Directory.systemTemp.createTemp(
      'cadview-accuracy-',
    );
    final file = File('${directory.path}/multilingual.dxf');
    await file.writeAsString(_dxfFixture());
    final opened = await engine.openDocument(file.path);
    try {
      expect(opened.formatId, 'dxf');
      expect(opened.isPartial, isFalse);
      final actualText = opened.document.entities
          .map((entity) => entity['geometry'] as Map<String, dynamic>)
          .where((geometry) => geometry['kind'] == 'text')
          .map((geometry) => geometry['value'])
          .toList();
      expect(actualText, containsAll(multilingualSamples.values));
      expect(actualText, containsAll(extendedMultilingualSamples.values));
      expect(await engine.hitTest(opened.sessionId, 10, 10, 0.1), isNotNull);
      final snap = await engine.snapIntersection(
        opened.sessionId,
        49.9,
        50.1,
        1,
      );
      expect(snap, isNotNull);
      expect(snap!.position.dx, closeTo(50, 1e-8));
      expect(snap.position.dy, closeTo(50, 1e-8));
      expect(engine.measureDistance(0, 0, 3, 4), closeTo(5, 1e-12));
      expect(
        engine.measureAngle(
          Offset.zero,
          const Offset(1, 0),
          const Offset(0, 1),
        ),
        closeTo(90, 1e-12),
      );
      expect(
        engine.measureArea(const [
          Offset.zero,
          Offset(4, 0),
          Offset(4, 3),
          Offset(0, 3),
        ]),
        closeTo(12, 1e-12),
      );
      final layer = opened.document.layers.first.id;
      await engine.setVisibility(opened.sessionId, layer, false);
      expect(await engine.hitTest(opened.sessionId, 10, 10, 0.1), isNull);
      await engine.setVisibility(opened.sessionId, layer, true);
      final value = [
        ...multilingualSamples.values,
        ...extendedMultilingualSamples.values,
      ].join('\n');
      final notes = await engine.addTextAnnotation(
        opened.sessionId,
        value,
        50,
        50,
        null,
      );
      expect(notes, hasLength(1));
      expect(notes.single.value, value);
      expect(
        await engine.exportAnnotations(opened.sessionId),
        contains('العَرَبِيَّة'),
      );
      expect(
        await engine.deleteAnnotation(opened.sessionId, notes.single.id),
        isEmpty,
      );
      report['nativeDxfTextCount'] = actualText.length;
      report['nativeGeometryAndAnnotations'] = 'passed';
      (report['images'] as Map<String, String>)['dxf'] = base64Encode(
        await _captureScene(tester, opened.document),
      );
    } finally {
      await engine.closeDocument(opened.sessionId);
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native binary DXF preserves Unicode and legacy code pages', (
    tester,
  ) async {
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    final directory = await Directory.systemTemp.createTemp('cadview-binary-');
    final samples = [
      ...multilingualSamples.values,
      ...extendedMultilingualSamples.values,
    ];
    try {
      for (final entry in {
        'utf8': (
          version: 'AC1021',
          page: 'ANSI_1251',
          texts: samples,
          bytes: samples.map(utf8.encode).toList(),
        ),
        'cyrillic': (
          version: 'AC1015',
          page: 'ANSI_1251',
          texts: ['Размер'],
          bytes: [
            [0xd0, 0xe0, 0xe7, 0xec, 0xe5, 0xf0],
          ],
        ),
        'chinese': (
          version: 'AC1015',
          page: 'ANSI_936',
          texts: ['图纸尺寸'],
          bytes: [
            [0xcd, 0xbc, 0xd6, 0xbd, 0xb3, 0xdf, 0xb4, 0xe7],
          ],
        ),
      }.entries) {
        final file = File('${directory.path}/${entry.key}.dxf');
        await file.writeAsBytes(
          _binaryDxfFixture(
            entry.value.version,
            entry.value.page,
            entry.value.bytes,
          ),
        );
        final opened = await engine.openDocument(file.path);
        try {
          final text = opened.document.entities
              .map((entity) => entity['geometry'] as Map<String, dynamic>)
              .where((geometry) => geometry['kind'] == 'text')
              .map((geometry) => geometry['value'])
              .toList();
          expect(text, entry.value.texts);
          expect(opened.isPartial, isFalse);
          final png = await _captureScene(tester, opened.document);
          if (entry.key == 'utf8') {
            (report['images'] as Map<String, String>)['dxf-binary'] =
                base64Encode(png);
          }
        } finally {
          await engine.closeDocument(opened.sessionId);
        }
      }
      report['nativeBinaryDxfEncoding'] = [
        'UTF-8 (20 multilingual labels)',
        'Windows-1251',
        'GBK',
      ];
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'native DXF preserves text anchors and complete MTEXT paragraphs',
    (tester) async {
      final engine = NativeCadEngine()..setApplicationBackgrounded(false);
      final directory = await Directory.systemTemp.createTemp(
        'cadview-text-layout-',
      );
      final file = File('${directory.path}/layout.dxf');
      await file.writeAsString(_styledDxfFixture());
      final opened = await engine.openDocument(file.path);
      try {
        final geometry = opened.document.entities
            .map((entity) => entity['geometry'] as Map<String, dynamic>)
            .toList();
        expect(geometry, hasLength(4));
        expect(geometry[0]['origin'], {'x': 200.0, 'y': 400.0});
        expect(geometry[0]['horizontal_alignment'], 'center');
        expect(geometry[0]['width_factor'], 0.75);
        expect(geometry[0]['font_family'], 'CADView Noto CJK');
        expect(geometry[1]['target_width'], 200.0);
        expect(geometry[1]['uniform_fit'], isFalse);
        expect(geometry[2]['uniform_fit'], isTrue);
        expect(geometry[3]['value'], '中文前段\nРазмер\n日本語末段 العربية');
        expect(geometry[3]['wrap_width'], 180.0);
        expect(
          geometry[3]['rotation'],
          closeTo(15 * 3.141592653589793 / 180, 1e-12),
        );
        expect(opened.isPartial, isFalse);
        (report['images'] as Map<String, String>)['dxf-layout'] = base64Encode(
          await _captureScene(tester, opened.document),
        );
        report['nativeDxfTextLayout'] = 'anchors, fit/aligned, chunks, wrap width and DXF degree conversion passed';
      } finally {
        await engine.closeDocument(opened.sessionId);
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'R2018 embedded object preserves native multilingual text and mask',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'cadview-embedded-mtext-',
      );
      final engine = NativeCadEngine()..setApplicationBackgrounded(false);
      final sessions = <BigInt>[];
      const mainEntity =
          '0\nMTEXT\n100\nAcDbEntity\n8\n0\n420\n0\n100\nAcDbMText\n'
          '10\n100\n20\n200\n30\n0\n40\n12.5\n41\n200\n46\n150\n71\n5\n72\n1\n'
          '11\n0.8660254037844386\n21\n0.5\n31\n0\n'
          '1\n{\\H25;日本語 中文}\\Pالعربية বাংলা\\P한국어 Русский\n'
          '73\n2\n44\n0.6\n90\n17\n45\n1.5\n63\n7\n421\n16777215\n';
      const embedded =
          '101\nEmbedded Object\n70\n1\n'
          '10\n0.8660254037844386\n20\n0.5\n30\n0\n'
          '11\n100\n21\n200\n31\n0\n40\n200\n41\n150\n42\n175\n43\n160\n71\n0\n';
      try {
        for (final (spacingName, spacingStyle, spacingFactor) in [
          ('exact', 2, 0.6),
          ('at_least', 1, 1.2),
        ]) {
          final documents = <CadDocumentModel>[];
          final images = <Uint8List>[];
          for (final (name, extra) in [('plain', ''), ('embedded', embedded)]) {
            final entity = mainEntity.replaceFirst(
              '73\n2\n44\n0.6\n',
              '73\n$spacingStyle\n44\n$spacingFactor\n',
            );
            final file = File('${directory.path}/$spacingName-$name.dxf');
            await file.writeAsString(
              '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1032\n0\nENDSEC\n'
              '0\nSECTION\n2\nENTITIES\n$entity${extra}0\nENDSEC\n0\nEOF\n',
            );
            final opened = await engine.openDocument(file.path);
            sessions.add(opened.sessionId);
            documents.add(opened.document);
            expect(opened.document.entities, hasLength(1));
            final geometry = opened.document.entities.single['geometry'] as Map;
            expect(geometry['origin'], {'x': 100.0, 'y': 200.0});
            expect(geometry['height'], 12.5);
            expect(geometry['rotation'], closeTo(math.pi / 6, 1e-12));
            expect(geometry['line_spacing'], {
              'factor': spacingFactor,
              'style': spacingName,
            });
            expect((geometry['background'] as Map)['scale'], 1.5);
            expect((geometry['background'] as Map)['layout_supported'], isTrue);
            expect(
              (geometry['text_runs'] as List).first['style']['height_factor'],
              2.0,
            );
            images.add(await _captureScene(tester, opened.document));
          }
          // Compare nested values, not Map identity across native sessions.
          expect(documents[1].entities, equals(documents[0].entities));
          expect(documents[1].bounds2D, documents[0].bounds2D);
          expect(
            images[1],
            orderedEquals(images[0]),
            reason: 'Embedded metadata changed the displayed glyphs or mask',
          );
          (report['images'] as Map<String, String>)[spacingName == 'exact'
              ? 'mtext-embedded-exact'
              : 'mtext-embedded'] = base64Encode(
            images[1],
          );
        }
        report['nativeEmbeddedMText'] = 'R2018/no-columns: AtLeast and Exact geometry, refined bounds and PNG match their plain paragraphs';
      } finally {
        for (final session in sessions) {
          await engine.closeDocument(session);
        }
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets('native R2018 columns retain multilingual flow and viewport tails', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('cadview-columns-');
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    const rows = ['A中文', 'B日本語', 'Cالعربية', 'Dবাংলা', 'Eहिन्दी', 'F한국어'];
    final sessions = <BigInt>[];
    var checks = 0;
    try {
      for (final (kind, auto, mode) in [
        (1, false, 'static'),
        (2, true, 'auto'),
        (2, false, 'manual'),
      ]) {
        for (final reversed in [false, true]) {
          final count = auto ? 0 : 3;
          final heights = mode == 'manual' ? '46\n20\n46\n40\n46\n0\n' : '';
          final file = File('${directory.path}/$mode-$reversed.dxf');
          await file.writeAsString(
            '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1032\n0\nENDSEC\n'
            '0\nSECTION\n2\nENTITIES\n0\nMTEXT\n100\nAcDbEntity\n8\n0\n100\nAcDbMText\n'
            '10\n100\n20\n200\n30\n0\n40\n10\n41\n999\n46\n999\n71\n1\n72\n1\n'
            '1\n${rows.join(r'\P')}\n73\n2\n44\n1\n'
            '101\nEmbedded Object\n70\n1\n10\n1\n20\n0\n30\n0\n11\n100\n21\n200\n31\n0\n'
            '40\n999\n41\n40\n42\n340\n43\n40\n71\n$kind\n72\n$count\n44\n100\n45\n20\n'
            '73\n${auto ? 1 : 0}\n74\n${reversed ? 1 : 0}\n${heights}0\nENDSEC\n0\nEOF\n',
          );
          final opened = await engine.openDocument(file.path);
          sessions.add(opened.sessionId);
          expect(opened.isPartial, isFalse);
          expect(opened.document.entities, hasLength(1));
          final entity = opened.document.entities.single;
          final geometry = entity['geometry'] as Map<String, dynamic>;
          final columns = geometry['columns'] as Map;
          expect(columns['count'], 3);
          expect(columns['width'], 100.0);
          expect(columns['gutter'], 20.0);
          expect(columns['flow_reversed'], reversed);
          expect(geometry['height'], 10.0);
          expect(geometry['wrap_width'], 100.0);
          final paragraphs = mode == 'manual'
              ? [
                  rows[0],
                  rows.sublist(1, 3).join('\n'),
                  rows.sublist(3).join('\n'),
                ]
              : [
                  rows.sublist(0, 2).join('\n'),
                  rows.sublist(2, 4).join('\n'),
                  rows.sublist(4).join('\n'),
                ];
          expect(
            cadTextColumnLayout(geometry).map((column) => column.text),
            paragraphs,
          );
          final retained = await engine.loadViewport(
            opened.sessionId,
            const Rect.fromLTWH(350, 170, 20, 20),
          );
          expect(
            retained.entities,
            hasLength(1),
            reason: 'Visible final-column text must survive when the insertion lies outside the query',
          );
          CadDocumentModel fixed(List<Map<String, dynamic>> entities) =>
              CadDocumentModel(
                format: 'dxf',
                displayName: mode,
                sceneKind: 'two_d',
                diagnostics: const [],
                scene: Map<String, dynamic>.from(opened.document.scene)
                  ..['entities'] = entities
                  ..['bounds'] = {
                    'min': {'x': 80.0, 'y': 110.0},
                    'max': {'x': 460.0, 'y': 240.0},
                  },
              );
          final oracle = [
            for (var i = 0; i < 3; i++)
              {
                ...entity,
                'id': i + 10,
                'geometry': {
                  ...geometry,
                  'columns': null,
                  'value': paragraphs[i],
                  'origin': {
                    'x': 100.0 + (reversed ? 2 - i : i) * 120,
                    'y': 200.0,
                  },
                },
              },
          ];
          final actual = await _captureScene(tester, fixed([entity]));
          final expected = await _captureScene(tester, fixed(oracle));
          expect(
            actual,
            orderedEquals(expected),
            reason:
                'Native $mode columns differ from independently positioned source paragraphs',
          );
          (report['images']
                  as Map<
                    String,
                    String
                  >)['mtext-columns-$mode${reversed ? '-reversed' : ''}'] =
              base64Encode(actual);
          checks++;
        }
      }
      report['nativeMTextColumns'] =
          '$checks static/auto/manual × normal/reversed cases: independent glyph positions and native culling passed';
    } finally {
      for (final session in sessions) {
        await engine.closeDocument(session);
      }
      await directory.delete(recursive: true);
    }
  });

  const corpusRoot = String.fromEnvironment('CADVIEW_CORPUS_ROOT');
  testWidgets('actual fitted and wrapped glyphs survive native viewport culling', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'cadview-text-index-',
    );
    final file = File('${directory.path}/text-index.dxf');
    final source = StringBuffer(
      '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1021\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n',
    );
    for (var index = 0; index < 4; index++) {
      source.write(
        '0\nTEXT\n8\n0\n10\n${index * 500}\n20\n0\n11\n${index * 500 + 100}\n21\n${index.isOdd ? 100 : 0}\n40\n10\n41\n0.1\n72\n3\n71\n${index >= 2 ? 6 : 0}\n1\nI\n',
      );
    }
    for (var index = 0; index < 4; index++) {
      source.write(
        '0\nMTEXT\n8\n0\n10\n${index * 500}\n20\n-500\n40\n50\n41\n75\n71\n${index.isOdd ? 9 : 1}\n50\n${index * 20}\n1\n中文 العربية বাংলা བོད་ཡིག 中文 العربية বাংলা བོད་ཡིག\n',
      );
    }
    source.write(
      '0\nTEXT\n10\n-2200\n20\n0\n30\n30\n40\n50\n50\n30\n1\n{中文} \\P日本語 \\H2;Размер %%%\n210\n0\n220\n0\n230\n-1\n'
      '0\nTEXT\n10\n-10\n20\n20\n30\n30\n11\n-2600\n21\n100\n31\n100\n72\n1\n40\n50\n1\n倾斜 বাংলা العربية\n210\n0\n220\n0.6\n230\n0.8\n'
      '0\nMTEXT\n10\n3000\n20\n-500\n30\n30\n40\n50\n41\n200\n71\n1\n1\nWCS 中文\\~120\\Pالعربية\n210\n0\n220\n0\n230\n-1\n11\n1\n21\n0\n31\n0\n'
      '0\nMTEXT\n10\n3500\n20\n-500\n40\n50\n41\n200\n71\n1\n1\nAngle 日本語\\PРазмер\n210\n0\n220\n0\n230\n-1\n50\n30\n',
    );
    source.write(
      '0\nMTEXT\n10\n4000\n20\n-500\n40\n40\n41\n220\n71\n1\n3\n中文{\\fCADView Noto CJK|b1|i1;\\H2x;\\L日本語\\l}\\P\n1\n{\\H20;\\Oالعربية বাংলা\\o} 한국어\n'
      '0\nTEXT\n10\n4500\n20\n0\n40\n40\n1\nA%%u中文%%o é%%uB%%kC%%oD%%kE\n',
    );
    for (final (style, factor, x) in [(2, 0.25, 5000), (1, 4.0, 5500)]) {
      source.write(
        '0\nMTEXT\n10\n$x\n20\n-500\n40\n40\n41\n400\n71\n1\n73\n$style\n44\n$factor\n50\n-30\n1\n中文\\P{\\H4x;العربية বাংলা}\\P日本語 한국어\n',
      );
    }
    source.write('0\nENDSEC\n0\nEOF\n');
    await file.writeAsString(source.toString());
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    final opened = await engine.openDocument(file.path);
    try {
      expect(opened.document.entities, hasLength(16));
      final projected = opened.document.entities
          .skip(8)
          .map((entity) => entity['geometry'] as Map<String, dynamic>)
          .toList();
      expect(
        projected.every(
          (geometry) => geometry['height_reference'] == 'cap_height',
        ),
        isTrue,
      );
      expect(projected[0]['origin'], {'x': 2200.0, 'y': 0.0});
      expect(projected[0]['value'], r'{中文} \P日本語 \H2;Размер %');
      expect(projected[0]['plane'], {
        'xx': -1.0,
        'xy': 0.0,
        'yx': 0.0,
        'yy': 1.0,
      });
      expect((projected[1]['origin'] as Map)['x'], closeTo(2600, 1e-10));
      expect((projected[1]['origin'] as Map)['y'], closeTo(-20, 1e-10));
      expect((projected[1]['plane'] as Map)['yy'], closeTo(-0.8, 1e-12));
      expect(projected[2]['origin'], {'x': 3000.0, 'y': -500.0});
      expect(projected[2]['value'], 'WCS 中文\u00a0120\nالعربية');
      expect(projected[2]['plane'], {
        'xx': 1.0,
        'xy': 0.0,
        'yx': 0.0,
        'yy': -1.0,
      });
      expect(projected[3]['rotation'], 0.0);
      expect(
        (projected[3]['plane'] as Map)['xx'],
        closeTo(0.8660254037844386, 1e-12),
      );
      expect(projected[4]['value'], '中文日本語\nالعربية বাংলা 한국어');
      final richRuns = projected[4]['text_runs'] as List;
      expect(richRuns[1]['start'], 2);
      expect(richRuns[1]['end'], 5);
      expect(richRuns[1]['style']['font_family'], 'CADView Noto CJK');
      expect(richRuns[1]['style']['height_factor'], 2.0);
      expect(richRuns[1]['style']['underline'], isTrue);
      expect(richRuns[1]['style']['bold'], isTrue);
      expect(richRuns[1]['style']['italic'], isTrue);
      expect(richRuns[3]['style']['height_factor'], 0.5);
      expect(richRuns[3]['style']['overline'], isTrue);
      expect(projected[5]['value'], 'A中文 éBCDE');
      expect(projected[6]['line_spacing'], {'factor': 0.25, 'style': 'exact'});
      expect(projected[7]['line_spacing'], {
        'factor': 4.0,
        'style': 'at_least',
      });
      expect(
        (projected[5]['text_runs'] as List)[4]['style']['strike_through'],
        isTrue,
      );
      (report['images'] as Map<String, String>)['dxf-rich'] = base64Encode(
        await _captureScene(
          tester,
          CadDocumentModel(
            format: 'dxf',
            displayName: 'rich-text',
            sceneKind: 'two_d',
            scene: Map<String, dynamic>.from(opened.document.scene)
              ..['entities'] = opened.document.entities.skip(12).toList()
              ..['bounds'] = {
                'min': {'x': 3900.0, 'y': -800.0},
                'max': {'x': 4850.0, 'y': 150.0},
              },
            diagnostics: const [],
          ),
        ),
      );
      report['nativeRichText'] = 'scoped fonts/heights, UTF-16 runs, decorations and real glyph culling passed';
      var probes = 0;
      for (final entity in opened.document.entities) {
        final geometry = entity['geometry'] as Map<String, dynamic>;
        final world = cadTextWorldBounds(geometry);
        if (geometry['kind'] == 'text' && geometry['uniform_fit'] == true) {
          expect(world.longestSide, greaterThan(1000));
        }
        final scene = Map<String, dynamic>.from(opened.document.scene)
          ..['entities'] = [entity]
          ..['bounds'] = {
            'min': {'x': world.left, 'y': world.top},
            'max': {'x': world.right, 'y': world.bottom},
          };
        final isolated = CadDocumentModel(
          format: 'dxf',
          displayName: 'isolated',
          sceneKind: 'two_d',
          scene: scene,
          diagnostics: const [],
        );
        const size = Size(600, 700);
        final recorder = ui.PictureRecorder();
        CadScenePainter(
          document: isolated,
          zoom: 1,
          pan: Offset.zero,
        ).paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(600, 700);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final pixels = data!.buffer.asUint8List();
        final transform = CadViewTransform.forScene(
          isolated,
          size,
          1,
          Offset.zero,
        );
        var checked = 0;
        // Sample every visible row, including glyphs far beyond the old
        // single-line estimate. Query the real Rust R-tree, not a Dart mock.
        for (var y = 0; y < 700; y += 15) {
          for (var x = 0; x < 600; x++) {
            final offset = (y * 600 + x) * 4;
            if (pixels[offset] < 180 ||
                pixels[offset + 1] < 180 ||
                pixels[offset + 2] < 180) {
              continue;
            }
            final point = transform.screenToWorld(Offset(x + 0.5, y + 0.5));
            final retained = await engine.loadViewport(
              opened.sessionId,
              Rect.fromCenter(center: point, width: 0.01, height: 0.01),
            );
            expect(
              retained.entities.any(
                (candidate) => candidate['id'] == entity['id'],
              ),
              isTrue,
              reason:
                  'Native index discarded visible glyph for entity ${entity['id']}',
            );
            checked++;
            break;
          }
        }
        image.dispose();
        picture.dispose();
        expect(
          checked,
          greaterThan(0),
          reason: 'Fixture must paint actual glyphs',
        );
        probes += checked;
      }
      report['nativeGlyphViewportProbes'] = probes;
    } finally {
      await engine.closeDocument(opened.sessionId);
      await directory.delete(recursive: true);
    }
  });

  const dwgTextRoot = String.fromEnvironment('CADVIEW_DWG_TEXT_ROOT');
  if (dwgTextRoot.isNotEmpty) {
    testWidgets('native DWG keeps nested, tilted and array text frames', (
      tester,
    ) async {
      final engine = NativeCadEngine()..setApplicationBackgrounded(false);
      var glyphProbes = 0;
      Offset rotate(Offset p, double angle) => Offset(
        p.dx * math.cos(angle) - p.dy * math.sin(angle),
        p.dx * math.sin(angle) + p.dy * math.cos(angle),
      );
      Offset inner(Offset p) => rotate(Offset(2 * p.dx, 3 * p.dy), 0.6);
      Offset outer(Offset p) => rotate(Offset(-p.dx, 2 * p.dy), -0.2);
      void expectPoint(Map point, Offset expected) {
        expect(point['x'], closeTo(expected.dx, 1e-10));
        expect(point['y'], closeTo(expected.dy, 1e-10));
      }

      for (final name in [
        'nested-text',
        'array-text',
        'tilted-text',
        'attribute-text',
        'constant-text',
      ]) {
        final opened = await engine.openDocument('$dwgTextRoot/$name.dwg');
        try {
          expect(opened.formatId, 'dwg');
          final entities = opened.document.entities;
          if (name == 'nested-text') {
            expect(entities, hasLength(2));
            final origin =
                outer(inner(const Offset(5, 13)) + const Offset(24, 27)) +
                const Offset(100, 200);
            for (var i = 0; i < 2; i++) {
              final geometry = entities[i]['geometry'] as Map<String, dynamic>;
              expectPoint(geometry['origin'] as Map, origin);
              expect(geometry['height'], 12.0);
              expect(geometry['rotation'], closeTo(i == 0 ? 0.3 : 0, 1e-12));
              if (i == 1) expect(geometry['wrap_width'], 120.0);
              final plane = geometry['plane'] as Map;
              for (final basis in [
                const Offset(1, 0),
                const Offset(0, 1),
                const Offset(3, -2),
              ]) {
                final expected = outer(
                  inner(i == 0 ? basis : rotate(basis, 0.3)),
                );
                expect(
                  (plane['xx'] as num) * basis.dx +
                      (plane['xy'] as num) * basis.dy,
                  closeTo(expected.dx, 1e-10),
                );
                expect(
                  (plane['yx'] as num) * basis.dx +
                      (plane['yy'] as num) * basis.dy,
                  closeTo(expected.dy, 1e-10),
                );
              }
            }
          } else if (name == 'array-text') {
            expect(entities, hasLength(8));
            for (var cell = 0; cell < 4; cell++) {
              final expected = Offset(
                -5 - (cell ~/ 2) * 200,
                28 + (cell % 2) * 100,
              );
              final text = entities[cell * 2]['geometry'] as Map;
              final line = entities[cell * 2 + 1]['geometry'] as Map;
              expect(text['kind'], 'text');
              expect(line['kind'], 'line');
              expectPoint(text['origin'] as Map, expected);
              expectPoint(line['start'] as Map, expected);
              expectPoint(line['end'] as Map, expected + const Offset(0, 2));
            }
          } else if (name == 'attribute-text') {
            expect(entities, hasLength(20));
            final layer = opened.document.layers.firstWhere(
              (layer) => layer.name == 'Labels',
            );
            for (final (
                  label,
                  start,
                  horizontal,
                  vertical,
                  fitted,
                  uniform,
                  mirrorX,
                  mirrorY,
                )
                in [
                  (
                    '中文 العربية',
                    const Offset(30, 40),
                    'center',
                    'top',
                    false,
                    false,
                    true,
                    false,
                  ),
                  (
                    '日本語 বাংলা',
                    const Offset(4, 5),
                    'left',
                    'baseline',
                    true,
                    false,
                    false,
                    true,
                  ),
                  (
                    'ไทย aligned',
                    const Offset(4, 5),
                    'left',
                    'baseline',
                    true,
                    true,
                    false,
                    true,
                  ),
                  (
                    'Middle עברית',
                    const Offset(-10, 30),
                    'center',
                    'middle',
                    false,
                    false,
                    false,
                    false,
                  ),
                ]) {
              final matches = entities
                  .where(
                    (entity) => (entity['geometry'] as Map)['value'] == label,
                  )
                  .toList();
              expect(matches, hasLength(4));
              for (var cell = 0; cell < 4; cell++) {
                final entity = matches[cell];
                final geometry = entity['geometry'] as Map;
                expectPoint(
                  geometry['origin'] as Map,
                  start + Offset(-(cell ~/ 2) * 200, (cell % 2) * 100),
                );
                expect(entity['layer_id'], layer.id.toInt());
                expect(geometry['height'], 12.0);
                expect(geometry['horizontal_alignment'], horizontal);
                expect(geometry['vertical_alignment'], vertical);
                expect(geometry['target_width'], fitted ? 50.0 : isNull);
                expect(geometry['uniform_fit'], uniform);
                expect(geometry['mirrored_x'], mirrorX);
                expect(geometry['mirrored_y'], mirrorY);
                if (fitted) {
                  expect(
                    geometry['rotation'],
                    closeTo(math.atan2(40, 30), 1e-12),
                  );
                } else {
                  expect(entity['color_argb'], 0xff0000ff);
                }
                if (label == '中文 العربية') {
                  expect(geometry['width_factor'], 1.3);
                  expect(geometry['oblique_angle'], 0.25);
                }
              }
            }
            await engine.setVisibility(opened.sessionId, layer.id, false);
            final hidden = await engine.loadViewport(
              opened.sessionId,
              opened.document.bounds2D!.inflate(1),
            );
            expect(
              hidden.entities,
              isEmpty,
              reason: 'All attribute instances must inherit the INSERT layer',
            );
            await engine.setVisibility(opened.sessionId, layer.id, true);
          } else if (name == 'constant-text') {
            expect(entities, hasLength(8));
            final layer = opened.document.layers.firstWhere(
              (layer) => layer.name == 'Labels',
            );
            for (var cell = 0; cell < 4; cell++) {
              for (var i = 0; i < 2; i++) {
                final entity = entities[cell * 2 + i];
                final geometry = entity['geometry'] as Map;
                expectPoint(
                  geometry['origin'] as Map,
                  (i == 0 ? const Offset(61, 210) : const Offset(115, 170)) +
                      Offset(-(cell ~/ 2) * 200, (cell % 2) * 100),
                );
                expect(geometry['value'], i == 0 ? '中文 العربية' : '日本語 বাংলা');
                expect(geometry['height'], 12.0);
                expect(
                  geometry['horizontal_alignment'],
                  i == 0 ? 'center' : 'left',
                );
                expect(
                  geometry['vertical_alignment'],
                  i == 0 ? 'top' : 'baseline',
                );
                expect(geometry['mirrored_x'], i == 0);
                expect(geometry['width_factor'], i == 0 ? 1.25 : 1.0);
                expect(geometry['oblique_angle'], i == 0 ? 0.2 : 0.0);
                final basis = geometry['plane'] as Map;
                expect(basis['xx'], closeTo(0, 1e-10));
                expect(basis['xy'], closeTo(i == 0 ? -3 : 2.4, 1e-10));
                expect(basis['yx'], closeTo(i == 0 ? 2 : -2, 1e-10));
                expect(basis['yy'], closeTo(0, 1e-10));
                expect(entity['layer_id'], layer.id.toInt());
                expect(entity['color_argb'], 0xff0000ff);
              }
            }
            await engine.setVisibility(opened.sessionId, layer.id, false);
            final hidden = await engine.loadViewport(
              opened.sessionId,
              opened.document.bounds2D!.inflate(1),
            );
            expect(hidden.entities, isEmpty);
            await engine.setVisibility(opened.sessionId, layer.id, true);
          } else {
            expect(entities, hasLength(2));
            for (var i = 0; i < 2; i++) {
              final geometry = entities[i]['geometry'] as Map;
              expectPoint(
                geometry['origin'] as Map,
                i == 0 ? const Offset(-10, 2) : const Offset(100, 200),
              );
              final plane = geometry['plane'] as Map;
              expect(plane['xx'], closeTo(i == 0 ? -1 : 1, 1e-12));
              expect(plane['xy'], closeTo(0, 1e-12));
              expect(plane['yx'], closeTo(0, 1e-12));
              expect(plane['yy'], closeTo(i == 0 ? -0.8 : 0.8, 1e-12));
            }
          }
          (report['images'] as Map<String, String>)['dwg-$name'] = base64Encode(
            await _captureScene(tester, opened.document),
          );
          glyphProbes += await _probeNativeDwgGlyphs(engine, opened);
        } finally {
          await engine.closeDocument(opened.sessionId);
        }
      }
      report['dwgTextFrames'] = {
        'fixtures': 5,
        'nativeGlyphViewportProbes': glyphProbes,
      };
    });
  }

  testWidgets('native MTEXT masks retain flags, colors and visible glyphs', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('cadview-mask-');
    final file = File('${directory.path}/mask.dxf');
    await file.writeAsString(
      '0\nSECTION\n2\nHEADER\n9\n\$ACADVER\n1\nAC1032\n0\nENDSEC\n'
      '0\nSECTION\n2\nTABLES\n0\nTABLE\n2\nLAYER\n0\nLAYER\n2\nInkBlack\n62\n1\n420\n0\n0\nENDTAB\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n'
      '0\nLINE\n8\n0\n62\n5\n10\n0\n20\n110\n11\n300\n21\n110\n'
      // Explicit RGB zero is black, not an absent override of ACI 250. Entity
      // color-book names must not be parsed as named background masks.
      '0\nMTEXT\n100\nAcDbEntity\n8\n0\n62\n250\n420\n0\n430\nBook\$Ink\n100\nAcDbMText\n10\n150\n20\n100\n40\n30\n41\n80\n71\n1\n1\n中文\\Pالعربية\n90\n17\n63\n1\n421\n16777215\n45\n1.5\n'
      '0\nLINE\n8\n0\n62\n3\n10\n160\n20\n110\n11\n200\n21\n110\n'
      '0\nMTEXT\n100\nAcDbEntity\n8\nInkBlack\n100\nAcDbMText\n10\n40\n20\n-100\n40\n30\n41\n130\n71\n1\n1\n日本語\\Pবাংলা\n90\n19\n63\n1\n45\n1.5\n0\nENDSEC\n0\nEOF\n',
    );
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    try {
      final opened = await engine.openDocument(file.path);
      try {
        final labels = opened.document.entities
            .where((e) => (e['geometry'] as Map)['kind'] == 'text')
            .toList();
        expect(labels, hasLength(2));
        final first = labels.first['geometry'] as Map;
        final last = labels.last['geometry'] as Map;
        expect(labels.first['color_argb'], 0xff000000);
        expect(labels.last['color_argb'], 0xff000000);
        final blackLayer = opened.document.layers.firstWhere(
          (layer) => layer.name == 'InkBlack',
        );
        expect(blackLayer.color.toARGB32(), 0xff000000);
        expect((first['background'] as Map)['color_argb'], 0xffffffff);
        expect((first['background'] as Map)['frame'], isTrue);
        expect((last['background'] as Map)['color_mode'], 'canvas');
        expect(first['value'], '中文\nالعربية');
        expect(last['value'], '日本語\nবাংলা');
        expect(
          (first['text_warnings'] as List?) ?? const [],
          isNot(contains('mtext_named_background_color_fallback')),
        );
        final bytes = await _captureScene(tester, opened.document);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final pixels = data!.buffer.asUint8List();
          var white = 0, black = 0, green = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            if (pixels[i] > 250 && pixels[i + 1] > 250 && pixels[i + 2] > 250) {
              white++;
            }
            if (pixels[i] < 4 && pixels[i + 1] < 4 && pixels[i + 2] < 4) {
              black++;
            }
            // A subpixel cosmetic line over a white mask has blended red/blue
            // channels. Require green chroma, not an opaque pixel centre.
            if (pixels[i + 1] > 210 &&
                pixels[i + 1] - pixels[i] > 60 &&
                pixels[i + 1] - pixels[i + 2] > 60) {
              green++;
            }
          }
          (report['images'] as Map<String, String>)['mtext-mask'] =
              base64Encode(bytes);
          expect(white, greaterThan(1000));
          expect(
            black,
            greaterThan(100),
            reason: 'Black glyphs on the explicit white mask must remain black',
          );
          expect(
            green,
            greaterThan(30),
            reason: 'Later geometry must remain visible on top of the mask',
          );
          report['mtextMaskPixels'] = {
            'white': white,
            'black': black,
            'laterGreen': green,
          };
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
        await engine.setVisibility(opened.sessionId, blackLayer.id, false);
        final hidden = await engine.loadViewport(
          opened.sessionId,
          opened.document.bounds2D!.inflate(1),
        );
        expect(hidden.entities, hasLength(3));
        expect(
          hidden.entities.any(
            (entity) => (entity['geometry'] as Map)['value'] == '日本語\nবাংলা',
          ),
          isFalse,
        );
        await engine.setVisibility(opened.sessionId, blackLayer.id, true);
        report['nativeTrueBlackInk'] = 'explicit and ByLayer RGB zero retained';
      } finally {
        await engine.closeDocument(opened.sessionId);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('cancelling during text refinement closes the native session', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'cadview-cancel-text-',
    );
    final file = File('${directory.path}/cancel.dxf');
    await file.writeAsString(_styledDxfFixture());
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    var cancelledDuringLayout = false;
    try {
      await expectLater(
        engine.openDocument(
          file.path,
          onEvent: (event) {
            if (event.stage == 'first_frame' &&
                event.kind == 'progress' &&
                event.progress == 1) {
              cancelledDuringLayout = true;
              engine.cancelCurrentOpen();
            }
          },
        ),
        throwsA(isA<CadOpenCancelled>()),
      );
      expect(cancelledDuringLayout, isTrue);
      final reopened = await engine.openDocument(file.path);
      expect(reopened.document.entities, isNotEmpty);
      // Tests run sequentially in this VM, so the immediately preceding
      // native session is the cancelled open, not an unrelated document.
      await expectLater(
        native.documentSummary(sessionId: reopened.sessionId - BigInt.one),
        throwsA(
          predicate<Object>(
            (error) => error.toString().contains('unknown session'),
          ),
        ),
      );
      await engine.closeDocument(reopened.sessionId);
      report['textLayoutCancellation'] = 'cancelled and reopened';
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('PDF PNG captures the loaded page without navigation controls', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('cadview-png-pdf-');
    final file = File('${directory.path}/export.pdf');
    await file.writeAsString(_pdfFixture());
    final key = GlobalKey();
    var ready = false;
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Center(
            child: SizedBox(
              width: 320,
              height: 480,
              child: PdfDocumentViewport(
                path: file.path,
                captureKey: key,
                onExportReadyChanged: (value) => ready = value,
              ),
            ),
          ),
        ),
      );
      for (var attempt = 0; !ready && attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready, isTrue);
      expect(
        find.descendant(of: find.byKey(key), matching: find.byType(IconButton)),
        findsNothing,
      );
      final capture = captureViewportPng(key, devicePixelRatio: 2);
      await tester.pump();
      final bytes = await capture;
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 640);
      expect(frame.image.height, 960);
      frame.image.dispose();
      codec.dispose();
      (report['images'] as Map<String, String>)['pdf-export'] = base64Encode(
        bytes,
      );
      report['pdfImageExport'] = 'passed';
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await directory.delete(recursive: true);
    }
  });

  testWidgets('native STL scene exports the current 3D view as PNG', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('cadview-png-stl-');
    final file = File('${directory.path}/triangle.stl');
    await file.writeAsString(
      'solid test\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid test\n',
    );
    final engine = NativeCadEngine()..setApplicationBackgrounded(false);
    final opened = await engine.openDocument(file.path);
    try {
      expect(opened.sceneKind, 'three_d');
      expect(opened.document.meshes, isNotEmpty);
      (report['images'] as Map<String, String>)['stl-export'] = base64Encode(
        await _captureScene(tester, opened.document, export: true),
      );
      report['stlImageExport'] = 'passed';
    } finally {
      await engine.closeDocument(opened.sessionId);
      await directory.delete(recursive: true);
    }
  });
  const dxfSample = String.fromEnvironment('CADVIEW_DXF_SAMPLE');
  if (dxfSample.isNotEmpty) {
    testWidgets('R20 DXF keeps its name and exports a readable PNG', (
      tester,
    ) async {
      final engine = NativeCadEngine()..setApplicationBackgrounded(false);
      final opened = await engine.openDocument(dxfSample);
      try {
        expect(opened.displayName, 'R20-0000_1.dxf');
        expect(opened.document.entities, isNotEmpty);
        final bytes = await _captureScene(
          tester,
          opened.document,
          export: true,
        );
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1800);
        expect(frame.image.height, 2200);
        frame.image.dispose();
        codec.dispose();
        (report['images'] as Map<String, String>)['dxf-r20'] = base64Encode(
          bytes,
        );
        report['dxfR20'] = {
          'name': opened.displayName,
          'entities': opened.document.entities.length,
          'pngWidth': 1800,
          'pngHeight': 2200,
        };
      } finally {
        await engine.closeDocument(opened.sessionId);
      }
    });
  }
  if (corpusRoot.isNotEmpty) {
    testWidgets('authorized DWG samples open with complete finite scenes', (
      tester,
    ) async {
      final engine = NativeCadEngine()..setApplicationBackgrounded(false);
      final summaries = <Map<String, dynamic>>[];
      for (final name in const [
        'A1、A2、A3图框.dwg',
        'Armchair-Dwgfree.com_.dwg',
        'Bedside-Table-Dwgfree.com_.dwg',
      ]) {
        final opened = await engine.openDocument('$corpusRoot/$name');
        try {
          expect(opened.formatId, 'dwg');
          expect(opened.isPartial, isFalse);
          expect(opened.document.entities, isNotEmpty);
          final bounds = opened.document.bounds2D!;
          expect(
            [
              bounds.left,
              bounds.top,
              bounds.right,
              bounds.bottom,
            ].every((value) => value.isFinite),
            isTrue,
          );
          expect(bounds.width, greaterThan(0));
          expect(bounds.height, greaterThan(0));
          final count = opened.document.entities.length;
          if (name.startsWith('A1')) {
            expect(count, greaterThanOrEqualTo(1100));
            expect(
              _hasLine(
                opened.document,
                const Offset(1021.0938, 2027.8369),
                const Offset(1067.6660, 2032.5297),
              ),
              isFalse,
            );
            expect(
              _hasLine(
                opened.document,
                const Offset(1023.5938, 2032.5297),
                const Offset(1065.1660, 2032.5297),
              ),
              isTrue,
            );
          } else if (name.startsWith('Armchair')) {
            expect(count, greaterThanOrEqualTo(55000));
          } else {
            expect(count, greaterThanOrEqualTo(12000));
          }
          final imageKey = name.startsWith('A1')
              ? 'dwg-title'
              : name.startsWith('Armchair')
              ? 'dwg-armchair'
              : 'dwg-bedside';
          (report['images'] as Map<String, String>)[imageKey] = base64Encode(
            await _captureScene(tester, opened.document),
          );
          final darkInk = opened.document.entities
              .where(
                (entity) =>
                    cadCanvasColor(entity['color_argb'] as int).toARGB32() !=
                    entity['color_argb'],
              )
              .length;
          summaries.add({
            'name': name,
            'entities': count,
            'darkNeutralInk': darkInk,
          });
        } finally {
          await engine.closeDocument(opened.sessionId);
        }
      }
      report['dwgSamples'] = summaries;
    });
  }
}

Future<int> _probeNativeDwgGlyphs(
  NativeCadEngine engine,
  OpenedCadDocument opened,
) async {
  var probes = 0;
  for (final entity in opened.document.entities) {
    final geometry = entity['geometry'] as Map<String, dynamic>;
    if (geometry['kind'] != 'text') {
      continue;
    }
    final world = cadTextWorldBounds(geometry);
    final isolated = CadDocumentModel(
      format: 'dwg',
      displayName: 'glyph-probe',
      sceneKind: 'two_d',
      diagnostics: const [],
      scene: Map<String, dynamic>.from(opened.document.scene)
        ..['entities'] = [entity]
        ..['bounds'] = {
          'min': {'x': world.left, 'y': world.top},
          'max': {'x': world.right, 'y': world.bottom},
        },
    );
    const size = Size(600, 700);
    final recorder = ui.PictureRecorder();
    CadScenePainter(
      document: isolated,
      zoom: 1,
      pan: Offset.zero,
    ).paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(600, 700);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      final transform = CadViewTransform.forScene(
        isolated,
        size,
        1,
        Offset.zero,
      );
      var checked = 0;
      for (var y = 0; y < 700; y += 15) {
        for (var x = 0; x < 600; x++) {
          final at = (y * 600 + x) * 4;
          // Include saturated ByBlock attribute ink, not just white labels.
          // The background/grid channel maxima remain below 100 here.
          if (pixels[at] < 180 &&
              pixels[at + 1] < 180 &&
              pixels[at + 2] < 180) {
            continue;
          }
          final point = transform.screenToWorld(Offset(x + 0.5, y + 0.5));
          final retained = await engine.loadViewport(
            opened.sessionId,
            Rect.fromCenter(center: point, width: 0.01, height: 0.01),
          );
          expect(
            retained.entities.any(
              (candidate) => candidate['id'] == entity['id'],
            ),
            isTrue,
            reason:
                'Rust index discarded transformed DWG glyph ${entity['id']}',
          );
          checked++;
          break;
        }
      }
      expect(
        checked,
        greaterThan(0),
        reason: 'DWG text fixture must paint real glyphs',
      );
      probes += checked;
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  return probes;
}

// Author the binary pairs directly instead of using the parser's DXF writer.
Uint8List _binaryDxfFixture(
  String version,
  String page,
  List<List<int>> labels,
) {
  final builder = BytesBuilder()
    ..add(ascii.encode('AutoCAD Binary DXF\r\n'))
    ..add([0x1a, 0]);
  void code(int value) => builder.add([value & 255, value >> 8]);
  void text(int group, List<int> value) {
    code(group);
    builder
      ..add(value)
      ..addByte(0);
  }

  void number(int group, double value) {
    code(group);
    builder.add(
      (ByteData(8)..setFloat64(0, value, Endian.little)).buffer.asUint8List(),
    );
  }

  for (final pair in [
    (0, 'SECTION'),
    (2, 'HEADER'),
    (9, r'$ACADVER'),
    (1, version),
    (9, r'$DWGCODEPAGE'),
    (3, page),
    (0, 'ENDSEC'),
    (0, 'SECTION'),
    (2, 'ENTITIES'),
  ]) {
    text(pair.$1, ascii.encode(pair.$2));
  }
  for (var i = 0; i < labels.length; i++) {
    text(0, ascii.encode('TEXT'));
    text(8, ascii.encode('0'));
    text(1, labels[i]);
    number(10, 0);
    number(20, 1700 - i * 80);
    number(40, 28);
  }
  text(0, ascii.encode('ENDSEC'));
  text(0, ascii.encode('EOF'));
  return builder.toBytes();
}

String _styledDxfFixture() => '''0
SECTION
2
HEADER
9
\$ACADVER
1
AC1021
0
ENDSEC
0
SECTION
2
TABLES
0
TABLE
2
STYLE
0
STYLE
2
CAD
3
CADView Noto CJK.otf
0
ENDTAB
0
ENDSEC
0
SECTION
2
ENTITIES
0
TEXT
10
-1000
20
-1000
11
200
21
400
40
28
1
中文居中 Размер
7
CAD
41
0.75
72
1
0
TEXT
10
50
20
320
11
250
21
320
40
28
1
FIT 标注
72
5
0
TEXT
10
50
20
240
11
250
21
240
40
28
1
ALIGN
72
3
0
MTEXT
10
50
20
170
40
28
41
180
71
1
3
中文前段\\P
3
Размер\\P
1
日本語末段 العربية
50
15
0
ENDSEC
0
EOF
''';

String _pdfFixture() {
  const drawing = '0 0 1 rg 20 20 160 160 re f\n';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> /Contents 4 0 R >>',
    '<< /Length ${drawing.length} >>\nstream\n${drawing}endstream',
  ];
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 5\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write('trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return output.toString();
}

Future<Uint8List> _captureScene(
  WidgetTester tester,
  CadDocumentModel document, {
  bool export = false,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: OverflowBox(
          minWidth: 900,
          maxWidth: 900,
          minHeight: 1100,
          maxHeight: 1100,
          child: RepaintBoundary(
            key: key,
            child: CustomPaint(
              size: const Size(900, 1100),
              painter: CadScenePainter(
                document: document,
                zoom: 1,
                pan: Offset.zero,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final rgba = pixels!.buffer.asUint8List();
  var ink = 0;
  for (var pixel = 0; pixel < rgba.length; pixel += 4) {
    // Grid/background have channel maxima below 100; visible CAD entities do not.
    if (rgba[pixel] > 100 || rgba[pixel + 1] > 100 || rgba[pixel + 2] > 100) {
      ink++;
    }
  }
  expect(ink, greaterThan(50), reason: 'parsed document painted a blank scene');
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (export) {
    final capture = captureViewportPng(key, devicePixelRatio: 2);
    await tester.pump();
    return capture;
  }
  return png!.buffer.asUint8List();
}

bool _hasLine(CadDocumentModel document, Offset first, Offset second) {
  bool near(Map<String, dynamic> point, Offset expected) =>
      ((point['x'] as num).toDouble() - expected.dx).abs() < 0.02 &&
      ((point['y'] as num).toDouble() - expected.dy).abs() < 0.02;
  return document.entities.any((entity) {
    final geometry = entity['geometry'] as Map<String, dynamic>;
    if (geometry['kind'] != 'line') return false;
    final start = geometry['start'] as Map<String, dynamic>;
    final end = geometry['end'] as Map<String, dynamic>;
    return (near(start, first) && near(end, second)) ||
        (near(start, second) && near(end, first));
  });
}

bool _sameRaster(Uint8List first, Uint8List second) {
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i] != second[i]) return false;
  }
  return true;
}

void _expectVisibleRows(Uint8List rgba, int rowCount) {
  for (var row = 0; row < rowCount; row++) {
    final baseline = (136.4 + row * 70.4).round();
    var ink = 0;
    for (var y = baseline - 40; y <= baseline + 20; y++) {
      for (var x = 60; x < 860; x++) {
        final pixel = (y * 900 + x) * 4;
        if (rgba[pixel] > 200 &&
            rgba[pixel + 1] > 200 &&
            rgba[pixel + 2] > 200) {
          ink++;
        }
      }
    }
    expect(ink, greaterThan(20), reason: 'missing text row $row');
  }
}

String _dxfFixture() {
  final samples = [
    ...multilingualSamples.values,
    ...extendedMultilingualSamples.values,
  ];
  final pairs = <String>[
    '0',
    'SECTION',
    '2',
    'HEADER',
    '9',
    r'$ACADVER',
    '1',
    'AC1021',
    '9',
    r'$INSUNITS',
    '70',
    '4',
    '0',
    'ENDSEC',
    '0',
    'SECTION',
    '2',
    'ENTITIES',
    for (final coordinates in [
      [0, 0, 100, 100],
      [0, 100, 100, 0],
    ]) ...[
      '0',
      'LINE',
      '8',
      '0',
      '10',
      '${coordinates[0]}',
      '20',
      '${coordinates[1]}',
      '11',
      '${coordinates[2]}',
      '21',
      '${coordinates[3]}',
    ],
    for (var i = 0; i < samples.length; i++) ...[
      '0',
      'TEXT',
      '8',
      '0',
      '10',
      '20',
      '20',
      '${samples.length * 80 + 100 - i * 80}',
      '40',
      '28',
      '1',
      _escapedDxfText(samples[i]),
    ],
    '0',
    'ENDSEC',
    '0',
    'EOF',
  ];
  return '${pairs.join('\n')}\n';
}

String _escapedDxfText(String value) => value.codeUnits
    .map(
      (unit) => unit < 128
          ? String.fromCharCode(unit)
          : r'\U+' + unit.toRadixString(16).padLeft(4, '0'),
    )
    .join();
