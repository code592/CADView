import 'dart:async';

/// At most one native preview query and one latest pending pointer position.
/// Superseded previews are not committed; pointer release can await its own
/// final position without queuing every intervening move.
class CadLatestPick<T, R> {
  CadLatestPick(this.query);

  final Future<R?> Function(T) query;
  ({T value, Completer<R?> result})? _pending;
  bool _running = false;
  int _generation = 0;

  Future<R?> request(T value) {
    _pending?.result.complete(null);
    final result = Completer<R?>();
    _pending = (value: value, result: result);
    if (!_running) unawaited(_drain());
    return result.future;
  }

  void cancel() {
    _generation++;
    _pending?.result.complete(null);
    _pending = null;
  }

  Future<void> _drain() async {
    _running = true;
    while (_pending != null) {
      final current = _pending!;
      _pending = null;
      final generation = _generation;
      try {
        final result = await query(current.value);
        current.result.complete(generation == _generation ? result : null);
      } catch (error, stack) {
        current.result.completeError(error, stack);
      }
    }
    _running = false;
  }
}

/// Preserve deliberate tap order, while invalidating all pending picks when
/// the tool, camera, document visibility or measurement state changes.
class CadPickQueue {
  Future<void> _tail = Future.value();
  int _generation = 0;

  void cancel() => _generation++;

  Future<void> add(Future<void> Function(bool Function() current) action) {
    final generation = _generation;
    bool current() => generation == _generation;
    final result = _tail.then((_) async {
      if (current()) await action(current);
    });
    // A failed query must not poison later picks; the caller handles its error.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
