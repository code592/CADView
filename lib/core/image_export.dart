import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Bound readback memory (RGBA plus PNG encoding) on mobile devices. Export is
/// a one-shot snapshot, not a recurring frame callback.
double imageExportPixelRatio(Size size, double devicePixelRatio) {
  if (size.isEmpty || !size.width.isFinite || !size.height.isFinite) {
    throw StateError('No drawing viewport is available');
  }
  // Apply the edge limit before multiplying dimensions. Multiplying the
  // logical dimensions first can overflow and yield a zero capture ratio.
  final edgeLimitedRatio = math.min(
    math.max(2, devicePixelRatio.isFinite ? devicePixelRatio : 2),
    4096 / math.max(size.width, size.height),
  );
  final pixels =
      (size.width * edgeLimitedRatio) * (size.height * edgeLimitedRatio);
  return edgeLimitedRatio * math.min(1, math.sqrt(8 * 1024 * 1024 / pixels));
}

Future<Uint8List> captureViewportPng(
  GlobalKey key, {
  required double devicePixelRatio,
}) async {
  await WidgetsBinding.instance.endOfFrame;
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! RenderRepaintBoundary || !boundary.attached) {
    throw StateError('The drawing is not ready to export');
  }
  final image = await boundary.toImage(
    pixelRatio: imageExportPixelRatio(boundary.size, devicePixelRatio),
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

String imageExportFileName(String documentName) {
  final name = documentName.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return '${stem.isEmpty || stem == '.' || stem == '..' ? 'drawing' : stem}.png';
}
