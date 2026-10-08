import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'cad_scene_painter.dart';

/// A raster of a 2D scene shown while the camera moves. Redrawing a large
/// drawing for every gesture frame is what made panning and pinching heavy;
/// between gesture frames only the camera changes, so the last exact
/// rendering is scaled and translated instead, and the scene is drawn
/// exactly again when the gesture ends or pauses.
class CadSceneSnapshot {
  CadSceneSnapshot._(this.image, this.painter, this.size, this.padding);

  /// Content beyond each screen edge kept for panning, as a fraction of the
  /// viewport size.
  static const double paddingFraction = 0.25;

  /// Raster pixel budget of one snapshot (about 48 MB).
  static const int maxPixels = 12 * 1024 * 1024;

  final ui.Image image;

  /// The painter (and so camera) the snapshot was rendered with.
  final CadScenePainter painter;
  final Size size;
  final Offset padding;

  /// Whether this snapshot shows [current]'s scene on a [size] canvas,
  /// whatever the camera.
  bool matches(CadScenePainter current, Size size) =>
      size == this.size && painter.sameSceneAs(current);

  /// Whether it was rendered with exactly [current]'s camera.
  bool sameCamera(CadScenePainter current) =>
      painter.zoom == current.zoom && painter.pan == current.pan;

  /// Raster reuse is safe only for panning inside the captured margin. A
  /// changed zoom needs exact geometry (including cosmetic widths and small
  /// labels), and panning past the image must not expose a blank strip.
  bool canPanTo(CadScenePainter current, Size size) {
    if (!matches(current, size) || current.zoom != painter.zoom) return false;
    final delta = current.pan - painter.pan;
    return delta.dx.abs() <= padding.dx - 2 && delta.dy.abs() <= padding.dy - 2;
  }

  /// Renders [painter]'s 2D scene with a margin around the [size] viewport.
  static Future<CadSceneSnapshot> capture(
    CadScenePainter painter,
    Size size,
    double pixelRatio,
  ) async {
    final padding = Offset(
      size.width * paddingFraction,
      size.height * paddingFraction,
    );
    final padded = Size(
      size.width + padding.dx * 2,
      size.height + padding.dy * 2,
    );
    var ratio = pixelRatio;
    final pixels = padded.width * padded.height * ratio * ratio;
    if (pixels > maxPixels) ratio *= math.sqrt(maxPixels / pixels);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(ratio)
      ..translate(padding.dx, padding.dy);
    painter
        .snapshotContent(math.max(padding.dx, padding.dy) + 40)
        .paint(canvas, size);
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(
        math.max(1, (padded.width * ratio).ceil()),
        math.max(1, (padded.height * ratio).ceil()),
      );
      return CadSceneSnapshot._(image, painter, size, padding);
    } finally {
      picture.dispose();
    }
  }

  /// Paints the snapshot as seen with [zoom] and [pan].
  void paint(Canvas canvas, Size size, double zoom, Offset pan) {
    final center = size.center(Offset.zero);
    final scale = zoom / painter.zoom;
    canvas
      ..save()
      ..translate(center.dx + pan.dx, center.dy + pan.dy)
      ..scale(scale)
      ..translate(-(center.dx + painter.pan.dx), -(center.dy + painter.pan.dy));
    canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        -padding.dx,
        -padding.dy,
        this.size.width + padding.dx * 2,
        this.size.height + padding.dy * 2,
      ),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  void dispose() => image.dispose();
}

/// Paints a [CadSceneSnapshot] on the live backdrop for the current camera.
class CadSnapshotPainter extends CustomPainter {
  CadSnapshotPainter(this.snapshot, {required this.zoom, required this.pan});

  final CadSceneSnapshot snapshot;
  final double zoom;
  final Offset pan;

  @override
  void paint(Canvas canvas, Size size) {
    CadScenePainter.paintBackdrop(
      canvas,
      size,
      pan,
      grid: snapshot.painter.showGrid,
    );
    snapshot.paint(canvas, size, zoom, pan);
  }

  @override
  bool shouldRepaint(CadSnapshotPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot ||
      oldDelegate.zoom != zoom ||
      oldDelegate.pan != pan;
}
