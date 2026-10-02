import 'dart:io';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_fonts.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/multilingual_fixture.dart';

const _samples = multilingualSamples;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled cmap covers UI characters and multilingual CAD samples', () {
    final coverage = <int>{};
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final entry in cadFontAssets.entries) {
      expect(pubspec, contains('family: ${entry.key}'));
      expect(pubspec, contains('asset: ${entry.value}'));
      coverage.addAll(_unicodeCmap(File(entry.value).readAsBytesSync()));
    }
    final source = File('lib/l10n/app_localizations.dart').readAsStringSync();
    final expected = [
      ..._samples.values,
      ...extendedMultilingualSamples.values,
      source,
    ].join('\n').runes.where((rune) => rune > 0x20 && rune != 0x7f);
    final missing = expected.where((rune) => !coverage.contains(rune)).toSet();
    expect(
      missing.map((rune) => 'U+${rune.toRadixString(16)}').toList(),
      isEmpty,
      reason:
          'Every UI character and declared script must have an offline glyph',
    );
  });

  test(
    'CAD direction follows first strong letter, ignoring numeric prefixes',
    () {
      expect(cadTextDirection('120 CAD العربية'), TextDirection.ltr);
      expect(cadTextDirection('120 العربية CAD'), TextDirection.rtl);
      expect(cadTextDirection('120 עברית CAD'), TextDirection.rtl);
      expect(cadTextDirection('中文 العربية'), TextDirection.ltr);
      expect(cadTextDirection('Հայերեն العربية'), TextDirection.ltr);
      expect(cadTextDirection('१२३ العربية'), TextDirection.rtl);
      expect(cadTextDirection('၀၁၂ العربية'), TextDirection.rtl);
      expect(cadTextDirection('\u{1ee00} CAD'), TextDirection.rtl);
      expect(cadTextDirection('\u{1e900} CAD'), TextDirection.rtl);
      expect(cadTextDirection('A\u{1e900}'), TextDirection.ltr);
      expect(cadTextDirection('ـالعربية CAD'), TextDirection.rtl);
      expect(cadTextDirection('\u0301 العربية CAD'), TextDirection.rtl);
      expect(cadTextDirection('⌀ 12.5'), TextDirection.ltr);
    },
  );

  test('default family is offline without overriding source fonts', () {
    expect(cadPrimaryFontFamily(null), cadDefaultFontFamily);
    expect(cadPrimaryFontFamily('   '), cadDefaultFontFamily);
    expect(cadPrimaryFontFamily(' Arial '), 'Arial');
    expect(cadPrimaryFontFamily('CADView Noto CJK'), 'CADView Noto CJK');
  });

  test('redistributed fonts are included in application licenses', () async {
    registerCadFontLicenses();
    final entries = await LicenseRegistry.licenses
        .where((entry) => entry.packages.contains('Noto fonts'))
        .toList();
    expect(entries, hasLength(2));
    for (final entry in entries) {
      expect(
        entry.paragraphs.map((paragraph) => paragraph.text).join('\n'),
        contains('SIL OPEN FONT LICENSE'),
      );
    }
  });

  testWidgets('real bundled fonts render accents, shaping and CAD symbols', (
    tester,
  ) async {
    for (final entry in cadFontAssets.entries) {
      final loader = FontLoader(entry.key);
      loader.addFont(
        Future.value(ByteData.sublistView(File(entry.value).readAsBytesSync())),
      );
      await loader.load();
    }
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'CADView Noto Sans',
          fontFamilyFallback: cadFontFallback,
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: Scaffold(
            backgroundColor: const Color(0xff0b1118),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in _samples.entries) ...[
                    Text(
                      entry.key,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      entry.value,
                      textDirection: cadTextDirection(entry.value),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        fontFamilyFallback: cadFontFallback,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('artifacts/qa');
      await directory.create(recursive: true);
      await File('${directory.path}/multilingual-text.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });

    // The headless engine script separately checks missing source fonts without
    // Ahem replacement. Here exercise unspecified CAD font metadata, baseline,
    // mixed direction and combining accents with the actual bundled default.
    final document = multilingualCadDocument();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: CustomPaint(
            painter: CadScenePainter(
              document: document,
              zoom: 1,
              pan: Offset.zero,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final cadBoundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await cadBoundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('artifacts/qa/multilingual-cad-text.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}

/// Read the actual sfnt Unicode cmap (formats 4/12), including glyph IDs. Font
/// family declarations alone cannot prove that a character avoids .notdef.
Set<int> _unicodeCmap(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var cmap = -1;
  for (var i = 0; i < data.getUint16(4); i++) {
    final table = 12 + i * 16;
    if (String.fromCharCodes(bytes.sublist(table, table + 4)) == 'cmap') {
      cmap = data.getUint32(table + 8);
      break;
    }
  }
  if (cmap < 0) throw FormatException('Font has no cmap');
  final result = <int>{};
  for (var i = 0; i < data.getUint16(cmap + 2); i++) {
    final record = cmap + 4 + i * 8;
    final platform = data.getUint16(record);
    final encoding = data.getUint16(record + 2);
    if (platform != 0 &&
        !(platform == 3 && (encoding == 1 || encoding == 10))) {
      continue;
    }
    final subtable = cmap + data.getUint32(record + 4);
    final format = data.getUint16(subtable);
    if (format == 12) {
      for (var j = 0; j < data.getUint32(subtable + 12); j++) {
        final group = subtable + 16 + j * 12;
        final start = data.getUint32(group);
        final end = data.getUint32(group + 4);
        final firstGlyph = data.getUint32(group + 8);
        for (var point = start; point <= end; point++) {
          if (firstGlyph + point - start != 0) result.add(point);
        }
      }
    } else if (format == 4) {
      final count = data.getUint16(subtable + 6) ~/ 2;
      final ends = subtable + 14;
      final starts = ends + count * 2 + 2;
      final deltas = starts + count * 2;
      final offsets = deltas + count * 2;
      for (var j = 0; j < count; j++) {
        final start = data.getUint16(starts + j * 2);
        final end = data.getUint16(ends + j * 2);
        final delta = data.getInt16(deltas + j * 2);
        final offset = data.getUint16(offsets + j * 2);
        for (var point = start; point <= end && point != 0xffff; point++) {
          final raw = offset == 0
              ? point
              : data.getUint16(offsets + j * 2 + offset + (point - start) * 2);
          if (offset != 0 && raw == 0) continue;
          if (((raw + delta) & 0xffff) != 0) result.add(point);
        }
      }
    }
  }
  return result;
}
