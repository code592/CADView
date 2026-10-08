import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../features/viewer/cad_document_model.dart';
import '../features/viewer/cad_scene_painter.dart';
import 'cad_engine.dart';

/// Resolution of exported PDF sheets (print quality).
const double sheetPdfDpi = 300;

/// Resolution of exported PNG sheets. Lower than PDF so a single A1 image
/// (about 31 megapixels) still opens in phone galleries.
const double sheetPngDpi = 200;

/// Largest raster rendered at once. Phone GPUs limit texture sizes, so
/// sheets are rendered and written in tiles of at most this many pixels.
const int sheetTileSize = 2048;

const double _millimetresPerInch = 25.4;
const double _pointsPerMillimetre = 72 / _millimetresPerInch;

/// Width of one logical pixel on paper. The painter's cosmetic 1.15 px lines
/// then plot at about 0.23 mm, like a default CAD lineweight, at any DPI.
const double _logicalPixelMillimetres = 0.2;

/// Physical size of a sheet. A detected ISO frame uses its sheet size (border
/// size ÷ drawing scale, in millimetres); anything else uses an A3-long sheet
/// with the frame's proportions.
({double width, double height}) sheetPaperSizeMillimetres(
  Rect frame, {
  double? scale,
}) {
  if (!frame.isFinite || frame.isEmpty) {
    throw StateError('The sheet has no area');
  }
  if (scale != null && scale.isFinite && scale > 0) {
    return (width: frame.width / scale, height: frame.height / scale);
  }
  const longEdge = 420.0;
  return frame.width >= frame.height
      ? (width: longEdge, height: longEdge * frame.height / frame.width)
      : (width: longEdge * frame.width / frame.height, height: longEdge);
}

/// PDF page size (points) of a sheet; see [sheetPaperSizeMillimetres].
({double width, double height}) sheetPageSizePoints(
  Rect frame, {
  double? scale,
}) {
  final paper = sheetPaperSizeMillimetres(frame, scale: scale);
  return (
    width: paper.width * _pointsPerMillimetre,
    height: paper.height * _pointsPerMillimetre,
  );
}

/// A sheet prepared for rendering: its document (bounded to the frame) and
/// raster/logical sizes for the requested resolution.
class CadSheetRaster {
  CadSheetRaster._({
    required this.document,
    required this.width,
    required this.height,
    required this.ratio,
    required this.annotations,
  });

  /// Prepares [frame] of [batch] (the entities loaded for that frame) at
  /// [dpi] on a paper of [paperWidthMm] × [paperHeightMm]. [maxPixels] bounds
  /// very large sheets by lowering the resolution.
  factory CadSheetRaster.prepare(
    CadDocumentModel batch,
    Rect frame, {
    required double paperWidthMm,
    required double paperHeightMm,
    required double dpi,
    int maxPixels = 120 * 1024 * 1024,
    List<CadTextAnnotation> annotations = const [],
  }) {
    if (!frame.isFinite || frame.isEmpty) {
      throw StateError('The sheet has no area');
    }
    var pixelsPerMm = dpi / _millimetresPerInch;
    final area = paperWidthMm * paperHeightMm * pixelsPerMm * pixelsPerMm;
    if (area > maxPixels) pixelsPerMm *= math.sqrt(maxPixels / area);
    final width = math.max(1, (paperWidthMm * pixelsPerMm).round());
    final height = math.max(1, (paperHeightMm * pixelsPerMm).round());
    final scene = Map<String, dynamic>.from(batch.scene)
      ..['bounds'] = {
        'min': {'x': frame.left, 'y': frame.top},
        'max': {'x': frame.right, 'y': frame.bottom},
      };
    return CadSheetRaster._(
      document: CadDocumentModel(
        format: batch.format,
        displayName: batch.displayName,
        units: batch.units,
        frames: batch.frames,
        sceneKind: batch.sceneKind,
        scene: scene,
        diagnostics: batch.diagnostics,
      ),
      width: width,
      height: height,
      ratio: pixelsPerMm * _logicalPixelMillimetres,
      annotations: annotations,
    );
  }

  final CadDocumentModel document;
  final int width;
  final int height;

  /// Raster pixels per logical pixel.
  final double ratio;
  final List<CadTextAnnotation> annotations;

  ui.Size get logicalSize => ui.Size(width / ratio, height / ratio);

