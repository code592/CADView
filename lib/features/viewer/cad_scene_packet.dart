import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'cad_mesh_packet.dart';

Map<String, dynamic> decodeCadDocumentPacket(Uint8List bytes) =>
    bytes.length >= 8 && ascii.decode(bytes.sublist(0, 8)) == 'CAD3D001'
    ? decodeCadMeshPacket(bytes)
    : decodeCadScenePacket(bytes);

/// Runtime wire format CAD2D001. Geometry is retained as exact little-endian
/// f64 values, not a million nested Dart maps. Text keeps its full JSON schema.
Map<String, dynamic> decodeCadScenePacket(Uint8List bytes) {
  if (bytes.length < 32 || ascii.decode(bytes.sublist(0, 8)) != 'CAD2D001') {
    throw const FormatException('Unsupported CAD scene packet');
  }
  final data = ByteData.sublistView(bytes);
  int word(int offset) => data.getUint32(offset, Endian.little);
  final metadataSize = word(8);
  final count = word(12);
  final coordinateCount = word(16);
  final styleCount = word(20);
  final dashCount = word(24);
  final fallbackSize = word(28);
  if (metadataSize > bytes.length - 32 ||
      count > 5000000 ||
      styleCount > count) {
    throw const FormatException('Invalid CAD scene packet header');
  }
  final records = ((32 + metadataSize + 7) ~/ 8) * 8;
  final styles = records + count * 32;
  final coordinates = styles + styleCount * 24;
  final dashes = coordinates + coordinateCount * 8;
  final fallbackStart = dashes + dashCount * 8;
  if (fallbackStart + fallbackSize != bytes.length || count > 5000000) {
    throw const FormatException('Invalid CAD scene packet length/count');
  }
  final document = jsonDecode(
    utf8.decode(Uint8List.sublistView(bytes, 32, 32 + metadataSize)),
  ) as Map<String, dynamic>;
  final envelope = document['scene'] as Map<String, dynamic>;
  if (envelope['scene_kind'] != 'two_d') {
    throw const FormatException('CAD scene packet kind mismatch');
  }
  final styleValues = <Map<String, dynamic>>[];
  for (var i = 0; i < styleCount; i++) {
    final offset = styles + i * 24;
    final flags = word(offset + 4);
    final start = word(offset + 16);
    final length = word(offset + 20);
    if (flags > 1 || start + length > dashCount) {
      throw const FormatException('Invalid CAD packet style');
    }
    styleValues.add(
      Map<String, dynamic>.unmodifiable({
        'color_argb': word(offset),
        'filled': flags == 1,
        'stroke_width': data.getFloat64(offset + 8, Endian.little),
        if (length != 0)
          'dash': Float64List.fromList([
            for (var j = 0; j < length; j++)
              data.getFloat64(dashes + (start + j) * 8, Endian.little),
          ]),
      }),
    );
  }
  final fallback = <int, Map<String, dynamic>>{};
  var orderedIds = true;
  var previousId = 0;
  // Validate every range once off the UI isolate. Never accept truncated or
  // sampled packets as a successfully opened drawing.
  for (var i = 0; i < count; i++) {
    final offset = records + i * 32;
    final id = data.getUint64(offset, Endian.little);
    if (i > 0 && id < previousId) orderedIds = false;
    previousId = id;
    final flags = word(offset + 20);
    final kind = flags & 255;
    final start = word(offset + 24);
    final length = word(offset + 28);
    if (word(offset + 16) >= styleCount ||
        flags & ~0x1ff != 0 ||
        kind > 5 ||
        (kind != 3 && flags >> 8 != 0)) {
      throw const FormatException('Invalid CAD packet entity');
    }
    if (kind == 0) {
      if (length == 0 || start + length > fallbackSize) {
        throw const FormatException('Invalid CAD packet text range');
      }
      final entity = jsonDecode(
        utf8.decode(
          Uint8List.sublistView(
            bytes,
            fallbackStart + start,
            fallbackStart + start + length,
          ),
        ),
      ) as Map<String, dynamic>;
      if (entity['id'] != data.getUint64(offset, Endian.little) ||
          entity['layer_id'] != data.getUint64(offset + 8, Endian.little)) {
        throw const FormatException('CAD packet text identity mismatch');
      }
      fallback[i] = entity;
    } else if (start + length > coordinateCount ||
        switch (kind) {
          1 => length != 2,
          2 => length != 4,
          3 => length.isOdd,
          4 => length != 3,
          5 => length != 5,
          _ => true,
        }) {
      throw const FormatException('Invalid CAD packet coordinate range');
    }
  }
  (envelope['scene'] as Map<String, dynamic>)['entities'] = CadPackedEntities._(
    data,
    records,
    coordinates,
    styleValues,
    fallback,
    0,
    count,
    orderedIds,
  );
  return document;
}

