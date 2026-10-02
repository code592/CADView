import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../features/viewer/cad_document_model.dart';
import '../features/viewer/cad_scene_painter.dart';
import 'cad_engine.dart';

/// Pixel size of one exported sheet: the frame's proportions, at most
/// [maxEdge] pixels long and [maxPixels] in total (bounded transient memory
/// for the RGBA readback on mobile devices).
({int width, int height}) sheetRasterSize(
  Rect frame, {
  int maxEdge = 4096,
  int maxPixels = 12 * 1024 * 1024,
}) {
  if (!frame.isFinite || frame.isEmpty) {
    throw StateError('The sheet has no area');
  }
  final aspect = frame.width / frame.height;
  var width = aspect >= 1 ? maxEdge.toDouble() : maxEdge * aspect;
  var height = aspect >= 1 ? maxEdge / aspect : maxEdge.toDouble();
  final area = width * height;
  if (area > maxPixels) {
    final shrink = math.sqrt(maxPixels / area);
    width *= shrink;
    height *= shrink;
  }
  return (
    width: math.max(1, width.floor()),
    height: math.max(1, height.floor()),
  );
}

/// Logical canvas size used for sheet rendering. Line and grid weights are in
/// logical pixels, so painting a smaller logical sheet scaled up keeps them as
/// visible as on screen instead of hairlines on a large raster.
const double _sheetLogicalLongEdge = 1600;

/// Paints exactly [frame] of [batch] (the entities loaded for that frame)
/// with the viewer's own painter, edge to edge, into a raster image.
Future<ui.Image> renderSheetImage(
  CadDocumentModel batch,
  Rect frame, {
  List<CadTextAnnotation> annotations = const [],
  int maxEdge = 4096,
  int maxPixels = 12 * 1024 * 1024,
}) async {
  final size = sheetRasterSize(frame, maxEdge: maxEdge, maxPixels: maxPixels);
  final ratio = math.max(size.width, size.height) / _sheetLogicalLongEdge;
  final logical = ui.Size(size.width / ratio, size.height / ratio);
  final scene = Map<String, dynamic>.from(batch.scene)
    ..['bounds'] = {
      'min': {'x': frame.left, 'y': frame.top},
      'max': {'x': frame.right, 'y': frame.bottom},
    };
  final document = CadDocumentModel(
    format: batch.format,
    displayName: batch.displayName,
    units: batch.units,
    frames: batch.frames,
    sceneKind: batch.sceneKind,
    scene: scene,
    diagnostics: batch.diagnostics,
  );
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(ratio);
  // The painter fits scene bounds into 88% of the canvas; undo that margin
  // (keeping 0.5%) so the sheet fills the image like a plotted page while
  // its own border lines stay fully visible.
  CadScenePainter(
    document: document,
    zoom: 0.995 / 0.88,
    pan: ui.Offset.zero,
    annotations: annotations,
  ).paint(canvas, logical);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size.width, size.height);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> encodePng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('PNG encoding failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// One PDF page holding a full-page raster.
class PdfRasterPage {
  PdfRasterPage({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.deflatedRgb,
    required this.widthPoints,
    required this.heightPoints,
  });

  /// Converts an image to a page of the given physical size.
  static Future<PdfRasterPage> fromImage(
    ui.Image image, {
    required double widthPoints,
    required double heightPoints,
  }) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Image readback failed');
    final rgba = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final rgb = Uint8List(image.width * image.height * 3);
    for (var source = 0, target = 0; source < rgba.length; source += 4) {
      rgb[target++] = rgba[source];
      rgb[target++] = rgba[source + 1];
      rgb[target++] = rgba[source + 2];
    }
    return PdfRasterPage(
      pixelWidth: image.width,
      pixelHeight: image.height,
      deflatedRgb: Uint8List.fromList(ZLibCodec(level: 6).encode(rgb)),
      widthPoints: widthPoints,
      heightPoints: heightPoints,
    );
  }

  final int pixelWidth;
  final int pixelHeight;
  final Uint8List deflatedRgb;
  final double widthPoints;
  final double heightPoints;
}

const double _pointsPerMillimetre = 72 / 25.4;

/// Physical page size of a sheet. A detected ISO frame prints at its sheet
/// size (border size ÷ drawing scale, in millimetres); anything else uses an
/// A3-long page with the frame's proportions.
({double width, double height}) sheetPageSizePoints(
  Rect frame, {
  double? scale,
}) {
  if (scale != null && scale > 0) {
    return (
      width: frame.width / scale * _pointsPerMillimetre,
      height: frame.height / scale * _pointsPerMillimetre,
    );
  }
  const longEdge = 420 * _pointsPerMillimetre;
  return frame.width >= frame.height
      ? (width: longEdge, height: longEdge * frame.height / frame.width)
      : (width: longEdge * frame.width / frame.height, height: longEdge);
}

/// Writes a PDF 1.4 document with one full-page raster per page.
Uint8List buildRasterPdf(List<PdfRasterPage> pages) {
  if (pages.isEmpty) throw StateError('No pages to export');
  final output = BytesBuilder(copy: false);
  final offsets = <int>[];
  void raw(String text) => output.add(latin1.encode(text));
  String number(double value) => value.toStringAsFixed(3);
  void object(int id, String body, [Uint8List? stream]) {
    offsets.add(output.length);
    raw('$id 0 obj\n$body');
    if (stream != null) {
      raw('\nstream\n');
      output.add(stream);
      raw('\nendstream');
    }
    raw('\nendobj\n');
  }

  output.add(const [0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34, 0x0a]);
  // Binary marker so transfer tools keep the file binary.
  output.add(const [0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]);
  // Objects: 1 catalog, 2 pages, then (page, contents, image) per page.
  final kids = [for (var i = 0; i < pages.length; i++) '${3 + i * 3} 0 R'];
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(
    2,
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${pages.length} >>',
  );
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final pageId = 3 + i * 3;
    final width = number(page.widthPoints);
    final height = number(page.heightPoints);
    object(
      pageId,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
      '/Resources << /XObject << /Im0 ${pageId + 2} 0 R >> >> '
      '/Contents ${pageId + 1} 0 R >>',
    );
    final content = latin1.encode('q $width 0 0 $height 0 0 cm /Im0 Do Q\n');
    object(pageId + 1, '<< /Length ${content.length} >>', content);
    object(
      pageId + 2,
      '<< /Type /XObject /Subtype /Image /Width ${page.pixelWidth} '
      '/Height ${page.pixelHeight} /ColorSpace /DeviceRGB '
      '/BitsPerComponent 8 /Filter /FlateDecode '
      '/Length ${page.deflatedRgb.length} >>',
      page.deflatedRgb,
    );
  }
  final xref = output.length;
  raw('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    raw('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  raw(
    'trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return output.takeBytes();
}

/// File name of one exported sheet: `<drawing>-<n>-<paper>.png`.
String sheetExportFileName(
  String documentName,
  int index,
  String? paper,
  String extension,
) {
  final name = documentName.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
  final dot = name.lastIndexOf('.');
  var stem = dot > 0 ? name.substring(0, dot) : name;
  if (stem.isEmpty || stem == '.' || stem == '..') stem = 'drawing';
  final suffix = paper == null ? '$index' : '$index-$paper';
  return '$stem-$suffix.$extension';
}

/// File name of a whole-document export: `<drawing>.<extension>`.
String documentExportFileName(String documentName, String extension) {
  final name = documentName.replaceAll(RegExp(r'[\\/\x00-\x1f]'), '_');
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return '${stem.isEmpty || stem == '.' || stem == '..' ? 'drawing' : stem}.$extension';
}
