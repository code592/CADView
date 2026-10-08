import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data == null) return;
    final platform = data['platform'];
    if (platform != 'ios' && platform != 'android') {
      throw StateError('Unexpected platform');
    }
    final directory = Directory('artifacts/qa/performance/mobile/$platform');
    await directory.create(recursive: true);
    await File('${directory.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
);
