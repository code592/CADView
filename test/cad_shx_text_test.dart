import 'dart:io';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Widths AutoCAD fitted leader underlines to in a GB title-block drawing whose
// style uses ebgen.shx + hztxt.shx (height 3.2, width factor 0.8).
const _autocadWidths = {
  '平面地形、土方断面图采用此格式': 41.37,
  'EBGEN.SHX(EBGHZ.SHX)': 35.08,
  '中心线线型采用ACAD_ISO04W100': 43.14,
  '仿宋_GB2312，字高3.5，字宽0.8': 43.44,
};

Map<String, dynamic> _label(String value, {Map<String, dynamic>? shx}) => {
  'kind': 'text',
  'origin': {'x': 0.0, 'y': 0.0},
  'value': value,
  'height': 3.2,
  'height_reference': 'cap_height',
  'rotation': 0.0,
  'width_factor': 0.8,
  'oblique_angle': 0.0,
  'horizontal_alignment': 'left',
  'vertical_alignment': 'baseline',
  'font_family': 'CADView Noto CJK',
  'shx': ?shx,
};

const _ebgen = {'font': 'ebgen.shx', 'big_font': 'hztxt.shx'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in cadFontAssets.entries) {
      final bytes = File(entry.value).readAsBytesSync();
      registerCadFontMetrics(entry.key, bytes);
      final loader = FontLoader(entry.key)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }
  });

  test('SHX styles select narrow Latin and big-font CJK sizing', () {
    expect(cadShxTextOptions(_label('A', shx: _ebgen)), (
      family: cadNarrowLatinFontFamily,
      cjkEmIsHeight: true,
    ));
    expect(cadShxTextOptions(_label('A', shx: {'font': 'txt.shx'})), (
      family: 'CADView Noto CJK',
      cjkEmIsHeight: false,
    ));
    expect(cadShxTextOptions(_label('A')), (
      family: 'CADView Noto CJK',
      cjkEmIsHeight: false,
    ));
  });

  test('big-font CJK spans use the text height as their em', () {
    final span = cadTextSpan(
      'A中文B',
      color: Colors.white,
      fontSize: 32,
      fontFamily: cadNarrowLatinFontFamily,
      cjkEmIsHeight: true,
    );
    expect(span.toPlainText(), 'A中文B');
    final children = span.children!.cast<TextSpan>();
    expect(children.map((child) => child.text), ['A', '中文', 'B']);
    expect(children[1].style!.fontSize, 32);
    expect(children[0].style, isNull);
    expect(
      span.style!.fontSize,
      closeTo(32 / cadFontCapRatio(cadNarrowLatinFontFamily), 1e-9),
    );
  });

  testWidgets('SHX labels match the widths AutoCAD fitted them to', (
    tester,
  ) async {
    for (final MapEntry(key: value, value: width) in _autocadWidths.entries) {
      final measured = cadTextWorldBounds(_label(value, shx: _ebgen)).width;
      expect(
        measured / width,
        inInclusiveRange(0.93, 1.07),
        reason: '$value: $measured vs AutoCAD $width',
      );
      // Without SHX emulation the same labels are far too wide.
      expect(cadTextWorldBounds(_label(value)).width / width, greaterThan(1.2));
    }
  });

  testWidgets('rebar grade codes render bundled symbol glyphs', (tester) async {
    for (final code in [0xe130, 0xe131, 0xe132, 0xe133]) {
      final painter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(code),
          style: const TextStyle(
            fontFamily: 'CADView CAD Symbols',
            fontSize: 100,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), Offset.zero);
      final image = await tester.runAsync(
        () => recorder.endRecording().toImage(
          painter.width.ceil(),
          painter.height.ceil(),
        ),
      );
      final data = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final pixels = data!.buffer.asUint8List();
      var ink = 0;
      for (var i = 3; i < pixels.length; i += 4) {
        if (pixels[i] > 128) ink++;
      }
      // A missing glyph would fall back to a box or nothing; the symbol has
      // a substantial ring-and-stroke outline.
      expect(ink, greaterThan(800), reason: code.toRadixString(16));
      expect(painter.width, closeTo(60, 1));
      image!.dispose();
      painter.dispose();
    }
  });
}
