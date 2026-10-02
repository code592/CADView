import 'dart:ui' as ui;

import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/core/image_export.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multilingual_fixture.dart';

void main() {
  test('PNG name preserves Unicode and removes only the final extension', () {
    expect(imageExportFileName('R20-0000_1.dxf'), 'R20-0000_1.png');
    expect(imageExportFileName('图框.v2.DWG'), '图框.v2.png');
    expect(imageExportFileName(''), 'drawing.png');
    expect(imageExportFileName('../file.dxf'), '.._file.png');
  });

  test('export uses at least 2x detail with bounded readback memory', () {
    expect(imageExportPixelRatio(const Size(400, 800), 1), 2);
    expect(imageExportPixelRatio(const Size(400, 800), 3), 3);
    for (final size in [const Size(1024, 1366), const Size(4000, 8000)]) {
      final ratio = imageExportPixelRatio(size, 4);
      expect(size.longestSide * ratio, lessThanOrEqualTo(4096));
      expect(
        size.width * size.height * ratio * ratio,
        lessThanOrEqualTo(8 * 1024 * 1024 + 1),
      );
    }
    expect(() => imageExportPixelRatio(Size.zero, 2), throwsStateError);
  });

  test(
    'export rejects invalid sizes and safely handles unusual pixel ratios',
    () {
      for (final size in [
        const Size(-1, 80),
        const Size(double.infinity, 80),
        const Size(100, double.nan),
      ]) {
        expect(() => imageExportPixelRatio(size, 2), throwsStateError);
      }
      for (final ratio in [double.nan, double.infinity, -1.0, 0.0]) {
        expect(imageExportPixelRatio(const Size(100, 80), ratio), 2);
      }
      final ratio = imageExportPixelRatio(
        const Size(double.maxFinite, double.maxFinite),
        3,
      );
      expect(ratio, greaterThan(0));
      expect(ratio.isFinite, isTrue);
      final edge = double.maxFinite * ratio;
      expect(edge * edge, lessThanOrEqualTo(8 * 1024 * 1024 + 1));
    },
  );

  testWidgets('export fails safely when the viewport is no longer mounted', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: const SizedBox(width: 100, height: 80)),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    final result = expectLater(
      captureViewportPng(key, devicePixelRatio: 2),
      throwsStateError,
    );
    await tester.pump();
    await result;
    expect(tester.takeException(), isNull);
  });

  testWidgets('export rejects a key that is not a capture boundary', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(SizedBox(key: key, width: 100, height: 80));
    final result = expectLater(
      captureViewportPng(key, devicePixelRatio: 2),
      throwsStateError,
    );
    await tester.pump();
    await result;
    expect(tester.takeException(), isNull);
  });

  testWidgets('captures just the viewport as a decodable PNG', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: 100,
              height: 80,
              child: ColoredBox(color: Colors.red),
            ),
          ),
        ),
      ),
    );
    final capture = captureViewportPng(key, devicePixelRatio: 2);
    await tester.pump();
    final bytes = await tester.runAsync(() => capture);
    expect(bytes!.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await tester.runAsync(() => ui.instantiateImageCodec(bytes));
    final frame = await tester.runAsync(() => codec!.getNextFrame());
    expect(frame!.image.width, 200);
    expect(frame.image.height, 160);
    final pixels = await tester.runAsync(
      () => frame.image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    expect(pixels!.buffer.asUint8List().take(4).toList(), [244, 67, 54, 255]);
    frame.image.dispose();
    codec!.dispose();
  });

  testWidgets('CAD PNG retains annotations and excludes surrounding controls', (
    tester,
  ) async {
    final key = GlobalKey();
    final document = multilingualCadDocument();
    const viewportSize = Size(320, 400);
    const anchor = Offset(450, 550);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 320,
                height: 40,
                child: ColoredBox(color: Color(0xffff00ff)),
              ),
              RepaintBoundary(
                key: key,
                child: SizedBox.fromSize(
                  size: viewportSize,
                  child: CustomPaint(
                    painter: CadScenePainter(
                      document: document,
                      zoom: 1,
                      pan: Offset.zero,
                      annotations: const [
                        CadTextAnnotation(
                          id: 'export-note',
                          value: 'PNG annotation',
                          x: 450,
                          y: 550,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final capture = captureViewportPng(key, devicePixelRatio: 2);
    await tester.pump();
    final bytes = await tester.runAsync(() => capture);
    final codec = await tester.runAsync(() => ui.instantiateImageCodec(bytes!));
    final frame = await tester.runAsync(() => codec!.getNextFrame());
    try {
      expect(frame!.image.width, 640);
      expect(frame.image.height, 800);
      final data = await tester.runAsync(
        () => frame.image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final pixels = data!.buffer.asUint8List();
      final point = CadViewTransform.forScene(
        document,
        viewportSize,
        1,
        Offset.zero,
      ).worldToScreen(anchor);
      final index = ((point.dy * 2).floor() * 640 + (point.dx * 2).floor()) * 4;
      expect(pixels.sublist(index, index + 4), [255, 204, 0, 255]);
      var containsChrome = false;
      for (var pixel = 0; pixel < pixels.length; pixel += 4) {
        if (pixels[pixel] == 255 &&
            pixels[pixel + 1] == 0 &&
            pixels[pixel + 2] == 255) {
          containsChrome = true;
          break;
        }
      }
      expect(
        containsChrome,
        isFalse,
        reason: 'Application chrome leaked into the exported viewport',
      );
    } finally {
      frame!.image.dispose();
      codec!.dispose();
    }
  });

  testWidgets('PNG preserves the current zoom and pan without resetting view', (
    tester,
  ) async {
    final key = GlobalKey();
    final document = multilingualCadDocument();
    const size = Size(320, 400);
    const pan = Offset(30, -20);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox.fromSize(
              size: size,
              child: CustomPaint(
                painter: CadScenePainter(
                  document: document,
                  zoom: 2,
                  pan: pan,
                  annotations: const [
                    CadTextAnnotation(
                      id: 'view-note',
                      value: 'Current view',
                      x: 450,
                      y: 550,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final capture = captureViewportPng(key, devicePixelRatio: 2);
    await tester.pump();
    final bytes = await tester.runAsync(() => capture);
    final codec = await tester.runAsync(() => ui.instantiateImageCodec(bytes!));
    final frame = await tester.runAsync(() => codec!.getNextFrame());
    try {
      final data = await tester.runAsync(
        () => frame!.image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final pixels = data!.buffer.asUint8List();
      List<int> pixelAt(int x, int y) {
        final index = (y * 2 * frame!.image.width + x * 2) * 4;
        return pixels.sublist(index, index + 4);
      }

      // The world-centre anchor stays at the viewport centre under zoom, then
      // moves by the current pan. Verify pixels, not just PNG headers.
      expect(pixelAt(190, 180), [255, 204, 0, 255]);
      expect(pixelAt(160, 200), isNot([255, 204, 0, 255]));
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is CustomPaint &&
                          widget.painter is CadScenePainter,
                    ),
                  )
                  .painter!
              as CadScenePainter;
      expect(painter.zoom, 2);
      expect(painter.pan, pan);
      expect(tester.takeException(), isNull);
    } finally {
      frame!.image.dispose();
      codec!.dispose();
    }
  });

  testWidgets('3D PNG retains the current viewing angle', (tester) async {
    final key = GlobalKey();
    final document = CadDocumentModel(
      format: 'stl',
      displayName: 'triangle.stl',
      sceneKind: 'three_d',
      diagnostics: const [],
      scene: {
        'meshes': [
          {
            'id': 7,
            'positions': [
              {'x': -1, 'y': -1, 'z': 0},
              {'x': 1, 'y': -1, 'z': 0},
              {'x': 0, 'y': 1, 'z': 0},
            ],
            'indices': [0, 1, 2],
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
    );
    Future<List<int>> capture(double yaw, double pitch) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 200,
                height: 200,
                child: CustomPaint(
                  painter: CadScenePainter(
                    document: document,
                    zoom: 1.5,
                    pan: const Offset(12, -8),
                    yaw: yaw,
                    pitch: pitch,
                    annotations: const [],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final pending = captureViewportPng(key, devicePixelRatio: 2);
      await tester.pump();
      final bytes = await tester.runAsync(() => pending);
      final codec = await tester.runAsync(
        () => ui.instantiateImageCodec(bytes!),
      );
      final frame = await tester.runAsync(() => codec!.getNextFrame());
      try {
        expect(frame!.image.width, 400);
        expect(frame.image.height, 400);
        final pixels = await tester.runAsync(
          () => frame.image.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final painter =
            tester
                    .widget<CustomPaint>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is CustomPaint &&
                            widget.painter is CadScenePainter,
                      ),
                    )
                    .painter!
                as CadScenePainter;
        expect(painter.yaw, yaw);
        expect(painter.pitch, pitch);
        expect(painter.zoom, 1.5);
        expect(painter.pan, const Offset(12, -8));
        return pixels!.buffer.asUint8List().toList();
      } finally {
        frame!.image.dispose();
        codec!.dispose();
      }
    }

    final originalView = await capture(-0.75, 0.55);
    final rotatedView = await capture(0.4, 1.1);
    expect(rotatedView, isNot(orderedEquals(originalView)));
    expect(tester.takeException(), isNull);
  });
}
