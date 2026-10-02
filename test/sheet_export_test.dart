import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/core/sheet_export.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CadDocumentModel _sheetDocument() => CadDocumentModel.fromJson({
  'diagnostics': <Object>[],
  'metadata': {
    'format': 'dwg',
    'display_name': 'frames.dwg',
    'frames': [
      {
        'bounds': {
          'min': {'x': 0.0, 'y': 0.0},
          'max': {'x': 841.0, 'y': 594.0},
        },
        'paper': 'A1',
        'scale': 1.0,
      },
    ],
  },
  'scene': {
    'scene_kind': 'two_d',
    'scene': {
      'layers': [
        {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
      ],
      'bounds': {
        'min': {'x': -500.0, 'y': -500.0},
        'max': {'x': 3000.0, 'y': 3000.0},
      },
      'entities': [
        {
          'id': 1,
          'layer_id': 1,
          'color_argb': 0xffff0000,
          'stroke_width': 0.0,
          'filled': false,
          'geometry': {
            'kind': 'polyline',
            'closed': true,
            'points': [
              {'x': 0.0, 'y': 0.0},
              {'x': 841.0, 'y': 0.0},
              {'x': 841.0, 'y': 594.0},
              {'x': 0.0, 'y': 594.0},
            ],
          },
        },
        {
          'id': 2,
          'layer_id': 1,
          'color_argb': 0xff00ff00,
          'stroke_width': 0.0,
          'filled': false,
          'dash': [20.0, -10.0],
          'geometry': {
            'kind': 'line',
            'start': {'x': 100.0, 'y': 297.0},
            'end': {'x': 741.0, 'y': 297.0},
          },
        },
      ],
    },
  },
});

CadSheetRaster _sheet(double dpi) {
  final document = _sheetDocument();
  final frame = document.frames.single;
  final paper = sheetPaperSizeMillimetres(frame.bounds, scale: frame.scale);
  return CadSheetRaster.prepare(
    document,
    frame.bounds,
    paperWidthMm: paper.width,
    paperHeightMm: paper.height,
    dpi: dpi,
  );
}

Future<Uint8List> _rgba(WidgetTester tester, ui.Image image) async =>
    (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!.buffer.asUint8List();

void main() {
  test('frames are parsed from document metadata', () {
    final frame = _sheetDocument().frames.single;
    expect(frame.bounds, const Rect.fromLTRB(0, 0, 841, 594));
    expect(frame.paper, 'A1');
    expect(frame.scale, 1.0);
  });

  test('sheets are sized from their paper and resolution', () {
    final pdf = _sheet(sheetPdfDpi);
    expect(pdf.width, (841 / 25.4 * 300).round());
    expect(pdf.height, (594 / 25.4 * 300).round());
    // Lines plot at a fixed paper width: 0.2 mm per logical pixel.
    expect(pdf.ratio, closeTo(300 / 25.4 * 0.2, 1e-9));
    final tiles = pdf.tiles().toList();
    expect(tiles, hasLength(5 * 4));
    expect(
      tiles.every((tile) => tile.width <= 2048 && tile.height <= 2048),
      isTrue,
    );
    expect(
      tiles.fold<int>(0, (sum, tile) => sum + tile.width * tile.height),
      pdf.width * pdf.height,
    );
    final unknown = sheetPaperSizeMillimetres(
      const Rect.fromLTWH(0, 0, 300, 100),
    );
    expect(unknown.width, 420);
    expect(unknown.height, closeTo(140, 1e-9));
    expect(
      () => CadSheetRaster.prepare(
        _sheetDocument(),
        const Rect.fromLTWH(0, 0, 0, 10),
        paperWidthMm: 420,
        paperHeightMm: 297,
        dpi: 100,
      ),
      throwsStateError,
    );
  });

  test('pages are sized to the detected sheet like the plotted PDF', () {
    // The reference plot's A1 page for an 831 × 584.03 border is 2356 × 1655.
    final a1 = sheetPageSizePoints(
      const Rect.fromLTWH(790.64, 1594.94, 831.0, 584.03),
      scale: 1,
    );
    expect(a1.width, closeTo(2356, 1));
    expect(a1.height, closeTo(1655, 1));
    final scaled = sheetPageSizePoints(
      const Rect.fromLTWH(0, 0, 42000, 29700),
      scale: 100,
    );
    expect(scaled.width, closeTo(420 * 72 / 25.4, 1e-6));
  });

  test('the PDF writer produces consistent objects and cross references', () {
    final pixels = Uint8List.fromList(List.filled(2 * 2 * 3, 200));
    PdfImageTile tile(double x, double y) => PdfImageTile(
      pixelWidth: 2,
      pixelHeight: 2,
      deflatedRgb: Uint8List.fromList(ZLibCodec().encode(pixels)),
      x: x,
      y: y,
      width: 300,
      height: 200,
    );
    final pages = [
      PdfRasterPage(
        widthPoints: 600,
        heightPoints: 400,
        tiles: [tile(0, 0), tile(300, 0), tile(0, 200), tile(300, 200)],
      ),
      PdfRasterPage(widthPoints: 300, heightPoints: 200, tiles: [tile(0, 0)]),
    ];
    final text = latin1.decode(buildRasterPdf(pages));
    expect(text.startsWith('%PDF-1.4'), isTrue);
    expect(text, contains('/Count 2'));
    expect(text, contains('/MediaBox [0 0 600.000 400.000]'));
    expect(text, contains('/MediaBox [0 0 300.000 200.000]'));
    expect(
      text,
      contains('q 300.000 0 0 200.000 300.000 200.000 cm /Im3 Do Q'),
    );
    expect(text.trimRight().endsWith('%%EOF'), isTrue);
    // Every xref entry points at the start of its object.
    final startxref = int.parse(
      RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!,
    );
    expect(text.substring(startxref).startsWith('xref'), isTrue);
    final entries = RegExp(r'(\d{10}) 00000 n')
        .allMatches(text.substring(startxref))
        .toList();
    // Catalog, pages, then page + contents + one image per tile.
    expect(entries, hasLength(2 + (2 + 4) + (2 + 1)));
    for (var i = 0; i < entries.length; i++) {
      final offset = int.parse(entries[i].group(1)!);
      expect(text.substring(offset).startsWith('${i + 1} 0 obj'), isTrue);
    }
    // Stream lengths match their data.
    for (final match in RegExp(
      r'/Length (\d+) >>\nstream\n',
    ).allMatches(text)) {
      final length = int.parse(match.group(1)!);
      expect(
        text.substring(match.end + length).startsWith('\nendstream'),
        isTrue,
      );
    }
  });

  testWidgets('tiles join seamlessly into one sheet', (tester) async {
    final sheet = _sheet(60);
    final half = sheet.width ~/ 2;
    final whole = (await tester.runAsync(
      () => sheet.renderTile(0, 0, sheet.width, sheet.height),
    ))!;
    final left = (await tester.runAsync(
      () => sheet.renderTile(0, 0, half, sheet.height),
    ))!;
    final right = (await tester.runAsync(
      () => sheet.renderTile(half, 0, sheet.width - half, sheet.height),
    ))!;
    final a = await _rgba(tester, whole);
    final b = await _rgba(tester, left);
    final c = await _rgba(tester, right);
    var mismatched = 0;
    for (var y = 0; y < sheet.height; y++) {
      for (var x = 0; x < sheet.width; x++) {
        final inLeft = x < half;
        final tile = inLeft ? b : c;
        final at = inLeft
            ? (y * half + x) * 4
            : (y * (sheet.width - half) + x - half) * 4;
        for (var channel = 0; channel < 3; channel++) {
          if ((a[(y * sheet.width + x) * 4 + channel] - tile[at + channel])
                  .abs() >
              2) {
            mismatched++;
          }
        }
      }
    }
    // Only antialiasing differences where a stroke crosses the seam.
    expect(mismatched, lessThan(sheet.height * 3 ~/ 10));
    for (final image in [whole, left, right]) {
      image.dispose();
    }
  });

  testWidgets('streamed sheet PNG decodes with border and dashed line', (
    tester,
  ) async {
    // 80 dpi A1 spans two tile bands across.
    final sheet = _sheet(80);
    expect(sheet.width, greaterThan(sheetTileSize));
    final png = (await tester.runAsync(() => encodeSheetPng(sheet)))!;
    expect(png.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = (await tester.runAsync(() => ui.instantiateImageCodec(png)))!;
    final image = (await tester.runAsync(() => codec.getNextFrame()))!.image;
    expect((image.width, image.height), (sheet.width, sheet.height));
    final pixels = await _rgba(tester, image);
    bool redNear(int x, int y) {
      for (var dy = -24; dy <= 24; dy++) {
        for (var dx = -24; dx <= 24; dx++) {
          final px = (x + dx).clamp(0, image.width - 1);
          final py = (y + dy).clamp(0, image.height - 1);
          final at = (py * image.width + px) * 4;
          if (pixels[at] > 90 && pixels[at] > pixels[at + 1] * 2) return true;
        }
      }
      return false;
    }

    // The red sheet border lies along all four image edges.
    expect(redNear(image.width ~/ 2, 0), isTrue, reason: 'top');
    expect(
      redNear(image.width ~/ 2, image.height - 1),
      isTrue,
      reason: 'bottom',
    );
    expect(redNear(0, image.height ~/ 2), isTrue, reason: 'left');
    expect(
      redNear(image.width - 1, image.height ~/ 2),
      isTrue,
      reason: 'right',
    );
    // The dashed green line: 20 on, 10 off.
    final y = image.height ~/ 2;
    var ink = 0, gaps = 0;
    for (var x = image.width ~/ 4; x < image.width * 3 ~/ 4; x++) {
      var hit = false;
      for (var dy = -3; dy <= 3 && !hit; dy++) {
        final at = ((y + dy) * image.width + x) * 4;
        hit = pixels[at + 1] > 60 && pixels[at + 1] > pixels[at] * 2;
      }
      hit ? ink++ : gaps++;
    }
    expect(ink, greaterThan(0));
    expect(gaps / (ink + gaps), closeTo(1 / 3, 0.08));
    image.dispose();
    codec.dispose();
  });

  test('dash paths follow the pattern and restart per contour', () {
    final source = Path()
      ..moveTo(0, 0)
      ..lineTo(100, 0)
      ..moveTo(0, 10)
      ..lineTo(25, 10);
    final dashed = cadDashPath(source, const [20, -10]);
    // Dashes at 0, 30, 60 and 90 (clipped to 10); the second contour
    // restarts the pattern.
    expect(
      [for (final metric in dashed.computeMetrics()) metric.length.round()],
      [20, 20, 20, 10, 20],
    );
    final dots = cadDashPath(
      Path()
        ..moveTo(0, 0)
        ..lineTo(30, 0),
      const [0, -10],
    );
    expect(dots.computeMetrics().length, 3);
    expect(cadDashPath(source, const [5]).computeMetrics().length, 2);
  });

  test('sheet file names keep the drawing name, index and paper', () {
    expect(
      sheetExportFileName('A1、A2、A3图框.dwg', 2, 'A2', 'png'),
      'A1、A2、A3图框-2-A2.png',
    );
    expect(sheetExportFileName('plan.dxf', 1, null, 'png'), 'plan-1.png');
    expect(documentExportFileName('A1、A2、A3图框.dwg', 'pdf'), 'A1、A2、A3图框.pdf');
  });
}
