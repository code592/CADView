import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:cad_view/features/viewer/cad_scene_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CadDocumentModel _grid() => CadDocumentModel.fromJson({
  'diagnostics': <Object>[],
  'metadata': {'format': 'dxf', 'display_name': 'grid.dxf'},
  'scene': {
    'scene_kind': 'two_d',
    'scene': {
      'layers': [
        {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
      ],
      'bounds': {
        'min': {'x': 0.0, 'y': 0.0},
        'max': {'x': 100.0, 'y': 100.0},
      },
      'entities': [
        for (var i = 0; i <= 10; i++) ...[
          {
            'id': i * 2 + 1,
            'layer_id': 1,
            'color_argb': 0xffff0000,
            'stroke_width': 0.0,
            'filled': false,
            'geometry': {
              'kind': 'line',
              'start': {'x': i * 10.0, 'y': 0.0},
              'end': {'x': i * 10.0, 'y': 100.0},
            },
          },
          {
            'id': i * 2 + 2,
            'layer_id': 1,
            'color_argb': 0xff00ff00,
            'stroke_width': 0.0,
            'filled': false,
            'geometry': {
              'kind': 'line',
              'start': {'x': 0.0, 'y': i * 10.0},
              'end': {'x': 100.0, 'y': i * 10.0},
            },
          },
        ],
      ],
    },
  },
});

const _size = Size(300, 200);

Future<Uint8List> _pixels(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(300, 200);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// Pixels with red or green ink of at least [level].
Set<int> _ink(Uint8List pixels, [int level = 120]) => {
  for (var i = 0; i < pixels.length; i += 4)
    if (pixels[i] > level || pixels[i + 1] > level) i ~/ 4,
};

/// Fraction of [ink] pixels within two pixels of a [reference] pixel.
double _near(Set<int> ink, Set<int> reference) {
  var near = 0;
  for (final pixel in ink) {
    final x = pixel % 300, y = pixel ~/ 300;
    search:
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (reference.contains((y + dy) * 300 + x + dx)) {
          near++;
          break search;
        }
      }
    }
  }
  return near / ink.length;
}

void main() {
  test(
    'a snapshot moved with the camera lines up with exact drawing',
    () async {
      final document = _grid();
      final painter = CadScenePainter(
        document: document,
        zoom: 1,
        pan: Offset.zero,
      );
      final snapshot = await CadSceneSnapshot.capture(painter, _size, 1);
      for (final (zoom, pan) in [
        (1.0, const Offset(37, -21)),
        (2.0, const Offset(-60, 15)),
        (0.7, const Offset(12, 9)),
      ]) {
        final exactPixels = await _pixels(
          (canvas) => CadScenePainter(
            document: document,
            zoom: zoom,
            pan: pan,
          ).paint(canvas, _size),
        );
        final movedPixels = await _pixels(
          (canvas) => CadSnapshotPainter(
            snapshot,
            zoom: zoom,
            pan: pan,
          ).paint(canvas, _size),
        );
        final exact = _ink(exactPixels);
        final moved = _ink(movedPixels);
        // Resampling blurs and magnified cosmetic lines thicken, but every
        // stroke must lie where the exact one is (within two pixels).
        // Compare where the snapshot has content: its padded area moved
        // with the camera (zooming out reveals an empty margin).
        final center = _size.center(Offset.zero);
        Offset map(Offset point) => center + pan + (point - center) * zoom;
        final covered = Rect.fromPoints(
          map(const Offset(-75, -50)),
          map(const Offset(375, 250)),
        ).deflate(3);
        bool inside(int pixel) =>
            covered.contains(Offset(pixel % 300 + 0.5, pixel ~/ 300 + 0.5));
        final exactCovered = exact.where(inside).toSet();
        final movedCovered = moved.where(inside).toSet();
        expect(exactCovered.length, greaterThan(500));
        // Downsampled lines are fainter: match against fainter ink too.
        expect(
          _near(exactCovered, _ink(movedPixels, 40)),
          greaterThan(0.95),
          reason: '$zoom $pan',
        );
        expect(
          _near(movedCovered, _ink(exactPixels, 40)),
          greaterThan(0.95),
          reason: '$zoom $pan',
        );
      }
      snapshot.dispose();
    },
  );

  test('a snapshot only stands in for the same scene', () async {
    final document = _grid();
    final painter = CadScenePainter(
      document: document,
      zoom: 1,
      pan: Offset.zero,
    );
    final snapshot = await CadSceneSnapshot.capture(painter, _size, 2);
    expect(snapshot.image.width, 450 * 2);
    final moved = CadScenePainter(
      document: document,
      zoom: 3,
      pan: const Offset(5, 5),
    );
    expect(snapshot.matches(moved, _size), isTrue);
    expect(snapshot.sameCamera(moved), isFalse);
    expect(
      snapshot.canPanTo(moved, _size),
      isFalse,
      reason: 'zoom must re-render fine geometry, text and cosmetic widths',
    );
    for (final pan in [const Offset(73, -48), const Offset(-73, 48)]) {
      expect(
        snapshot.canPanTo(
          CadScenePainter(document: document, zoom: 1, pan: pan),
          _size,
        ),
        isTrue,
      );
    }
    for (final pan in [
      const Offset(76, 0),
      const Offset(0, -51),
      const Offset(300, 200),
    ]) {
      expect(
        snapshot.canPanTo(
          CadScenePainter(document: document, zoom: 1, pan: pan),
          _size,
        ),
        isFalse,
        reason: 'a fast pan must not reveal an uncaptured blank strip',
      );
    }
    expect(snapshot.matches(moved, const Size(300, 201)), isFalse);
    expect(
      snapshot.matches(
        CadScenePainter(
          document: document,
          zoom: 1,
          pan: Offset.zero,
          selectedEntityIds: {BigInt.one},
        ),
        _size,
      ),
      isFalse,
    );
    expect(
      snapshot.matches(
        CadScenePainter(document: _grid(), zoom: 1, pan: Offset.zero),
        _size,
      ),
      isFalse,
    );
    snapshot.dispose();
  });
}