  /// Builds the sheet's paths between frames before its tiles are rendered.
  Future<void> prepare() => CadScenePainter.prepareDocument(document);

  /// Renders the pixel rectangle ([x], [y], [tileWidth] × [tileHeight]).
  Future<ui.Image> renderTile(int x, int y, int tileWidth, int tileHeight) {
    final recorder = ui.PictureRecorder();
    // The clip also lets the painter skip geometry outside this tile.
    final canvas = ui.Canvas(recorder)
      ..clipRect(
        ui.Rect.fromLTWH(0, 0, tileWidth.toDouble(), tileHeight.toDouble()),
      )
      ..translate(-x.toDouble(), -y.toDouble())
      ..scale(ratio);
    // The painter fits scene bounds into 88% of the canvas; undo that margin
    // (keeping 0.5%) so the sheet fills the page like a plot while its own
    // border lines stay fully visible.
    CadScenePainter(
      document: document,
      zoom: 0.995 / 0.88,
      pan: ui.Offset.zero,
      annotations: annotations,
      showGrid: false,
    ).paint(canvas, logicalSize);
    final picture = recorder.endRecording();
    return picture.toImage(tileWidth, tileHeight).whenComplete(picture.dispose);
  }

  /// Tile rectangles covering the sheet, row by row.
  Iterable<({int x, int y, int width, int height})> tiles([
    int size = sheetTileSize,
  ]) sync* {
    for (var y = 0; y < height; y += size) {
      for (var x = 0; x < width; x += size) {
        yield (
          x: x,
          y: y,
          width: math.min(size, width - x),
          height: math.min(size, height - y),
        );
      }
    }
  }
}

Future<Uint8List> _rawRgba(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) throw StateError('Image readback failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> encodePng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('PNG encoding failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(List<int> type, List<int> data) {
  var crc = 0xffffffff;
  for (final byte in type) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return crc ^ 0xffffffff;
}

/// A PNG chunk: length, type, data and CRC.
Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = latin1.encode(type);
  final chunk = Uint8List(12 + data.length);
  ByteData.sublistView(chunk).setUint32(0, data.length);
  chunk.setRange(4, 8, typeBytes);
  chunk.setRange(8, 8 + data.length, data);
  ByteData.sublistView(chunk)
      .setUint32(8 + data.length, _crc32(typeBytes, data));
  return chunk;
}

const _adlerBase = 65521;

int _adler32(Uint8List data) {
  var a = 1, b = 0;
  // 5552 bytes is the longest run whose sums cannot overflow before the
  // modulo (as in zlib); Dart integers are 64-bit, so this is conservative.
  for (var start = 0; start < data.length; start += 5552) {
    final end = math.min(start + 5552, data.length);
    for (var i = start; i < end; i++) {
      a += data[i];
      b += a;
    }
    a %= _adlerBase;
    b %= _adlerBase;
  }
  return b << 16 | a;
}

/// Adler-32 of two concatenated inputs from their checksums (zlib's
/// adler32_combine), [secondLength] being the second input's length.
int _adler32Combine(int first, int second, int secondLength) {
  final remainder = secondLength % _adlerBase;
  var sum1 = first & 0xffff;
  var sum2 = (remainder * sum1) % _adlerBase;
  sum1 += (second & 0xffff) + _adlerBase - 1;
  sum2 += (first >> 16) + (second >> 16) + _adlerBase - remainder;
  sum1 %= _adlerBase;
  sum2 %= _adlerBase;
  return sum2 << 16 | sum1;
}

/// One band of a sheet PNG, encoded in a background isolate: the tiles'
/// RGBA rows become filtered RGB rows, compressed as raw deflate blocks.
/// Every band but the last ends with a sync flush, which leaves the stream
/// byte aligned and unfinished, so the bands concatenate into one stream.
({Uint8List idat, int adler, int length}) _encodePngBand(
  List<({int x, int width, Uint8List rgba})> tiles,
  int sheetWidth,
  int bandHeight,
  bool last,
) {
  final rowBytes = sheetWidth * 3 + 1;
  final band = Uint8List(rowBytes * bandHeight);
  for (final tile in tiles) {
    for (var row = 0; row < bandHeight; row++) {
      var target = row * rowBytes + 1 + tile.x * 3;
      var source = row * tile.width * 4;
      for (var column = 0; column < tile.width; column++) {
        band[target++] = tile.rgba[source];
        band[target++] = tile.rgba[source + 1];
        band[target++] = tile.rgba[source + 2];
        source += 4;
      }
    }
  }
  final filter = RawZLibFilter.deflateFilter(level: 6, raw: true);
  filter.process(band, 0, band.length);
  final deflated = BytesBuilder(copy: false);
  for (
    var chunk = filter.processed(flush: !last, end: last);
    chunk != null;
    chunk = filter.processed(flush: !last, end: last)
  ) {
    deflated.add(chunk);
  }
  return (
    idat: _pngChunk('IDAT', deflated.takeBytes()),
    adler: _adler32(band),
    length: band.length,
  );
}

