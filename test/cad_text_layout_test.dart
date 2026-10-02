import 'dart:io';

import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multilingual_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in cadFontAssets.entries) {
      final loader = FontLoader(entry.key);
      registerCadFontMetrics(entry.key, File(entry.value).readAsBytesSync());
      loader.addFont(
        Future.value(ByteData.sublistView(File(entry.value).readAsBytesSync())),
      );
      await loader.load();
    }
  });

  Rect bounds(Map<String, dynamic> changes, {double zoom = 1}) {
    final document = multilingualCadDocument();
    final geometry = Map<String, dynamic>.from(
      document.entities.first['geometry'] as Map,
    );
    geometry.addAll({
      'origin': {'x': 450, 'y': 550},
      'value': '中文測量尺寸 Размер العربية 日本語 中文測量尺寸 Размер العربية 日本語',
      'height': 28,
      ...changes,
    });
    return cadTextScreenBounds(
      geometry,
      CadViewTransform.forScene(
        document,
        const Size(900, 1100),
        zoom,
        Offset.zero,
      ),
    );
  }

  test('MTEXT wraps instead of horizontally stretching a paragraph', () {
    final unwrapped = bounds({});
    final wrapped = bounds({'wrap_width': 180});
    expect(wrapped.width, lessThan(unwrapped.width * 0.5));
    expect(wrapped.height, greaterThan(unwrapped.height * 1.5));
    // Width belongs in the layout cache key; revisiting unwrapped text must
    // not reuse the narrow paragraph from an earlier camera/style request.
    expect(bounds({}), unwrapped);
  });

  Map<String, dynamic> paragraph(double factor, String style) => {
    'origin': {'x': 450.0, 'y': 550.0},
    'value': 'A\nA\nA',
    'height': 60.0,
    'line_spacing': {'factor': factor, 'style': style},
  };

  Map<String, dynamic> columnParagraph({
    String value = 'A\nB\nC\nD\nE\nF',
    bool reversed = false,
    List<double> heights = const [],
    List<int> breaks = const [],
  }) => {
    'origin': {'x': 450.0, 'y': 550.0},
    'value': value,
    'height': 10.0,
    'width_factor': 1.0,
    'horizontal_alignment': 'left',
    'vertical_alignment': 'top',
    'line_spacing': {'factor': 1.0, 'style': 'exact'},
    'columns': {
      'count': 3,
      'width': 100.0,
      'gutter': 20.0,
      'defined_height': heights.isEmpty ? 40.0 : 0.0,
      'heights': heights,
      'flow_reversed': reversed,
      'auto_height': false,
      'manual_breaks': breaks,
    },
  };

  test('static columns flow by shaped line height with declared gutters', () {
    final geometry = columnParagraph();
    final columns = cadTextColumnLayout(geometry);
    expect(columns.map((column) => column.text), ['A\nB', 'C\nD', 'E\nF']);
    expect(columns.map((column) => column.box), [
      const Rect.fromLTWH(0, 0, 100, 40),
      const Rect.fromLTWH(120, 0, 100, 40),
      const Rect.fromLTWH(240, 0, 100, 40),
    ]);
    final reversed = cadTextColumnLayout(columnParagraph(reversed: true));
    expect(
      reversed.map((column) => column.text),
      columns.map((column) => column.text),
    );
    expect(reversed.map((column) => column.box.left), [240.0, 120.0, 0.0]);
    // Camera changes must neither reshape nor rebalance column flow.
    final world = cadTextWorldBounds(geometry);
    for (final scale in [0.001, 1.0, 25.0, 10000.0]) {
      final transform = CadViewTransform(
        worldCenter: Offset.zero,
        screenCenter: Offset.zero,
        scale: scale,
      );
      final screen = cadTextScreenBounds(geometry, transform);
      expect(screen.width / scale, closeTo(world.width, 1e-7));
      expect(screen.height / scale, closeTo(world.height, 1e-7));
    }
    expect(cadTextColumnLayout(geometry).map((column) => column.text), [
      'A\nB',
      'C\nD',
      'E\nF',
    ]);
  });

  test(
    'manual column heights and zero-height tail never discard remaining text',
    () {
      final columns = cadTextColumnLayout(
        columnParagraph(heights: [20, 40, 0]),
      );
      expect(columns.map((column) => column.text), ['A', 'B\nC', 'D\nE\nF']);
      expect(columns[0].box.height, 20);
      expect(columns[1].box.height, 40);
      expect(columns[2].box.height, greaterThan(40));
      final overflow = cadTextColumnLayout(
        columnParagraph(value: List.filled(30, 'A').join('\n')),
      );
      expect(overflow.last.text.split('\n'), hasLength(26));
      expect(overflow.last.box.height, greaterThan(40));
    },
  );

  test('manual breaks retain multilingual UTF16 runs and whole-paragraph direction', () {
    const value = '日本語e\u0301😀\nالعربية\nবাংলা';
    final geometry = columnParagraph(
      value: value,
      breaks: [value.indexOf('\n'), value.lastIndexOf('\n')],
    );
    geometry['text_runs'] = [
      {
        'start': 0,
        'end': value.length,
        'style': {'underline': true, 'font_family': 'CADView Noto Sans'},
      },
    ];
    final columns = cadTextColumnLayout(geometry);
    expect(columns.map((column) => column.text), [
      '日本語e\u0301😀',
      'العربية',
      'বাংলা',
    ]);
    for (final column in columns) {
      expect(column.runs!.single['start'], 0);
      expect(column.runs!.single['end'], column.text.length);
      expect(column.runs!.single['style']['underline'], isTrue);
      expect(
        column.text.codeUnits.last,
        isNot(inInclusiveRange(0xd800, 0xdbff)),
      );
    }
  });

  test(
    'narrow automatic columns preserve shaped combining sequences and all text',
    () {
      const cluster = 'e\u0301';
      final geometry = columnParagraph(value: List.filled(60, cluster).join());
      (geometry['columns'] as Map)['width'] = 12.0;
      final columns = cadTextColumnLayout(geometry);
      expect(
        columns.map((column) => column.text).join(),
        List.filled(60, cluster).join(),
      );
      for (final column in columns.where((column) => column.text.isNotEmpty)) {
        expect(column.text.codeUnitAt(0), 'e'.codeUnitAt(0));
        expect(column.text.codeUnitAt(column.text.length - 1), 0x301);
      }
      // The column width is a layout constraint, not a clip rectangle. A word
      // or glyph wider than it is still painted and covered by spatial bounds.
      expect(cadTextWorldBounds(geometry).height, greaterThan(40));
    },
  );

  test(
    'column cache separates heights, reversal, width scale and manual breaks',
    () {
      final base = columnParagraph();
      final expected = cadTextColumnLayout(base);
      for (final widthFactor in [0.5, 2.0]) {
        final changed = columnParagraph()..['width_factor'] = widthFactor;
        expect(cadTextColumnLayout(changed).map((column) => column.box.left), [
          0.0,
          120.0,
          240.0,
        ]);
      }
      cadTextColumnLayout(
        columnParagraph(heights: [20, 40, 0], reversed: true),
      );
      expect(
        cadTextColumnLayout(base).map((column) => column.text),
        expected.map((column) => column.text),
      );
    },
  );

  test(
    'Exact MTEXT baselines use CAD cap height and preserve the full range',
    () {
      for (final factor in [0.25, 0.6, 1.0, 4.0]) {
        final lines = cadTextLineBaselines(paragraph(factor, 'exact'));
        final strut = cadMTextStrut(60, null, {
          'factor': factor,
          'style': 'exact',
        });
        expect(
          strut.fontSize! * strut.height!,
          closeTo(60 * 5 / 3 * factor, 1e-8),
        );
        expect(lines, hasLength(3));
        for (var i = 1; i < lines.length; i++) {
          // Flutter quantizes line metrics at the camera-independent 128-unit
          // shaping size. Require less than one shape pixel in world units;
          // the independent raster oracle below still uses two output pixels.
          expect(
            lines[i] - lines[i - 1],
            closeTo(60 * 5 / 3 * factor, 60 / 128),
          );
        }
      }
    },
  );

  test(
    'AtLeast grows for large runs while Exact retains its baseline grid',
    () {
      final exact = paragraph(1, 'exact')
        ..['text_runs'] = [
          {
            'start': 2,
            'end': 3,
            'style': {'height_factor': 4.0},
          },
        ];
      final atLeast = Map<String, dynamic>.from(exact)
        ..['line_spacing'] = {'factor': 1.0, 'style': 'at_least'};
      final fixed = cadTextLineBaselines(exact);
      final growing = cadTextLineBaselines(atLeast);
      expect(fixed[1] - fixed[0], closeTo(100, 60 / 128));
      expect(fixed[2] - fixed[1], closeTo(100, 60 / 128));
      expect(growing[1] - growing[0], greaterThan(100));
      expect(growing[2] - growing[1], greaterThan(100));
      expect(cadTextLineBaselines(exact), fixed);
    },
  );

  test('invalid spacing factors safely default without changing the style', () {
    for (final factor in [double.nan, double.infinity, -1.0, 0.0, 4.1]) {
      expect(
        cadTextLineBaselines(paragraph(factor, 'exact')),
        cadTextLineBaselines(paragraph(1, 'exact')),
      );
    }
  });

  test('multilingual forced-line envelopes remain camera independent', () {
    final geometry = paragraph(0.25, 'exact')
      ..addAll({
        'value': '中文\nالعربية বাংলা\nབོད་ཡིག 日本語',
        'text_runs': [
          {
            'start': 0,
            'end': 2,
            'style': {'height_factor': 10.0},
          },
        ],
        'rotation': 0.45,
        'mirrored_x': true,
        'plane': {'xx': -1.0, 'xy': 0.0, 'yx': 0.0, 'yy': -0.8},
      });
    final world = cadTextWorldBounds(geometry);
    expect(world.height, greaterThan(300));
    for (final scale in [0.001, 1.0, 17.0, 10000.0]) {
      final transform = CadViewTransform(
        worldCenter: const Offset(120, -40),
        screenCenter: const Offset(800, 600),
        scale: scale,
      );
      final screen = cadTextScreenBounds(geometry, transform);
      expect(
        transform.screenToWorld(screen.topLeft).dx,
        closeTo(world.left, 1e-7),
      );
      expect(
        transform.screenToWorld(screen.topLeft).dy,
        closeTo(world.bottom, 1e-7),
      );
      expect(
        transform.screenToWorld(screen.bottomRight).dx,
        closeTo(world.right, 1e-7),
      );
      expect(
        transform.screenToWorld(screen.bottomRight).dy,
        closeTo(world.top, 1e-7),
      );
    }
  });

  test('rich text retains Unicode ranges and scoped font/decorations', () {
    const value = '中文e\u0301😀日本語';
    final span = cadTextSpan(
      value,
      color: Colors.white,
      fontSize: 32,
      runs: [
        {
          'start': 0,
          'end': 2,
          'style': {
            'font_family': 'CADView Noto CJK',
            'height_factor': 2.0,
            'bold': true,
            'italic': true,
            'underline': true,
            'overline': true,
          },
        },
        {
          'start': 4,
          'end': 6,
          'style': {'strike_through': true},
        },
      ],
    );
    expect(span.toPlainText(), value);
    final first = span.children!.first as TextSpan;
    expect(first.text, '中文');
    expect(first.style!.fontFamily, 'CADView Noto CJK');
    expect(first.style!.fontFamilyFallback, contains('CADView Noto Arabic'));
    expect(first.style!.fontFamilyFallback, contains('CADView Noto Bengali'));
    expect(
      first.style!.fontSize,
      closeTo(64 / cadFontCapRatio('CADView Noto CJK'), 1e-8),
    );
    expect(first.style!.fontWeight, FontWeight.bold);
    expect(first.style!.fontStyle, FontStyle.italic);
    expect(first.style!.decoration!.contains(TextDecoration.underline), isTrue);
    expect(first.style!.decoration!.contains(TextDecoration.overline), isTrue);
    expect((span.children![1] as TextSpan).text, 'e\u0301');
    expect((span.children![2] as TextSpan).text, '😀');
    expect(
      (span.children![2] as TextSpan).style!.decoration,
      TextDecoration.lineThrough,
    );
  });

  test(
    'invalid rich text ranges do not split surrogate pairs or lose labels',
    () {
      for (final range in [(1, 2), (0, 99), (-1, 1), (2, 1)]) {
        final span = cadTextSpan(
          '😀中文',
          color: Colors.white,
          fontSize: 32,
          runs: [
            {
              'start': range.$1,
              'end': range.$2,
              'style': {'underline': true},
            },
          ],
        );
        expect(span.toPlainText(), '😀中文');
        expect(span.children, isNull);
      }
    },
  );

  test('height-only and decoration-only runs inherit the source font', () {
    final span = cadTextSpan(
      'AB',
      color: Colors.white,
      fontSize: 32,
      fontFamily: 'CADView Noto CJK',
      runs: [
        {
          'start': 0,
          'end': 1,
          'style': {'height_factor': 2.0},
        },
        {
          'start': 1,
          'end': 2,
          'style': {'underline': true},
        },
      ],
    );
    for (final child in span.children!.cast<TextSpan>()) {
      expect(child.style!.fontFamily, 'CADView Noto CJK');
      expect(child.style!.fontFamilyFallback, contains('CADView Noto Arabic'));
    }
  });

  test(
    'rich text styles participate in layout cache and camera-stable bounds',
    () {
      const value = '中文 العربية বাংলা 日本語';
      final styled = [
        {
          'start': 0,
          'end': value.length,
          'style': {
            'height_factor': 2.0,
            'underline': true,
            'font_family': 'CADView Noto CJK',
          },
        },
      ];
      final plain = bounds({'value': value});
      final rich = bounds({'value': value, 'text_runs': styled});
      expect(rich.height, greaterThan(plain.height * 1.5));
      expect(bounds({'value': value}), plain);
      expect(bounds({'value': value, 'text_runs': styled}), rich);
      final zoomed = bounds({'value': value, 'text_runs': styled}, zoom: 17);
      expect(zoomed.height / rich.height, closeTo(17, 1e-8));
      expect(zoomed.width / rich.width, closeTo(17, 1e-8));
    },
  );

  test('Aligned TEXT scales height while Fit TEXT retains its height', () {
    final fit = bounds({
      'value': 'AB',
      'target_width': 200,
      'uniform_fit': false,
    });
    final aligned = bounds({
      'value': 'AB',
      'target_width': 200,
      'uniform_fit': true,
    });
    expect(aligned.width, closeTo(fit.width, 1e-8));
    expect(aligned.height, greaterThan(fit.height * 3));
  });

  test(
    'high zoom keeps CAD text dimensions beyond the font shape size cap',
    () {
      final first = bounds({'value': '中文 ABC'}, zoom: 100);
      final second = bounds({'value': '中文 ABC'}, zoom: 200);
      expect(second.width / first.width, closeTo(2, 1e-8));
      expect(second.height / first.height, closeTo(2, 1e-8));
    },
  );

  test('wrapping and native world envelopes do not change with the camera', () {
    final document = multilingualCadDocument();
    final geometry =
        Map<String, dynamic>.from(document.entities.first['geometry'] as Map)
          ..addAll({
            'value': 'العربية 中文 বাংলা བོད་ཡིག A very narrow fitted label',
            'height': 10,
            'wrap_width': 75,
            'rotation': 0.45,
            'oblique_angle': 0.2,
            'mirrored_y': true,
            'horizontal_alignment': 'right',
            'vertical_alignment': 'middle',
          });
    final world = cadTextWorldBounds(geometry);
    for (final scale in [0.001, 0.17, 1.0, 25.0, 10000.0]) {
      final transform = CadViewTransform(
        worldCenter: const Offset(120, -40),
        screenCenter: const Offset(800, 600),
        scale: scale,
      );
      final screen = cadTextScreenBounds(geometry, transform);
      final first = transform.screenToWorld(screen.topLeft);
      final second = transform.screenToWorld(screen.bottomRight);
      expect(first.dx, closeTo(world.left, 1e-7));
      expect(first.dy, closeTo(world.bottom, 1e-7));
      expect(second.dx, closeTo(world.right, 1e-7));
      expect(second.dy, closeTo(world.top, 1e-7));
    }
  });

  test('thin Aligned glyph requires an envelope beyond the old estimate', () {
    final fit = bounds({
      'value': 'I',
      'height': 10,
      'width_factor': 0.1,
      'target_width': 100,
      'uniform_fit': true,
    });
    expect(fit.height, greaterThan(1000));
  });

  test('projected text plane transforms geometry and bounds consistently', () {
    final document = multilingualCadDocument();
    final geometry =
        Map<String, dynamic>.from(document.entities.first['geometry'] as Map)
          ..addAll({
            'origin': {'x': 0, 'y': 0},
            'rotation': 0,
            'value': '中文 Размер العربية',
            'height': 28,
          });
    final regular = cadTextWorldBounds(geometry);
    geometry['plane'] = {'xx': -1.0, 'xy': 0.0, 'yx': 0.0, 'yy': 1.0};
    final mirrored = cadTextWorldBounds(geometry);
    expect(mirrored.left, closeTo(-regular.right, 1e-8));
    expect(mirrored.right, closeTo(-regular.left, 1e-8));
    expect(mirrored.top, regular.top);
    geometry['plane'] = {'xx': -1.0, 'xy': 0.0, 'yx': 0.0, 'yy': -0.8};
    final tilted = cadTextWorldBounds(geometry);
    expect(tilted.height, closeTo(regular.height * 0.8, 1e-8));
    expect(tilted.top, closeTo(-regular.bottom * 0.8, 1e-8));
  });
}
