// Headless engine visual check WITHOUT --use-test-fonts. Widget tests replace
// unavailable system families with Ahem, which draws Latin as solid squares.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/core/cad_font_metrics.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/services.dart';

import '../test/support/multilingual_fixture.dart';

Future<void> main() async {
  try {
    await _runChecks();
    exit(0);
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exit(1);
  }
}

Future<void> _runChecks() async {
  for (final entry in cadFontAssets.entries) {
    final loader = FontLoader(entry.key);
    registerCadFontMetrics(entry.key, File(entry.value).readAsBytesSync());
    loader.addFont(
      Future.value(ByteData.sublistView(File(entry.value).readAsBytesSync())),
    );
    await loader.load();
  }
  await Directory('artifacts/qa').create(recursive: true);
  for (final family in [cadDefaultFontFamily, 'CADView Noto CJK']) {
    await prepareCadTextFontMetrics({'font_family': family});
  }
  await _checkVariants(multilingualSamples);
  await _checkVariants(extendedMultilingualSamples, prefix: 'extended-');
  await _checkTextEnvelopes();
  await _checkTextPlanePixels();
  await _checkAffineTextPixels();
  await _checkRichTextPixels();
  await _checkCapHeightPixels();
  await _checkMTextLineSpacingPixels();
}

Future<void> _checkMTextLineSpacingPixels() async {
  for (final factor in [0.75, 1.0, 2.0, 4.0]) {
    final document = multilingualCadDocument(samples: {'spacing': 'A\nA\nA'});
    final geometry =
        document.entities.single['geometry'] as Map<String, dynamic>;
    geometry.addAll({
      'origin': {'x': 400.0, 'y': 800.0},
      'height': 60.0,
      'line_spacing': {'factor': factor, 'style': 'exact'},
    });
    final recorder = ui.PictureRecorder();
    CadScenePainter(
      document: document,
      zoom: 1,
      pan: ui.Offset.zero,
    ).paint(ui.Canvas(recorder), const ui.Size(900, 1100));
    final picture = recorder.endRecording();
    final image = await picture.toImage(900, 1100);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      final starts = <int>[];
      var previousInk = false;
      for (var y = 0; y < 1100; y++) {
        var ink = false;
        for (var x = 0; x < 900; x++) {
          final at = (y * 900 + x) * 4;
          if (pixels[at] > 200 &&
              pixels[at + 1] > 200 &&
              pixels[at + 2] > 200) {
            ink = true;
            break;
          }
        }
        if (ink && !previousInk) starts.add(y);
        previousInk = ink;
      }
      if (starts.length != 3) {
        throw StateError('Missing paragraph rows: $starts');
      }
      final expected = 60 * (5 / 3) * factor * 0.88;
      for (var i = 1; i < starts.length; i++) {
        if ((starts[i] - starts[i - 1] - expected).abs() > 2) {
          throw StateError(
            'MTEXT factor $factor baseline spacing ${starts[i] - starts[i - 1]} != $expected',
          );
        }
      }
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  stdout.writeln('PASS: 4 MTEXT baseline-spacing pixel cases');
}

Future<void> _checkCapHeightPixels() async {
  for (final family in [
    cadDefaultFontFamily,
    'CADView Noto CJK',
    'Missing cap-height font',
    'Times New Roman',
  ]) {
    for (final reference in ['cap_height', 'em']) {
      for (final factor in [1.0, 2.0]) {
        final document = multilingualCadDocument(samples: {'cap': 'A'});
        final geometry =
            document.entities.single['geometry'] as Map<String, dynamic>;
        geometry.addAll({
          'origin': {'x': 400.0, 'y': 550.0},
          'height': 100.0,
          'height_reference': reference,
          'font_family': family,
          'text_runs': [
            {
              'start': 0,
              'end': 1,
              'style': {'height_factor': factor},
            },
          ],
        });
        if (!await prepareCadTextFontMetrics(geometry)) {
          throw StateError('Font calibration failed for $family');
        }
        final recorder = ui.PictureRecorder();
        CadScenePainter(
          document: document,
          zoom: 1,
          pan: ui.Offset.zero,
        ).paint(ui.Canvas(recorder), const ui.Size(900, 1100));
        final picture = recorder.endRecording();
        final image = await picture.toImage(900, 1100);
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final pixels = data!.buffer.asUint8List();
          var minY = 1100, maxY = -1;
          for (var y = 0; y < 1100; y++) {
            for (var x = 0; x < 900; x++) {
              final at = (y * 900 + x) * 4;
              if (pixels[at] > 200 &&
                  pixels[at + 1] > 200 &&
                  pixels[at + 2] > 200) {
                minY = math.min(minY, y);
                maxY = math.max(maxY, y);
              }
            }
          }
          // Independent CAD oracle: cap ink must equal the stated drawing
          // height under the known 0.88 camera scale, regardless of em metrics.
          final expected =
              100 *
              factor *
              0.88 *
              (reference == 'em' ? cadFontCapRatio(family) : 1);
          if ((maxY - minY + 1 - expected).abs() > 2) {
            throw StateError(
              '$family $reference $factor: cap ink ${maxY - minY + 1} != $expected',
            );
          }
        } finally {
          image.dispose();
          picture.dispose();
        }
      }
    }
  }
  stdout.writeln(
    'PASS: 16 independent cap-height/em and inline-height pixel checks',
  );
}

