import 'dart:async';
import 'dart:ui';

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_viewport_loader.dart';
import 'package:flutter_test/flutter_test.dart';

CadDocumentModel _document(String name) => CadDocumentModel(
  format: 'dxf',
  displayName: name,
  sceneKind: 'two_d',
  scene: {'layers': [], 'entities': []},
  diagnostics: [],
);

void main() {
  test('camera stays in exact guard band without requery/decode', () async {
    var calls = 0;
    final document = _document('retained');
    final loader = CadViewportLoader((bounds) async {
      calls++;
      expect(bounds, const Rect.fromLTRB(-50, -50, 150, 150));
      return document;
    });
    expect(await loader.load(const Rect.fromLTWH(0, 0, 100, 100)), document);
    expect(await loader.load(const Rect.fromLTWH(10, 10, 90, 90)), document);
    expect(await loader.load(const Rect.fromLTWH(50, 50, 100, 100)), document);
    expect(calls, 1);
  });

  test(
    'single flight coalesces many cameras to latest without losing geometry',
    () async {
      final requests = <Rect>[];
      final responses = <Completer<CadDocumentModel>>[];
      final loader = CadViewportLoader((bounds) {
        requests.add(bounds);
        final response = Completer<CadDocumentModel>();
        responses.add(response);
        return response.future;
      });
      final first = loader.load(const Rect.fromLTWH(0, 0, 100, 100));
      for (var i = 1; i < 100; i++) {
        unawaited(loader.load(Rect.fromLTWH(i * 100, 0, 100, 100)));
      }
      expect(requests, hasLength(1));
      responses.first.complete(_document('old'));
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(2));
      expect(requests.last, const Rect.fromLTRB(9850, -50, 10050, 150));
      final latest = _document('latest');
      responses.last.complete(latest);
      expect(await first, same(latest));
      expect(requests, hasLength(2));
    },
  );

  test('layer changes discard in-flight generation and fetch newly visible geometry', () async {
    final responses = <Completer<CadDocumentModel>>[];
    final loader = CadViewportLoader((bounds) {
      final response = Completer<CadDocumentModel>();
      responses.add(response);
      return response.future;
    });
    final first = loader.load(const Rect.fromLTWH(0, 0, 100, 100));
    loader.invalidate();
    final second = loader.load(const Rect.fromLTWH(0, 0, 100, 100));
    responses.first.complete(_document('hidden'));
    await Future<void>.delayed(Duration.zero);
    expect(responses, hasLength(2));
    final latest = _document('visible');
    responses.last.complete(latest);
    expect(await first, same(latest));
    expect(await second, same(latest));
  });

  test(
    'failure does not prevent retry; disposal does not start queued work',
    () async {
      var calls = 0;
      final loader = CadViewportLoader((bounds) async {
        if (++calls == 1) throw StateError('bad packet');
        return _document('retry');
      });
      await expectLater(
        loader.load(const Rect.fromLTWH(0, 0, 1, 1)),
        throwsStateError,
      );
      expect(
        (await loader.load(const Rect.fromLTWH(0, 0, 1, 1)))!.displayName,
        'retry',
      );
      loader.dispose();
      expect(await loader.load(const Rect.fromLTWH(0, 0, 1, 1)), isNull);
      expect(calls, 2);
    },
  );
}
