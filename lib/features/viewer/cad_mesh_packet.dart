import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'cad_mesh_render_index.dart';

/// Lossless CAD3D001 runtime transport, not a public file/cache format.
/// Numeric buffers are retained instead of materializing per-vertex maps.
Map<String, dynamic> decodeCadMeshPacket(Uint8List bytes) {
  if (bytes.length < 32 || ascii.decode(bytes.sublist(0, 8)) != 'CAD3D001') {
    throw const FormatException('Unsupported CAD mesh packet');
  }
  final data = ByteData.sublistView(bytes);
  int word(int offset) => data.getUint32(offset, Endian.little);
  final metadataSize = word(8);
  final meshCount = word(12);
  final vertexCount = word(16);
  final normalCount = word(20);
  final indexCount = word(24);
  if (metadataSize > bytes.length - 32 ||
      word(28) != 0 ||
      meshCount > 5000000 ||
      indexCount > 15000000 ||
      indexCount % 3 != 0) {
    throw const FormatException('Invalid CAD mesh packet header');
  }
  final directory = ((32 + metadataSize + 7) ~/ 8) * 8;
  final positions = ((directory + meshCount * 12 + 7) ~/ 8) * 8;
  final normals = positions + vertexCount * 24;
  final indices = normals + normalCount * 12;
  if (indices + indexCount * 4 != bytes.length) {
    throw const FormatException('Invalid CAD mesh packet length');
  }
  final document = jsonDecode(
    utf8.decode(Uint8List.sublistView(bytes, 32, 32 + metadataSize)),
  ) as Map<String, dynamic>;
  final envelope = document['scene'] as Map<String, dynamic>;
  if (envelope['scene_kind'] != 'three_d') {
    throw const FormatException('CAD mesh packet kind mismatch');
  }
  final scene = envelope['scene'] as Map<String, dynamic>;
  final metadata = scene['meshes'] as List;
  if (metadata.length != meshCount) {
    throw const FormatException('CAD mesh packet directory mismatch');
  }
  Float64List doubles(int offset, int count) {
    // FRB can provide a byte slice whose underlying buffer is unaligned.
    // In that case copy exact numeric bits once, never via JSON/float32.
    if (Endian.host == Endian.little &&
        (bytes.offsetInBytes + offset) % 8 == 0) {
      return Float64List.view(
        bytes.buffer,
        bytes.offsetInBytes + offset,
        count,
      ).asUnmodifiableView();
    }
    final values = Float64List(count);
    for (var i = 0; i < count; i++) {
      values[i] = data.getFloat64(offset + i * 8, Endian.little);
    }
    return values.asUnmodifiableView();
  }

  Float32List floats(int offset, int count) {
    if (Endian.host == Endian.little &&
        (bytes.offsetInBytes + offset) % 4 == 0) {
      return Float32List.view(
        bytes.buffer,
        bytes.offsetInBytes + offset,
        count,
      ).asUnmodifiableView();
    }
    final values = Float32List(count);
    for (var i = 0; i < count; i++) {
      values[i] = data.getFloat32(offset + i * 4, Endian.little);
    }
    return values.asUnmodifiableView();
  }

  Uint32List integers(int offset, int count) {
    if (Endian.host == Endian.little &&
        (bytes.offsetInBytes + offset) % 4 == 0) {
      return Uint32List.view(
        bytes.buffer,
        bytes.offsetInBytes + offset,
        count,
      ).asUnmodifiableView();
    }
    final values = Uint32List(count);
    for (var i = 0; i < count; i++) {
      values[i] = data.getUint32(offset + i * 4, Endian.little);
    }
    return values.asUnmodifiableView();
  }

  final meshes = <Map<String, dynamic>>[];
  final ids = <int>{};
  var vertexStart = 0, normalStart = 0, indexStart = 0;
  for (var i = 0; i < meshCount; i++) {
    final p = word(directory + i * 12);
    final n = word(directory + i * 12 + 4);
    final t = word(directory + i * 12 + 8);
    final info = metadata[i] as Map<String, dynamic>;
    if (vertexStart + p > vertexCount ||
        normalStart + n > normalCount ||
        indexStart + t > indexCount ||
        t % 3 != 0 ||
        info['id'] is! int ||
        !ids.add(info['id'] as int)) {
      throw const FormatException('Invalid CAD mesh packet ranges/identity');
    }
    final xyz = doubles(positions + vertexStart * 24, p * 3);
    final norm = floats(normals + normalStart * 12, n * 3);
    final topology = integers(indices + indexStart * 4, t);
    if (norm.any((v) => !v.isFinite)) {
      throw const FormatException('Invalid CAD mesh packet geometry');
    }
    meshes.add(CadPackedMesh(info, xyz, norm, topology));
    vertexStart += p;
    normalStart += n;
    indexStart += t;
  }
  if (vertexStart != vertexCount ||
      normalStart != normalCount ||
      indexStart != indexCount) {
    throw const FormatException('Incomplete CAD mesh packet');
  }
  scene['meshes'] = List<Map<String, dynamic>>.unmodifiable(meshes);
  return document;
}

class CadPackedMesh extends MapBase<String, dynamic> {
  CadPackedMesh(
    Map<String, dynamic> info,
    this.coordinates,
    Float32List normals,
    this.indices,
  ) : _info = Map<String, dynamic>.unmodifiable(info),
      _normals = _PackedNormals(normals),
      renderIndex = CadMeshRenderIndex.build(coordinates, indices);
  final Map<String, dynamic> _info;
  final Float64List coordinates;
  final Uint32List indices;
  final CadMeshRenderIndex renderIndex;
  late final _positions = _PackedPositions(coordinates);
  final _PackedNormals _normals;
  @override
  Iterable<String> get keys => [
    ..._info.keys,
    'positions',
    'normals',
    'indices',
  ];
  @override
  dynamic operator [](Object? key) => switch (key) {
    'positions' => _positions,
    'normals' => _normals,
    'indices' => indices,
    _ => _info[key],
  };
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('Read-only CAD mesh');
  @override
  void clear() => throw UnsupportedError('Read-only CAD mesh');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('Read-only CAD mesh');
}

class _PackedPositions extends ListBase<Map<String, dynamic>> {
  _PackedPositions(this.xyz);
  final Float64List xyz;
  @override
  int get length => xyz.length ~/ 3;
  @override
  set length(int value) => throw UnsupportedError('Read-only CAD mesh');
  @override
  Map<String, dynamic> operator [](int i) {
    RangeError.checkValidIndex(i, this);
    return Map<String, dynamic>.unmodifiable({
      'x': xyz[i * 3],
      'y': xyz[i * 3 + 1],
      'z': xyz[i * 3 + 2],
    });
  }

  @override
  void operator []=(int i, Map<String, dynamic> value) =>
      throw UnsupportedError('Read-only CAD mesh');
}

class _PackedNormals extends ListBase<List<double>> {
  _PackedNormals(this.xyz);
  final Float32List xyz;
  @override
  int get length => xyz.length ~/ 3;
  @override
  set length(int value) => throw UnsupportedError('Read-only CAD mesh');
  @override
  List<double> operator [](int i) {
    RangeError.checkValidIndex(i, this);
    return Float32List.sublistView(xyz, i * 3, i * 3 + 3).asUnmodifiableView();
  }

  @override
  void operator []=(int i, List<double> value) =>
      throw UnsupportedError('Read-only CAD mesh');
}