abstract class _ReadonlyMap extends MapBase<String, dynamic> {
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('Read-only CAD scene');
  @override
  void clear() => throw UnsupportedError('Read-only CAD scene');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('Read-only CAD scene');
}

/// List slices also retain a range view, not eagerly generated entity maps.
class CadPackedEntities extends ListBase<Map<String, dynamic>> {
  CadPackedEntities._(
    this._data,
    this._records,
    this._coordinates,
    this._styles,
    this._fallback,
    this._first,
    this._count,
    this._orderedIds,
  );
  final ByteData _data;
  final int _records, _coordinates, _first, _count;
  final List<Map<String, dynamic>> _styles;
  final Map<int, Map<String, dynamic>> _fallback;
  final bool _orderedIds;
  @override
  int get length => _count;
  @override
  set length(int value) => throw UnsupportedError('Read-only CAD scene');
  int _offset(int i) => _records + (_first + i) * 32;
  int idAt(int i) => _data.getUint64(_offset(i), Endian.little);

  /// IDs are checked once while decoding off the UI isolate. Lower-bound
  /// lookup preserves the first source occurrence even for duplicate IDs.
  /// Unsorted packets retain exact source-order lookup without map allocation.
  int indexOfId(int id) {
    if (_orderedIds) {
      var low = 0, high = length;
      while (low < high) {
        final middle = low + ((high - low) ~/ 2);
        if (idAt(middle) < id) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      return low < length && idAt(low) == id ? low : -1;
    }
    for (var i = 0; i < length; i++) {
      if (idAt(i) == id) return i;
    }
    return -1;
  }

  /// Return every source occurrence, including duplicate IDs. An unsorted
  /// packet needs only one numeric scan, regardless of selection size.
  Iterable<int> indicesOfIds(Set<int> ids) sync* {
    if (_orderedIds) {
      for (final id in ids) {
        final first = indexOfId(id);
        if (first < 0) continue;
        for (var i = first; i < length && idAt(i) == id; i++) {
          yield i;
        }
      }
    } else {
      for (var i = 0; i < length; i++) {
        if (ids.contains(idAt(i))) yield i;
      }
    }
  }

  int layerAt(int i) => _data.getUint64(_offset(i) + 8, Endian.little);
  int kindAt(int i) => _data.getUint32(_offset(i) + 20, Endian.little) & 255;
  Map<String, dynamic> styleAt(int i) =>
      _styles[_data.getUint32(_offset(i) + 16, Endian.little)];
  double coordinateAt(int i, int component) {
    RangeError.checkValidIndex(i, this);
    final offset = _offset(i);
    RangeError.checkValidRange(
      component,
      component + 1,
      _data.getUint32(offset + 28, Endian.little),
    );
    final start = _data.getUint32(offset + 24, Endian.little);
    return _data.getFloat64(
      _coordinates + (start + component) * 8,
      Endian.little,
    );
  }

  /// Number of f64 values of record [i] (two per polyline vertex).
  int coordinateCountAt(int i) {
    RangeError.checkValidIndex(i, this);
    return _data.getUint32(_offset(i) + 28, Endian.little);
  }

  /// Whether polyline record [i] is closed.
  bool closedAt(int i) {
    RangeError.checkValidIndex(i, this);
    return _data.getUint32(_offset(i) + 20, Endian.little) >> 8 == 1;
  }

  bool hasVisibleMasks(Map<int, bool> visible) =>
      _fallback.entries.any((entry) {
        if (entry.key < _first || entry.key >= _first + length) return false;
        final entity = entry.value;
        return (visible[entity['layer_id']] ?? true) &&
            (entity['geometry'] as Map)['background'] != null;
      });

  @override
  Map<String, dynamic> operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _fallback[_first + index] ?? _EntityView(this, index);
  }

  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      throw UnsupportedError('Read-only CAD scene');
  @override
  CadPackedEntities sublist(int start, [int? end]) {
    final stop = RangeError.checkValidRange(start, end, length);
    return CadPackedEntities._(
      _data,
      _records,
      _coordinates,
      _styles,
      _fallback,
      _first + start,
      stop - start,
      _orderedIds,
    );
  }
}

