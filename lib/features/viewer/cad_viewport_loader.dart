import 'dart:ui';

import 'cad_document_model.dart';

/// One native query/decode at a time, with only the latest pending camera.
/// Reuse the exact retained geometry while the camera stays in its guard band.
/// No sampling, timers or work is performed while the view is idle.
class CadViewportLoader {
  CadViewportLoader(this.fetch);

  final Future<CadDocumentModel> Function(Rect bounds) fetch;
  Rect? _coverage;
  Rect? _pending;
  CadDocumentModel? _retained;
  Future<CadDocumentModel?>? _flight;
  int _generation = 0;
  bool _disposed = false;

  void invalidate() {
    _generation++;
    _coverage = null;
    _retained = null;
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    invalidate();
  }

  static bool _contains(Rect outer, Rect inner) =>
      outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom;

  Future<CadDocumentModel?> load(Rect visible) {
    if (_disposed) return Future.value(null);
    _pending = visible;
    return _flight ??= _drain().whenComplete(() => _flight = null);
  }

  Future<CadDocumentModel?> _drain() async {
    while (!_disposed && _pending != null) {
      final visible = _pending!;
      _pending = null;
      if (_coverage != null && _contains(_coverage!, visible)) continue;
      final generation = _generation;
      final guardBand = visible.inflate(
        (visible.width > visible.height ? visible.width : visible.height) * 0.5,
      );
      final document = await fetch(guardBand);
      if (_disposed) return null;
      if (generation != _generation) continue;
      _coverage = guardBand;
      _retained = document;
    }
    return _retained;
  }
}
