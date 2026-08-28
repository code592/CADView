import 'dart:async';

import 'package:flutter/services.dart';

/// Receives files opened or shared from another application.
///
/// Native code first copies provider-backed files into CADView's private
/// imports directory. The Rust format registry then probes the actual file
/// signature instead of trusting the sender's MIME type or extension.
abstract final class IncomingDocuments {
  static const _channel = MethodChannel('org.cadview/incoming_files');
  static final _files = StreamController<String>.broadcast();
  static bool _initialized = false;
  static bool _draining = false;
  static bool _drainAgain = false;

  static Stream<String> get files => _files.stream;

  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'incomingFilesAvailable') {
        await _drain();
      }
    });
    await _drain();
  }

  static Future<void> _drain() async {
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    try {
      do {
        _drainAgain = false;
        final paths = await _channel.invokeListMethod<String>(
          'takePendingFiles',
        );
        for (final path in paths ?? const <String>[]) {
          if (path.isNotEmpty) _files.add(path);
        }
      } while (_drainAgain);
    } on MissingPluginException {
      // Desktop/widget-test builds do not provide the mobile channel.
    } finally {
      _draining = false;
    }
  }
}