Future<void> _checkRichTextPixels() async {
  const value = 'F ⌀ 中文 العربية';
  Future<Uint8List> render(
    Map<String, dynamic> changes, {
    String? imageName,
  }) async {
    final document = multilingualCadDocument(samples: {'rich': value});
    final geometry =
        document.entities.single['geometry'] as Map<String, dynamic>;
    geometry.addAll({
      'origin': {'x': 100.0, 'y': 550.0},
      'height': 40.0,
      ...changes,
    });
    final recorder = ui.PictureRecorder();
    CadScenePainter(
      document: document,
      zoom: 1,
      pan: ui.Offset.zero,
    ).paint(ui.Canvas(recorder), const ui.Size(900, 1100));
    final picture = recorder.endRecording();
    final image = await picture.toImage(900, 1100);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (imageName != null) {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('artifacts/qa/cad-rich-$imageName.png')
            .writeAsBytes(png!.buffer.asUint8List());
      }
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  Map<String, dynamic> styled(Map<String, dynamic> style) => {
    'text_runs': [
      {'start': 0, 'end': value.length, 'style': style},
    ],
  };
  Set<int> ink(Uint8List pixels) => {
    for (var index = 0; index < 900 * 1100; index++)
      if (pixels[index * 4] > 200 &&
          pixels[index * 4 + 1] > 200 &&
          pixels[index * 4 + 2] > 200)
        index,
  };
  final plain = await render({}, imageName: 'plain');
  final source = await render({
    'font_family': 'CADView Noto CJK',
  }, imageName: 'font-reference');
  final rich = await render(
    styled({'font_family': 'CADView Noto CJK'}),
    imageName: 'font',
  );
  if (!_equal(source, rich) || _equal(plain, rich)) {
    final expectedInk = ink(source), actualInk = ink(rich);
    stdout.writeln(
      'Reference glyph count=${expectedInk.length}, inline=${actualInk.length}, '
      'intersection=${expectedInk.intersection(actualInk).length}, plainEqualsInline=${_equal(plain, rich)}',
    );
    throw StateError(
      'Inline font override differs from independently selected source font',
    );
  }
  final inherited = await render({
    'font_family': 'CADView Noto CJK',
    ...styled({'height_factor': 1.0}),
  });
  if (!_equal(source, inherited)) {
    throw StateError('Height-only inline run lost its inherited source family');
  }
  final missing = await render(styled({'font_family': 'Missing inline font'}));
  if (!_equal(plain, missing)) {
    throw StateError('Inline missing font lost offline fallback');
  }
  final plainInk = ink(plain);
  final decorated = ink(
    await render(
      styled({'underline': true, 'overline': true, 'strike_through': true}),
      imageName: 'decorations',
    ),
  );
  if (decorated.length <= plainInk.length + 100) {
    throw StateError('Inline decoration controls did not paint strokes');
  }
  final tall = ink(
    await render(styled({'height_factor': 2.0}), imageName: 'height'),
  );
  int extent(Set<int> mask) {
    final rows = mask.map((index) => index ~/ 900);
    return rows.reduce(math.max) - rows.reduce(math.min) + 1;
  }

  if (extent(tall) < extent(plainInk) * 1.8) {
    throw StateError('Inline height factor was ignored');
  }
  stdout.writeln(
    'PASS: real inline font, missing-font fallback, decoration and height pixels',
  );
}

// Independent pixel oracle: reflect the *untransformed* glyph raster, rather
// than trusting the same bounds/matrix code used by the renderer.
Future<void> _checkTextPlanePixels() async {
  const width = 900;
  const height = 1100;
  final masks = <String, Set<int>>{};
  for (final entry in <String, Map<String, double>?>{
    'identity': null,
    'mirror-x': {'xx': -1, 'xy': 0, 'yx': 0, 'yy': 1},
    'mirror-y': {'xx': 1, 'xy': 0, 'yx': 0, 'yy': -1},
    'swap-xy': {'xx': 0, 'xy': 1, 'yx': 1, 'yy': 0},
  }.entries) {
    final document = multilingualCadDocument(
      samples: {'plane': 'F ⌀ 中文 العربية'},
    );
    final geometry =
        document.entities.single['geometry'] as Map<String, dynamic>;
    geometry.addAll({
      'origin': {'x': 450.0, 'y': 550.0},
      'height': 64.0,
      // Keep both the original and swapped rasters wholly inside the canvas.
      'horizontal_alignment': 'center',
      if (entry.value != null) 'plane': entry.value,
    });
    final recorder = ui.PictureRecorder();
    CadScenePainter(
      document: document,
      zoom: 1,
      pan: ui.Offset.zero,
    ).paint(ui.Canvas(recorder), const ui.Size(900, 1100));
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      final mask = <int>{};
      for (var index = 0; index < width * height; index++) {
        final offset = index * 4;
        if (pixels[offset] > 200 &&
            pixels[offset + 1] > 200 &&
            pixels[offset + 2] > 200) {
          mask.add(index);
        }
      }
      if (mask.length < 100) {
        throw StateError('No real glyphs in ${entry.key} plane');
      }
      masks[entry.key] = mask;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('artifacts/qa/text-plane-${entry.key}.png')
          .writeAsBytes(png!.buffer.asUint8List());
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  for (final name in masks.keys.where((name) => name != 'identity')) {
    final expected = masks['identity']!.map((index) {
      final x = index % width;
      final y = index ~/ width;
      final (mappedX, mappedY) = switch (name) {
        'mirror-x' => (width - 1 - x, y),
        'mirror-y' => (x, height - 1 - y),
        _ => (999 - y, 999 - x),
      };
      return mappedY * width + mappedX;
    }).toSet();
    final actual = masks[name]!;
    for (final (source, target) in [(expected, actual), (actual, expected)]) {
      var matched = 0;
      for (final index in source) {
        var found = false;
        // One pixel tolerance for text antialiasing/hinting under reflection.
        for (var dy = -1; dy <= 1 && !found; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (target.contains(index + dy * width + dx)) {
              found = true;
              break;
            }
          }
        }
        if (found) matched++;
      }
      if (matched / source.length < 0.99) {
        throw StateError(
          '$name plane differs from independently reflected glyphs: $matched/${source.length}',
        );
      }
    }
  }
  stdout.writeln(
    'PASS: 3 text-plane orientations against independent pixel reflections',
  );
}

// Compose the reference by transforming a previously recorded, untransformed
// glyph picture. This never calls the painter's plane or bounds helpers.
Future<void> _checkAffineTextPixels() async {
  const width = 900;
  const height = 1100;
  final document = multilingualCadDocument(
    samples: {'affine': 'F ⌀ 中文\n日本語 العربية'},
  );
  final geometry = document.entities.single['geometry'] as Map<String, dynamic>;
  geometry.addAll({
    'origin': {'x': 450.0, 'y': 550.0},
    'height': 40.0,
    'horizontal_alignment': 'center',
    'wrap_width': 300.0,
  });
  final recorder = ui.PictureRecorder();
  CadScenePainter(
    document: document,
    zoom: 1,
    pan: ui.Offset.zero,
  ).paint(ui.Canvas(recorder), const ui.Size(900, 1100));
  final original = recorder.endRecording();
  Future<Set<int>> mask(ui.Picture picture, String name) async {
    final image = await picture.toImage(width, height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final pixels = data!.buffer.asUint8List();
      final ink = <int>{};
      for (var index = 0; index < width * height; index++) {
        final at = index * 4;
        if (pixels[at] > 200 && pixels[at + 1] > 200 && pixels[at + 2] > 200) {
          ink.add(index);
        }
      }
      if (ink.length < 100) throw StateError('No real affine glyphs: $name');
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('artifacts/qa/text-affine-$name.png')
          .writeAsBytes(png!.buffer.asUint8List());
      return ink;
    } finally {
      image.dispose();
    }
  }

  try {
    for (final (name, a, b, c, d) in [
      ('shear-scale', 1.2, 0.4, -0.3, 0.8),
      ('mirror-shear', -1.2, 0.4, 0.3, 0.8),
      ('tilted-scale', 0.7, -0.5, 0.6, 1.3),
    ]) {
      final referenceRecorder = ui.PictureRecorder();
      final canvas = ui.Canvas(referenceRecorder);
      canvas.translate(450, 550);
      // World Y is up, screen Y is down: F * P * F. No translation in P.
      canvas.transform(
        Float64List.fromList([
          a,
          -c,
          0,
          0,
          -b,
          d,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          1,
        ]),
      );
      canvas.translate(-450, -550);
      canvas.drawPicture(original);
      final reference = referenceRecorder.endRecording();
      geometry['plane'] = {'xx': a, 'xy': b, 'yx': c, 'yy': d};
      final actualRecorder = ui.PictureRecorder();
      CadScenePainter(
        document: document,
        zoom: 1,
        pan: ui.Offset.zero,
      ).paint(ui.Canvas(actualRecorder), const ui.Size(900, 1100));
      final actualPicture = actualRecorder.endRecording();
      try {
        final expected = await mask(reference, '$name-reference');
        final actual = await mask(actualPicture, name);
        for (final (source, target) in [
          (expected, actual),
          (actual, expected),
        ]) {
          var matched = 0;
          for (final index in source) {
            var found = false;
            for (var dy = -1; dy <= 1 && !found; dy++) {
              for (var dx = -1; dx <= 1; dx++) {
                if (target.contains(index + dy * width + dx)) {
                  found = true;
                  break;
                }
              }
            }
            if (found) matched++;
          }
          if (matched / source.length < 0.99) {
            throw StateError(
              '$name affine glyphs differ: $matched/${source.length}',
            );
          }
        }
      } finally {
        reference.dispose();
        actualPicture.dispose();
      }
    }
  } finally {
    original.dispose();
  }
  stdout.writeln(
    'PASS: 3 full affine text planes against independent picture transforms',
  );
}

Future<void> _checkVariants(
  Map<String, String> samples, {
  String prefix = '',
}) async {
  final rasters = <String, Uint8List>{};
  for (final entry in <String, String?>{
    'default': null,
    'missing': 'Missing source CAD font',
    'bundled': 'CADView Noto Sans',
    'source': 'CADView Noto CJK',
  }.entries) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    CadScenePainter(
      document: multilingualCadDocument(
        fontFamily: entry.value,
        samples: samples,
      ),
      zoom: 1,
      pan: ui.Offset.zero,
    ).paint(canvas, const ui.Size(900, 1100));
    final picture = recorder.endRecording();
    final image = await picture.toImage(900, 1100);
    final raster = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    rasters[entry.key] = raster!.buffer.asUint8List();
    _assertVisibleRows(
      rasters[entry.key]!,
      '$prefix${entry.key}',
      samples.length,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final path = 'artifacts/qa/cad-fonts-$prefix${entry.key}.png';
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    stdout.writeln('Rendered $path');
  }
  if (!_equal(rasters['default']!, rasters['bundled']!)) {
    throw StateError('Unspecified CAD font does not use the bundled default');
  }
  if (prefix.isEmpty && _equal(rasters['source']!, rasters['bundled']!)) {
    throw StateError('Explicit source font was ignored');
  }
  if (!_equal(rasters['missing']!, rasters['bundled']!)) {
    throw StateError('Missing source font does not use offline fallback');
  }
  stdout.writeln(
    'PASS: ${prefix.isEmpty ? "base" : "extended"} offline font raster checks',
  );
}

Future<void> _checkTextEnvelopes() async {
  final variants = <Map<String, dynamic>>[
    for (final horizontal in ['left', 'center', 'right'])
      for (final vertical in ['baseline', 'bottom', 'middle', 'top'])
        {'horizontal_alignment': horizontal, 'vertical_alignment': vertical},
    {'rotation': math.pi / 2},
    {'rotation': -math.pi / 3, 'oblique_angle': 0.35},
    {'mirrored_x': true},
    {'mirrored_y': true},
    {'mirrored_x': true, 'mirrored_y': true, 'oblique_angle': -0.35},
    {'width_factor': 0.6},
    {'target_width': 250},
    {'target_width': 250, 'uniform_fit': true},
    {'wrap_width': 180, 'vertical_alignment': 'top'},
    {'wrap_width': 180, 'width_factor': 0.6, 'rotation': 0.4},
    {'wrap_width': 180, 'mirrored_x': true, 'vertical_alignment': 'middle'},
    {'wrap_width': 180, 'horizontal_alignment': 'right', 'rotation': -0.4},
    for (final style in ['exact', 'at_least'])
      for (final factor in [0.25, 1.0, 4.0])
        {
          'line_spacing': {'factor': factor, 'style': style},
          'rich_style': {'height_factor': 4.0, 'underline': true},
          'wrap_width': 350,
          'rotation': -0.4,
          'mirrored_x': true,
        },
    {
      'rich_style': {
        'height_factor': 2.0,
        'underline': true,
        'font_family': 'CADView Noto CJK',
      },
    },
    {
      'rich_style': {'height_factor': 0.5, 'overline': true, 'italic': true},
      'wrap_width': 100,
    },
    {
      'rich_style': {
        'bold': true,
        'strike_through': true,
        'height_factor': 3.0,
      },
      'rotation': -0.4,
      'mirrored_x': true,
      'wrap_width': 180,
    },
    {
      'plane': {'xx': -1.0, 'xy': 0.0, 'yx': 0.0, 'yy': 1.0},
    },
    {
      'plane': {'xx': 1.0, 'xy': 0.0, 'yx': 0.0, 'yy': -1.0},
    },
    {
      'plane': {'xx': -1.0, 'xy': 0.0, 'yx': 0.0, 'yy': -0.8},
      'rotation': 0.45,
    },
    {
      'plane': {'xx': 0.6, 'xy': 0.8, 'yx': 0.8, 'yy': -0.6},
      'wrap_width': 180,
      'oblique_angle': 0.3,
    },
    {
      'plane': {'xx': -1.2, 'xy': 0.4, 'yx': 0.3, 'yy': 0.8},
      'wrap_width': 180,
      'rotation': 0.3,
    },
    {
      'plane': {'xx': 0.7, 'xy': -0.5, 'yx': 0.6, 'yy': 1.3},
      'wrap_width': 180,
      'width_factor': 0.6,
    },
    // Insertion points outside the viewport, with glyphs still visible.
    {
      'origin': {'x': -100, 'y': 550},
      'target_width': 350,
    },
    {
      'origin': {'x': 1000, 'y': 550},
      'target_width': 350,
      'mirrored_x': true,
    },
  ];
  const texts = [
    'e\u0301 ⌀ 12 中文\nالعَرَبِيَّة\nहिन्दी',
    'বাংলা ພາສາລາວ\nខ្មែរ မြန်မာ\nབོད་ཡིག සිංහල',
  ];
  for (var index = 0; index < variants.length * texts.length; index++) {
    final document = multilingualCadDocument();
    final entity =
        (document.scene['entities'] as List).first as Map<String, dynamic>;
    document.scene['entities'] = [entity];
    final geometry = entity['geometry'] as Map<String, dynamic>;
    geometry.addAll({
      'origin': {'x': 450, 'y': 550},
      'height': 32,
      'value': texts[index ~/ variants.length],
      ...variants[index % variants.length],
    });
    if (geometry.remove('rich_style') case final Map<String, dynamic> style) {
      geometry['text_runs'] = [
        {
          'start': 0,
          'end': (geometry['value'] as String).length,
          'style': style,
        },
      ];
    }
    final transform = CadViewTransform.forScene(
      document,
      const ui.Size(900, 1100),
      1,
      ui.Offset.zero,
    );
    // This standalone visual test intentionally uses the painter's test seam.
    // ignore: invalid_use_of_visible_for_testing_member
    final bounds = cadTextScreenBounds(geometry, transform);
    final recorder = ui.PictureRecorder();
    CadScenePainter(
      document: document,
      zoom: 1,
      pan: ui.Offset.zero,
    ).paint(ui.Canvas(recorder), const ui.Size(900, 1100));
    final picture = recorder.endRecording();
    final image = await picture.toImage(900, 1100);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgba = bytes!.buffer.asUint8List();
    var ink = 0;
    for (var y = 0; y < 1100; y++) {
      for (var x = 0; x < 900; x++) {
        final offset = (y * 900 + x) * 4;
        if (rgba[offset] <= 200 ||
            rgba[offset + 1] <= 200 ||
            rgba[offset + 2] <= 200) {
          continue;
        }
        ink++;
        if (!bounds.contains(ui.Offset(x + 0.5, y + 0.5))) {
          throw StateError(
            'Text variant $index has glyphs outside its envelope',
          );
        }
      }
    }
    image.dispose();
    picture.dispose();
    if (ink < 20) {
      throw StateError('Text variant $index was incorrectly culled');
    }
  }
  stdout.writeln(
    'PASS: ${variants.length * texts.length} real glyph/culling envelope checks',
  );
}

void _assertVisibleRows(Uint8List rgba, String variant, int rowCount) {
  // Keep blank-vs-blank comparisons from passing. The fixture uses a fit scale
  // of 0.88; inspect each complete text row, not background/grid pixels.
  for (var row = 0; row < rowCount; row++) {
    final baseline = (136.4 + row * 70.4).round();
    var ink = 0;
    for (var y = baseline - 40; y <= baseline + 20; y++) {
      for (var x = 60; x < 860; x++) {
        final offset = (y * 900 + x) * 4;
        if (rgba[offset] > 200 &&
            rgba[offset + 1] > 200 &&
            rgba[offset + 2] > 200) {
          ink++;
        }
      }
    }
    if (ink < 20) {
      throw StateError('Missing rendered row $row for font variant $variant');
    }
  }
}

bool _equal(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
