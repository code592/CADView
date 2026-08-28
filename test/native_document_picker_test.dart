import 'package:cad_view/core/native_document_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uses the native CAD document picker channel', () async {
    const channel = MethodChannel('org.cadview/document_picker');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickDocument');
          return '/private/imports/model.dwg';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(
      await NativeDocumentPicker.pickDocument(),
      '/private/imports/model.dwg',
    );
  });
}