/// Encodes the whole sheet as one RGB PNG without holding the full raster.
/// Each band of tiles is rendered, then converted and compressed into an
/// IDAT chunk off the UI isolate, and released before the next band.
Future<Uint8List> encodeSheetPng(CadSheetRaster sheet) async {
  await sheet.prepare();
  final output = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    ..add(
      _pngChunk(
        'IHDR',
        (ByteData(13)
              ..setUint32(0, sheet.width)
              ..setUint32(4, sheet.height)
              ..setUint8(8, 8) // bit depth
              ..setUint8(9, 2) // RGB
              ..setUint8(10, 0)
              ..setUint8(11, 0)
              ..setUint8(12, 0))
            .buffer
            .asUint8List(),
      ),
    )
    // zlib header: deflate with a 32 KiB window, default compression.
    ..add(_pngChunk('IDAT', const [0x78, 0x9c]));
  var adler = 1;
  for (var y = 0; y < sheet.height; y += sheetTileSize) {
    final bandHeight = math.min(sheetTileSize, sheet.height - y);
    final tiles = <({int x, int width, Uint8List rgba})>[];
    for (var x = 0; x < sheet.width; x += sheetTileSize) {
      final tileWidth = math.min(sheetTileSize, sheet.width - x);
      final image = await sheet.renderTile(x, y, tileWidth, bandHeight);
      try {
        tiles.add((x: x, width: tileWidth, rgba: await _rawRgba(image)));
      } finally {
        image.dispose();
      }
    }
    final width = sheet.width;
    final last = y + bandHeight >= sheet.height;
    final band = await Isolate.run(
      () => _encodePngBand(tiles, width, bandHeight, last),
    );
    output.add(band.idat);
    adler = _adler32Combine(adler, band.adler, band.length);
  }
  output
    ..add(
      _pngChunk(
        'IDAT',
        (ByteData(4)..setUint32(0, adler)).buffer.asUint8List(),
      ),
    )
    ..add(_pngChunk('IEND', const []));
  return output.takeBytes();
}

