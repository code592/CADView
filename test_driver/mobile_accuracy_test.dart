import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data == null) return;
    final platform = data['platform'];
    if (platform != 'ios' && platform != 'android') {
      throw StateError('Unexpected mobile test platform: $platform');
    }
    final directory = Directory('artifacts/qa/mobile/$platform');
    await directory.create(recursive: true);
    final images = data.remove('images') as Map<String, dynamic>? ?? {};
    for (final variant in [
      'default',
      'missing',
      'bundled',
      'source',
      'extended-default',
      'extended-missing',
      'extended-bundled',
      'extended-source',
      'dxf',
      'dxf-binary',
      'dxf-layout',
      'dxf-rich',
      'dxf-r20',
      'pdf-export',
      'stl-export',
      'dwg-title',
      'dwg-armchair',
      'dwg-bedside',
      'dwg-nested-text',
      'dwg-array-text',
      'dwg-tilted-text',
      'dwg-attribute-text',
      'dwg-constant-text',
      'mtext-mask',
      'mtext-embedded',
      'mtext-embedded-exact',
      'mtext-columns-static',
      'mtext-columns-static-reversed',
      'mtext-columns-auto',
      'mtext-columns-auto-reversed',
      'mtext-columns-manual',
      'mtext-columns-manual-reversed',
    ]) {
      final encoded = images[variant] as String?;
      if (encoded != null) {
        await File('${directory.path}/fonts-$variant.png')
            .writeAsBytes(base64Decode(encoded));
      }
    }
    await File('${directory.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
);
