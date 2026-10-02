import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import 'cad_fonts.dart';

/// Drawing heights are capital heights, not OpenType em sizes. Keep UI and SVG
/// font sizes out of this conversion. Bundled metrics come from the actual
/// font tables; installed families are calibrated once using the engine's A
/// (the CAD reference capital, whose top need not match every uppercase glyph).
final _capRatios = <String, double>{cadDefaultFontFamily: 0.714};
final _pending = <String, Future<void>>{};
final _assetMetrics = <String>{};
final _failed = <String>{};
final _calibrated = <String>{};
Future<void>? _loading;
int _revision = 0;
int get cadFontMetricsRevision => _revision;

double cadFontCapRatio(String? family) =>
    _capRatios[cadPrimaryFontFamily(family)] ??
    _capRatios[cadDefaultFontFamily]!;

/// Parse only bounded sfnt table metadata; never interpret outline programs.
/// OS/2 versions before 2 do not define sCapHeight.
double? sfntCapRatio(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 12) return null;
  if (data.getUint32(0) != 0x00010000 && data.getUint32(0) != 0x4f54544f) {
    return null;
  }
  final count = data.getUint16(4);
  if (count > 256 || 12 + count * 16 > bytes.length) return null;
  (int, int)? head;
  (int, int)? os2;
  for (var i = 0; i < count; i++) {
    final at = 12 + i * 16;
    final offset = data.getUint32(at + 8);
    final length = data.getUint32(at + 12);
    if (offset > bytes.length || length > bytes.length - offset) return null;
    switch (data.getUint32(at)) {
      case 0x68656164: // head
        head = (offset, length);
      case 0x4f532f32: // OS/2
        os2 = (offset, length);
    }
  }
  if (head == null || os2 == null || head.$2 < 20 || os2.$2 < 90) {
    return null;
  }
  if (data.getUint16(os2.$1) < 2) return null;
  final em = data.getUint16(head.$1 + 18);
  final cap = data.getInt16(os2.$1 + 88);
  if (em < 16 || cap <= 0) return null;
  final ratio = cap / em;
  return ratio >= 0.1 && ratio <= 2 ? ratio : null;
}

void registerCadFontMetrics(String family, Uint8List bytes) {
  final ratio = sfntCapRatio(bytes);
  if (ratio == null) return;
  _assetMetrics.add(family);
  _calibrated.remove(family);
  if (_capRatios[family] != ratio) {
    _capRatios[family] = ratio;
    _revision++;
  }
}

Future<void> loadCadFontMetrics() => _loading ??= () async {
  for (final entry in cadFontAssets.entries) {
    if (_assetMetrics.contains(entry.key)) continue;
    final bytes = await rootBundle.load(entry.value);
    registerCadFontMetrics(
      entry.key,
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  }
}();

typedef _CapRaster = ({double ratio, int signature, int width, int height});
Future<_CapRaster>? _defaultRaster;

Future<_CapRaster> _rasterCap(String family) async {
  const size = 512.0;
  final painter = TextPainter(
    text: TextSpan(
      text: 'A',
      style: TextStyle(
        fontFamily: family,
        fontFamilyFallback: cadFontFallback,
        fontSize: size,
        color: const ui.Color(0xffffffff),
      ),
    ),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  final width = math.min(1024, painter.width.ceil() + 16);
  final height = math.min(1536, painter.height.ceil() + 16);
  final recorder = ui.PictureRecorder();
  painter.paint(ui.Canvas(recorder), const ui.Offset(8, 8));
  final picture = recorder.endRecording();
  painter.dispose();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) throw StateError('Font calibration readback failed');
    final pixels = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    var top = height;
    var bottom = -1;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (pixels[(y * width + x) * 4 + 3] >= 128) {
          top = math.min(top, y);
          bottom = math.max(bottom, y);
        }
      }
    }
    final ratio = (bottom - top + 1) / size;
    if (ratio < 0.1 || ratio > 2) throw StateError('Invalid font cap height');
    return (
      ratio: ratio,
      signature: Object.hashAll(pixels),
      width: width,
      height: height,
    );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

/// Readback failure or a full cache retains a readable default metric and
/// returns false so callers can surface a diagnostic without losing the label.
Future<bool> prepareCadTextFontMetrics(Map<String, dynamic> geometry) async {
  await loadCadFontMetrics();
  if (geometry['height_reference'] == 'em') return true;
  final families = <String>{
    cadPrimaryFontFamily(geometry['font_family'] as String?),
    for (final run in geometry['text_runs'] as List<dynamic>? ?? const [])
      if ((run as Map)['style'] case final Map style)
        if (style['font_family'] case final String family)
          cadPrimaryFontFamily(family),
  };
  var complete = true;
  for (final family in families) {
    if (_calibrated.contains(family)) {
      if (_failed.contains(family)) complete = false;
      continue;
    }
    if (_calibrated.length >= 512) {
      complete = false;
      continue;
    }
    try {
      await (_pending[family] ??= () async {
        final raster = await _rasterCap(family);
        final fallback = await (_defaultRaster ??= _rasterCap(
          cadDefaultFontFamily,
        ));
        // Missing families resolve to the bundled font. Keep its exact table
        // metric instead of introducing pixel quantization into the fallback.
        final table = _assetMetrics.contains(family)
            ? _capRatios[family]
            : null;
        final ratio = table != null && (raster.ratio - table).abs() <= 1 / 512
            ? table
            : raster.signature == fallback.signature &&
                  raster.width == fallback.width &&
                  raster.height == fallback.height
            ? _capRatios[cadDefaultFontFamily]!
            : raster.ratio;
        _capRatios[family] = ratio;
        _calibrated.add(family);
        _revision++;
      }());
    } catch (_) {
      _capRatios[family] = _capRatios[cadDefaultFontFamily]!;
      _failed.add(family);
      _calibrated.add(family);
      _revision++;
      complete = false;
    } finally {
      _pending.remove(family);
    }
  }
  return complete;
}
