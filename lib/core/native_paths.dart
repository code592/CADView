import 'package:flutter/services.dart';

abstract final class NativePaths {
  static const _channel = MethodChannel('org.cadview/native_paths');

  static Future<String> applicationSupport() async {
    final path = await _channel.invokeMethod<String>('applicationSupportPath');
    if (path == null || path.isEmpty) {
      throw StateError('Native application support directory is unavailable');
    }
    return path;
  }
}