/// One image placed on a PDF page, in points from the page's lower left.
class PdfImageTile {
  PdfImageTile({
    required this.pixelWidth,
    required this.pixelHeight,
    required this.deflatedRgb,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  static Future<PdfImageTile> fromImage(
    ui.Image image, {
    required double x,
    required double y,
    required double width,
    required double height,
  }) async {
    final rgba = await _rawRgba(image);
    // Conversion and compression run off the UI isolate.
    final deflated = await Isolate.run(() {
      final rgb = Uint8List(rgba.length ~/ 4 * 3);
      for (var source = 0, target = 0; source < rgba.length; source += 4) {
        rgb[target++] = rgba[source];
        rgb[target++] = rgba[source + 1];
        rgb[target++] = rgba[source + 2];
      }
      return Uint8List.fromList(ZLibCodec(level: 6).encode(rgb));
    });
    return PdfImageTile(
      pixelWidth: image.width,
      pixelHeight: image.height,
      deflatedRgb: deflated,
      x: x,
      y: y,
      width: width,
      height: height,
    );
  }

  final int pixelWidth;
  final int pixelHeight;
  final Uint8List deflatedRgb;
  final double x;
  final double y;
  final double width;
  final double height;
}

/// One PDF page made of raster tiles.
class PdfRasterPage {
  PdfRasterPage({
    required this.widthPoints,
    required this.heightPoints,
    required this.tiles,
  });

  /// A page showing a single image over its full area.
  static Future<PdfRasterPage> fromImage(
    ui.Image image, {
    required double widthPoints,
    required double heightPoints,
  }) async => PdfRasterPage(
    widthPoints: widthPoints,
    heightPoints: heightPoints,
    tiles: [
      await PdfImageTile.fromImage(
        image,
        x: 0,
        y: 0,
        width: widthPoints,
        height: heightPoints,
      ),
    ],
  );

  /// Renders [sheet] tile by tile onto a page of the given size. Adjacent
  /// tiles overlap by one pixel so viewers do not show hairline seams.
  static Future<PdfRasterPage> fromSheet(
    CadSheetRaster sheet, {
    required double widthPoints,
    required double heightPoints,
  }) async {
    await sheet.prepare();
    final xScale = widthPoints / sheet.width;
    final yScale = heightPoints / sheet.height;
    final tiles = <PdfImageTile>[];
    for (final tile in sheet.tiles()) {
      final tileWidth = math.min(tile.width + 1, sheet.width - tile.x);
      final tileHeight = math.min(tile.height + 1, sheet.height - tile.y);
      final image = await sheet.renderTile(
        tile.x,
        tile.y,
        tileWidth,
        tileHeight,
      );
      try {
        tiles.add(
          await PdfImageTile.fromImage(
            image,
            x: tile.x * xScale,
            y: heightPoints - (tile.y + tileHeight) * yScale,
            width: tileWidth * xScale,
            height: tileHeight * yScale,
          ),
        );
      } finally {
        image.dispose();
      }
    }
    return PdfRasterPage(
      widthPoints: widthPoints,
      heightPoints: heightPoints,
      tiles: tiles,
    );
  }

  final double widthPoints;
  final double heightPoints;
  final List<PdfImageTile> tiles;
}

/// Writes a PDF 1.4 document whose pages are made of raster tiles.
Uint8List buildRasterPdf(List<PdfRasterPage> pages) {
  if (pages.isEmpty) throw StateError('No pages to export');
  final output = BytesBuilder(copy: false);
  final offsets = <int>[];
  void raw(String text) => output.add(latin1.encode(text));
  String number(double value) => value.toStringAsFixed(3);
  void object(int id, String body, [Uint8List? stream]) {
    while (offsets.length < id) {
      offsets.add(0);
    }
    offsets[id - 1] = output.length;
    raw('$id 0 obj\n$body');
    if (stream != null) {
      raw('\nstream\n');
      output.add(stream);
      raw('\nendstream');
    }
    raw('\nendobj\n');
  }

  raw('%PDF-1.4\n');
  // Binary marker so transfer tools keep the file binary.
  output.add(const [0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]);
  // Objects: 1 catalog, 2 pages, then per page: page, contents, images.
  final pageIds = <int>[];
  var next = 3;
  for (final page in pages) {
    pageIds.add(next);
    next += 2 + page.tiles.length;
  }
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(
    2,
    '<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] '
    '/Count ${pages.length} >>',
  );
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    final pageId = pageIds[i];
    final images = [
      for (var t = 0; t < page.tiles.length; t++) '/Im$t ${pageId + 2 + t} 0 R',
    ];
    object(
      pageId,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 '
      '${number(page.widthPoints)} ${number(page.heightPoints)}] '
      '/Resources << /XObject << ${images.join(' ')} >> >> '
      '/Contents ${pageId + 1} 0 R >>',
    );
    final content = StringBuffer();
    for (var t = 0; t < page.tiles.length; t++) {
      final tile = page.tiles[t];
      content.write(
        'q ${number(tile.width)} 0 0 ${number(tile.height)} '
        '${number(tile.x)} ${number(tile.y)} cm /Im$t Do Q\n',
      );
    }
    final contentBytes = latin1.encode(content.toString());
    object(pageId + 1, '<< /Length ${contentBytes.length} >>', contentBytes);
    for (var t = 0; t < page.tiles.length; t++) {
      final tile = page.tiles[t];
      object(
        pageId + 2 + t,
        '<< /Type /XObject /Subtype /Image /Width ${tile.pixelWidth} '
        '/Height ${tile.pixelHeight} /ColorSpace /DeviceRGB '
        '/BitsPerComponent 8 /Filter /FlateDecode '
        '/Length ${tile.deflatedRgb.length} >>',
        tile.deflatedRgb,
      );
    }
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

/// File name of one exported sheet: `<drawing>-<n>-<paper>.<extension>`.
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
