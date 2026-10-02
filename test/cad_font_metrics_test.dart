import 'dart:io';
import 'dart:typed_data';

import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bundled capital-height metrics are read from licensed font tables', () {
    for (final entry in cadFontAssets.entries) {
      final bytes = File(entry.value).readAsBytesSync();
      final ratio = sfntCapRatio(bytes);
      expect(ratio, isNotNull, reason: entry.key);
      registerCadFontMetrics(entry.key, bytes);
      expect(cadFontCapRatio(entry.key), ratio);
    }
    expect(cadFontCapRatio(cadDefaultFontFamily), 0.714);
    expect(cadFontCapRatio('CADView Noto CJK'), 0.733);
    expect(cadFontCapRatio('Missing family'), 0.714);
  });

  test(
    'font metadata rejects truncated or invalid tables without throwing',
    () {
      final good = File(cadFontAssets[cadDefaultFontFamily]!).readAsBytesSync();
      for (final length in [0, 4, 12, 100]) {
        expect(sfntCapRatio(Uint8List.sublistView(good, 0, length)), isNull);
      }
      for (final mutation in ['signature', 'offset', 'em', 'cap', 'version']) {
        final bytes = Uint8List.fromList(good);
        final data = ByteData.sublistView(bytes);
        if (mutation == 'signature') data.setUint32(0, 0);
        for (var i = 0; i < data.getUint16(4); i++) {
          final at = 12 + i * 16;
          final tag = data.getUint32(at);
          final offset = data.getUint32(at + 8);
          if (mutation == 'offset' && tag == 0x68656164) {
            data.setUint32(at + 8, 0xffffffff);
          }
          if (mutation == 'em' && tag == 0x68656164) {
            data.setUint16(offset + 18, 0);
          }
          if (mutation == 'cap' && tag == 0x4f532f32) {
            data.setInt16(offset + 88, -1);
          }
          if (mutation == 'version' && tag == 0x4f532f32) {
            data.setUint16(offset, 1);
          }
        }
        expect(sfntCapRatio(bytes), isNull, reason: mutation);
      }
    },
  );

  test('CAD capital-height conversion leaves SVG/em font sizes unchanged', () {
    registerCadFontMetrics(
      cadDefaultFontFamily,
      File(cadFontAssets[cadDefaultFontFamily]!).readAsBytesSync(),
    );
    final cad = cadTextSpan('H', color: Colors.white, fontSize: 32);
    final svg = cadTextSpan(
      'H',
      color: Colors.white,
      fontSize: 32,
      heightIsCapHeight: false,
    );
    expect(cad.style!.fontSize, closeTo(32 / 0.714, 1e-8));
    expect(svg.style!.fontSize, 32);
  });
}
