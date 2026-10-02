import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/core/sheet_export.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
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
      ],
    },
  },
});

void main() {
  test('frames are parsed from document metadata', () {
    final frame = _sheetDocument().frames.single;
    expect(frame.bounds, const Rect.fromLTRB(0, 0, 841, 594));
    expect(frame.paper, 'A1');
    expect(frame.scale, 1.0);
  });

  test('sheet rasters keep the frame proportions within memory limits', () {
    final a1 = sheetRasterSize(const Rect.fromLTWH(0, 0, 841, 594));
    expect(a1.width, 4096);
    expect(a1.height, closeTo(4096 * 594 / 841, 1));
    expect(a1.width * a1.height, lessThanOrEqualTo(12 * 1024 * 1024));
    final portrait = sheetRasterSize(const Rect.fromLTWH(0, 0, 210, 297));
    expect(portrait.height, 4096);
    final capped = sheetRasterSize(
      const Rect.fromLTWH(0, 0, 100, 100),
      maxPixels: 1000000,
    );
    expect(capped.width * capped.height, lessThanOrEqualTo(1000000));
    expect(
      () => sheetRasterSize(const Rect.fromLTWH(0, 0, 0, 10)),
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
    final unknown = sheetPageSizePoints(const Rect.fromLTWH(0, 0, 300, 100));
    expect(unknown.width, closeTo(420 * 72 / 25.4, 1e-6));
    expect(unknown.height, closeTo(unknown.width / 3, 1e-6));
  });

  test('the PDF writer produces consistent objects and cross references', () {
    final pixels = Uint8List.fromList(List.filled(2 * 2 * 3, 200));
    final pages = [
      for (final size in [(600.0, 400.0), (300.0, 200.0)])
        PdfRasterPage(
          pixelWidth: 2,
          pixelHeight: 2,
          deflatedRgb: Uint8List.fromList(ZLibCodec().encode(pixels)),
          widthPoints: size.$1,
          heightPoints: size.$2,
        ),
    ];
    final bytes = buildRasterPdf(pages);
    final text = latin1.decode(bytes);
    expect(text.startsWith('%PDF-1.4'), isTrue);
    expect(text, contains('/Count 2'));
    expect(text, contains('/MediaBox [0 0 600.000 400.000]'));
    expect(text, contains('/MediaBox [0 0 300.000 200.000]'));
    expect(text.trimRight().endsWith('%%EOF'), isTrue);
    // Every xref entry points at the start of its object.
    final startxref = int.parse(
      RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!,
    );
    expect(text.substring(startxref).startsWith('xref'), isTrue);
    final entries = RegExp(r'(\d{10}) 00000 n')
        .allMatches(text.substring(startxref))
        .toList();
    expect(entries, hasLength(2 + pages.length * 3));
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

  testWidgets('a sheet is rendered edge to edge at its own proportions', (
    tester,
  ) async {
    final document = _sheetDocument();
    final frame = document.frames.single;
    final image = (await tester.runAsync(
      () => renderSheetImage(
        document,
        frame.bounds,
        maxEdge: 3364,
        maxPixels: 4 * 1024 * 1024,
      ),
    ))!;
    expect(image.width, closeTo(image.height * 841 / 594, 2));
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final pixels = data.buffer.asUint8List();
    // Within 1% of the image edge (the 0.5% border margin plus stroke).
    bool redNear(int x, int y) {
      for (var dy = -24; dy <= 24; dy++) {
        for (var dx = -24; dx <= 24; dx++) {
          final px = (x + dx).clamp(0, image.width - 1);
          final py = (y + dy).clamp(0, image.height - 1);
          final at = (py * image.width + px) * 4;
          if (pixels[at] > 180 && pixels[at + 1] < 120) return true;
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
    expect(redNear(image.width ~/ 2, image.height ~/ 2), isFalse);
    image.dispose();
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
