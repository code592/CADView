import 'dart:io';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> columnText(String value, double x) => {
  'kind': 'text',
  'origin': {'x': x, 'y': 180.0},
  'value': value,
  'height': 10.0,
  'rotation': 0.0,
  'width_factor': 1.0,
  'horizontal_alignment': 'left',
  'vertical_alignment': 'top',
  'wrap_width': 100.0,
  'line_spacing': {'style': 'exact', 'factor': 1.0},
};

CadDocumentModel columnDocument(List<Map<String, dynamic>> geometries) =>
    CadDocumentModel.fromJson({
      'diagnostics': [],
      'metadata': {'format': 'dxf', 'display_name': 'columns.dxf'},
      'scene': {
        'scene_kind': 'two_d',
        'scene': {
          'layers': [
            {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
          ],
          'bounds': {
            'min': {'x': 0.0, 'y': 0.0},
            'max': {'x': 400.0, 'y': 240.0},
          },
          'entities': [
            for (var i = 0; i < geometries.length; i++)
              {
                'id': i + 1,
                'layer_id': 1,
                'color_argb': 0xffffffff,
                'geometry': geometries[i],
              },
          ],
        },
      },
    });

Future<Uint8List> columnRaster(
  WidgetTester tester,
  CadDocumentModel document, {
  Offset pan = Offset.zero,
}) async => (await tester.runAsync(() async {
  final recorder = ui.PictureRecorder();
  CadScenePainter(
    document: document,
    zoom: 1,
    pan: pan,
  ).paint(Canvas(recorder), const Size(800, 480));
  final picture = recorder.endRecording();
  final image = await picture.toImage(800, 480);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}))!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in cadFontAssets.entries) {
      final bytes = File(entry.value).readAsBytesSync();
      registerCadFontMetrics(entry.key, bytes);
      final loader = FontLoader(entry.key)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });

  testWidgets(
    'automatic multilingual columns match independently positioned paragraphs',
    (tester) async {
      const paragraphs = ['A中文\nB日本語', 'Cالعربية\nDবাংলা', 'Eहिन्दी\nF한국어'];
      for (final reversed in [false, true]) {
        final text = columnText(paragraphs.join('\n'), 30);
        text['columns'] = {
          'count': 3,
          'width': 100.0,
          'gutter': 20.0,
          'defined_height': 40.0,
          'heights': [],
          'flow_reversed': reversed,
          'auto_height': false,
          'manual_breaks': [],
        };
        final oracle = [
          for (var i = 0; i < 3; i++)
            columnText(paragraphs[i], 30.0 + (reversed ? 2 - i : i) * 120),
        ];
        final actual = await columnRaster(tester, columnDocument([text]));
        final expected = await columnRaster(tester, columnDocument(oracle));
        expect(
          actual,
          orderedEquals(expected),
          reason: 'Columns must preserve the same multilingual glyphs at the independent source positions',
        );
      }
    },
  );

  testWidgets(
    'column masks preserve gutter geometry and draw all glyphs after masks',
    (tester) async {
      final geometry = columnText('A\nB\nC\nD\nE\nF', 30);
      geometry['columns'] = {
        'count': 3,
        'width': 100.0,
        'gutter': 20.0,
        'defined_height': 40.0,
        'heights': [],
        'flow_reversed': false,
        'auto_height': false,
        'manual_breaks': [],
      };
      geometry['background'] = {
        'layout_supported': true,
        'fill': true,
        'frame': false,
        'scale': 1.0,
        'color_mode': 'explicit',
        'color_argb': 0xffff0000,
        'transparency': 0,
      };
      final line = {
        'kind': 'line',
        'start': {'x': 0.0, 'y': 160.0},
        'end': {'x': 400.0, 'y': 160.0},
      };
      final document = columnDocument([line, geometry]);
      final pixels = await columnRaster(tester, document);
      final transform = CadViewTransform.forScene(
        document,
        const Size(800, 480),
        1,
        Offset.zero,
      );
      List<int> pixelAt(double x, double y) {
        final screen = transform.worldToScreen(Offset(x, y));
        final index = (screen.dy.floor() * 800 + screen.dx.floor()) * 4;
        return pixels.sublist(index, index + 4);
      }

      expect(pixelAt(120, 160), [255, 0, 0, 255]);
      expect(
        pixelAt(140, 160)[1],
        greaterThan(100),
        reason: 'The background must not bridge the gap between columns',
      );
      expect(pixelAt(240, 160), [255, 0, 0, 255]);
      expect(pixelAt(260, 160)[1], greaterThan(100));
    },
  );

  testWidgets(
    'column tail is painted when the insertion point is outside the viewport',
    (tester) async {
      final geometry = columnText('A\nB\nC\nD\nE\nF', 30);
      geometry['columns'] = {
        'count': 3,
        'width': 100.0,
        'gutter': 20.0,
        'defined_height': 40.0,
        'heights': [],
        'flow_reversed': false,
        'auto_height': false,
        'manual_breaks': [],
      };
      const pan = Offset(-450, 0);
      final actual = await columnRaster(
        tester,
        columnDocument([geometry]),
        pan: pan,
      );
      final expected = await columnRaster(
        tester,
        columnDocument([
          columnText('A\nB', 30),
          columnText('C\nD', 150),
          columnText('E\nF', 270),
        ]),
        pan: pan,
      );
      expect(actual, orderedEquals(expected));
    },
  );
}
