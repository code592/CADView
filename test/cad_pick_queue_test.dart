import 'dart:async';

import 'package:cad_view/features/viewer/cad_pick_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'preview moves coalesce, and release waits for its exact last point',
    () async {
      final requests = <int>[];
      final replies = <Completer<int?>>[];
      final query = CadLatestPick<int, int>((value) {
        requests.add(value);
        final reply = Completer<int?>();
        replies.add(reply);
        return reply.future;
      });
      final first = query.request(0);
      final moves = [for (var i = 1; i <= 100; i++) query.request(i)];
      final release = query.request(101);
      expect(requests, [0]);
      expect(await Future.wait(moves), everyElement(isNull));
      replies.first.complete(0);
      expect(await first, 0);
      expect(requests, [0, 101]);
      replies.last.complete(101);
      expect(await release, 101);
    },
  );

  test(
    'cancel discards running and pending previews, then allows a new hold',
    () async {
      final reply = Completer<int?>();
      final requests = <int>[];
      final query = CadLatestPick<int, int>((value) {
        requests.add(value);
        return value == 1 ? reply.future : Future.value(value);
      });
      final running = query.request(1);
      final pending = query.request(2);
      query.cancel();
      final next = query.request(3);
      expect(await pending, isNull);
      reply.complete(1);
      expect(await running, isNull);
      expect(await next, 3);
      expect(requests, [1, 3]);
    },
  );

  test(
    'deliberate taps remain ordered; cancellation skips queued work',
    () async {
      final queue = CadPickQueue();
      final gate = Completer<void>();
      final committed = <int>[];
      final first = queue.add((current) async {
        await gate.future;
        if (current()) committed.add(1);
      });
      final second = queue.add((current) async => committed.add(2));
      await Future<void>.delayed(Duration.zero);
      expect(committed, isEmpty);
      queue.cancel();
      final third = queue.add((current) async => committed.add(3));
      gate.complete();
      await Future.wait([first, second, third]);
      expect(committed, [3]);
    },
  );

  test(
    'failed queries do not poison later preview or committed picks',
    () async {
      final query = CadLatestPick<int, int>((value) async {
        if (value == 1) throw StateError('bad pick');
        return value;
      });
      await expectLater(query.request(1), throwsStateError);
      expect(await query.request(2), 2);
      final queue = CadPickQueue();
      await expectLater(
        queue.add((_) async => throw StateError('bad pick')),
        throwsStateError,
      );
      var committed = false;
      await queue.add((_) async => committed = true);
      expect(committed, isTrue);
    },
  );
}
