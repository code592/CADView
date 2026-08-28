import 'package:cad_view/core/incoming_documents.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('drains files supplied by the native open/share channel', () async {
    const channel = MethodChannel('org.cadview/incoming_files');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'takePendingFiles');
          return ['/private/imports/model.dwg'];
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final received = IncomingDocuments.files.first;
    await IncomingDocuments.initialize();

    expect(await received, '/private/imports/model.dwg');
  });
}