class _EntityView extends _ReadonlyMap {
  _EntityView(this.source, this.index);
  final CadPackedEntities source;
  final int index;
  int get offset => source._offset(index);
  Map<String, dynamic> get style =>
      source._styles[source._data.getUint32(offset + 16, Endian.little)];
  late final _geometry = _GeometryView(source, offset);
  @override
  Iterable<String> get keys => ['id', 'layer_id', ...style.keys, 'geometry'];
  @override
  dynamic operator [](Object? key) => switch (key) {
    'id' => source.idAt(index),
    'layer_id' => source._data.getUint64(offset + 8, Endian.little),
    'geometry' => _geometry,
    _ => style[key],
  };
}

class _GeometryView extends _ReadonlyMap {
  _GeometryView(this.source, this.offset);
  final CadPackedEntities source;
  final int offset;
  int get flags => source._data.getUint32(offset + 20, Endian.little);
  int get kind => flags & 255;
  int get start => source._data.getUint32(offset + 24, Endian.little);
  int get count => source._data.getUint32(offset + 28, Endian.little);
  double number(int i) => source._data.getFloat64(
    source._coordinates + (start + i) * 8,
    Endian.little,
  );
  Map<String, dynamic> point(int i) => {'x': number(i), 'y': number(i + 1)};
  @override
  Iterable<String> get keys => switch (kind) {
    1 => const ['kind', 'position'],
    2 => const ['kind', 'start', 'end'],
    3 => const ['kind', 'points', 'closed'],
    4 => const ['kind', 'center', 'radius'],
    5 => const ['kind', 'center', 'radius', 'start_angle', 'end_angle'],
    _ => const [],
  };
  @override
  dynamic operator [](Object? key) {
    if (key == 'kind') {
      return const ['', 'point', 'line', 'polyline', 'circle', 'arc'][kind];
    }
    if (!keys.contains(key)) return null;
    return switch (key) {
      'position' || 'start' || 'center' => point(0),
      'end' => point(2),
      'points' => _Points(this),
      'closed' => flags >> 8 == 1,
      'radius' => number(2),
      'start_angle' => number(3),
      'end_angle' => number(4),
      _ => null,
    };
  }
}

class _Points extends ListBase<Map<String, dynamic>> {
  _Points(this.geometry);
  final _GeometryView geometry;
  @override
  int get length => geometry.count ~/ 2;
  @override
  set length(int value) => throw UnsupportedError('Read-only CAD scene');
  @override
  Map<String, dynamic> operator [](int i) {
    RangeError.checkValidIndex(i, this);
    return geometry.point(i * 2);
  }

  @override
  void operator []=(int i, Map<String, dynamic> value) =>
      throw UnsupportedError('Read-only CAD scene');
}
