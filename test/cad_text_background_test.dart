import 'dart:io';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> maskGeometry({
  bool canvas = false,
  bool frame = false,
  bool fill = true,
  int color = 0xffff0000,
}) => {
  'kind': 'text',
  'origin': {'x': 150.0, 'y': 100.0},
  'value': '中文',
  'height': 30.0,
  'rotation': 0.0,
  'horizontal_alignment': 'left',
  'vertical_alignment': 'top',
  'background': {
    'fill': fill,
    'frame': frame,
    'scale': 1.5,
    'color_mode': canvas ? 'canvas' : 'explicit',
    'color_argb': color,
    'transparency': 0,
  },
};

CadDocumentModel maskDocument({
  bool lineAfter = false,
  bool canvas = false,
  bool frame = false,
  bool fill = true,
  int color = 0xffff0000,
  int ink = 0xffffffff,
}) {
  final line = <String, dynamic>{
    'id': 1,
    'layer_id': 1,
    'color_argb': 0xff0000ff,
    'geometry': {
      'kind': 'line',
      // Fit scale is 0.88; align this line with pixel centre y=91.5 so
      // assertions test mask/order, not fractional stroke antialiasing.
      'start': {'x': 0.0, 'y': 100 + 8.5 / 0.88},
      'end': {'x': 300.0, 'y': 100 + 8.5 / 0.88},
    },
  };
  final text = <String, dynamic>{
    'id': 2,
    'layer_id': 1,
    'color_argb': ink,
    'geometry': maskGeometry(
      canvas: canvas,
      frame: frame,
      fill: fill,
      color: color,
    ),
  };
  return CadDocumentModel.fromJson({
    'diagnostics': [],
    'metadata': {'format': 'dxf', 'display_name': 'mask.dxf'},
    'scene': {
      'scene_kind': 'two_d',
      'scene': {
        'layers': [
          {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
        ],
        'bounds': {
          'min': {'x': 0.0, 'y': 0.0},
          'max': {'x': 300.0, 'y': 200.0},
        },
        'entities': lineAfter ? [text, line] : [line, text],
      },
    },
  });
}

Future<Uint8List> raster(
  WidgetTester tester,
  CadDocumentModel document,
) async => (await tester.runAsync(() async {
  final recorder = ui.PictureRecorder();
  CadScenePainter(
    document: document,
    zoom: 1,
    pan: Offset.zero,
  ).paint(Canvas(recorder), const Size(300, 200));
  final picture = recorder.endRecording();
  final image = await picture.toImage(300, 200);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}))!;

List<int> pixel(Uint8List pixels, int x, int y) =>
    pixels.sublist((y * 300 + x) * 4, (y * 300 + x) * 4 + 4);

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

  test('mask margin uses nominal height, independently of width factor', () {
    final geometry = maskGeometry()..['width_factor'] = 0.5;
    expect(
      cadTextBackgroundRect(geometry, const Rect.fromLTWH(20, 30, 200, 100)),
      const Rect.fromLTRB(-108, -34, 348, 194),
    );
    (geometry['background'] as Map)['scale'] = 1.0;
    expect(
      cadTextBackgroundRect(geometry, const Rect.fromLTWH(20, 30, 200, 100)),
      const Rect.fromLTWH(20, 30, 200, 100),
    );
  });

  testWidgets('mask hides only earlier geometry and preserves later geometry', (
    tester,
  ) async {
    final before = await raster(tester, maskDocument());
    expect(pixel(before, 150, 91), [255, 0, 0, 255]);
    expect(pixel(before, 50, 91)[2], greaterThan(200));
    final after = await raster(tester, maskDocument(lineAfter: true));
    expect(pixel(after, 150, 91)[2], greaterThan(200));
    expect(pixel(after, 150, 91)[0], lessThan(80));
  });

  testWidgets(
    'canvas mask removes grid and frame-only does not hide geometry',
    (tester) async {
      final canvas = await raster(tester, maskDocument(canvas: true));
      expect(pixel(canvas, 150, 91), [7, 16, 23, 255]);
      final frame = await raster(
        tester,
        maskDocument(fill: false, frame: true),
      );
      expect(pixel(frame, 150, 91)[2], greaterThan(200));
      expect(
        [
          pixel(frame, 170, 86)[0],
          pixel(frame, 170, 87)[0],
        ].reduce((a, b) => a > b ? a : b),
        greaterThan(150),
        reason: 'The frame must be drawn even without a fill',
      );
    },
  );

  testWidgets(
    'explicit white mask retains black glyph ink instead of making it white',
    (tester) async {
      final pixels = await raster(
        tester,
        maskDocument(color: 0xffffffff, ink: 0xff000000),
      );
      var black = 0;
      for (var y = 100; y < 155; y++) {
        for (var x = 150; x < 245; x++) {
          final rgb = pixel(pixels, x, y);
          if (rgb[0] < 8 && rgb[1] < 8 && rgb[2] < 8) black++;
        }
      }
      expect(black, greaterThan(30));
    },
  );

  test(
    'offscreen mask border is included in world and screen culling envelopes',
    () {
      final geometry = maskGeometry();
      (geometry['background'] as Map)['scale'] = 5.0;
      final transform = CadViewTransform.forScene(
        maskDocument(),
        const Size(300, 200),
        1,
        Offset.zero,
      );
      final withMask = cadTextScreenBounds(geometry, transform);
      final withoutMask = cadTextScreenBounds({
        ...geometry,
        'background': null,
      }, transform);
      expect(withMask.left, lessThan(withoutMask.left - 80));
      expect(withMask.top, lessThan(withoutMask.top - 80));
      expect(
        cadTextWorldBounds(geometry).width,
        greaterThan(
          cadTextWorldBounds({...geometry, 'background': null}).width + 160,
        ),
      );
    },
  );
}
