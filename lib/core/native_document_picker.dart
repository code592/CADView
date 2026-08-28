import 'package:flutter/services.dart';

/// Android's MIME database does not recognize common CAD extensions such as
/// DWG and DXF. The native picker supplies their real-world MIME aliases plus
/// generic provider fallbacks; the caller must still validate the extension.
abstract final class NativeDocumentPicker {
  static const _channel = MethodChannel('org.cadview/document_picker');

  static Future<String?> pickDocument() =>
      _channel.invokeMethod<String>('pickDocument');
}
