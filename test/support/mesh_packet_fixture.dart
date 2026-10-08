import 'dart:convert';
import 'dart:typed_data';

// Independent test writer: never calls the production Rust encoder.
Uint8List meshPacketFixture(Map<String, dynamic> document) {
  final scene = (document['scene'] as Map)['scene'] as Map;
  final meshes = scene['meshes'] as List;
  final metadata = utf8.encode(
    jsonEncode({
      ...document,
      'scene': {
        'scene_kind': 'three_d',
        'scene': {
          ...scene,
          'meshes': [
            for (final mesh in meshes)
              {
                for (final entry in (mesh as Map).entries)
                  if (!['positions', 'normals', 'indices'].contains(entry.key))
                    entry.key: entry.value,
              },
          ],
        },
      },
    }),
  );
  final out = BytesBuilder()..add(ascii.encode('CAD3D001'));
  void word(int n) => out.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  for (final n in [
    metadata.length,
    meshes.length,
    meshes.fold<int>(0, (n, m) => n + (m['positions'] as List).length),
    meshes.fold<int>(0, (n, m) => n + ((m['normals'] as List?) ?? []).length),
    meshes.fold<int>(0, (n, m) => n + (m['indices'] as List).length),
    0,
  ]) {
    word(n);
  }
  out.add(metadata);
  while (out.length % 8 != 0) {
    out.addByte(0);
  }
  for (final mesh in meshes) {
    word((mesh['positions'] as List).length);
    word(((mesh['normals'] as List?) ?? []).length);
    word((mesh['indices'] as List).length);
  }
  while (out.length % 8 != 0) {
    out.addByte(0);
  }
  for (final mesh in meshes) {
    for (final p in mesh['positions'] as List) {
      for (final axis in ['x', 'y', 'z']) {
        out.add(
          (ByteData(8)
                ..setFloat64(0, (p[axis] as num).toDouble(), Endian.little))
              .buffer
              .asUint8List(),
        );
      }
    }
  }
  for (final mesh in meshes) {
    for (final n in (mesh['normals'] as List?) ?? []) {
      for (final v in n as List) {
        out.add(
          (ByteData(4)..setFloat32(0, (v as num).toDouble(), Endian.little))
              .buffer
              .asUint8List(),
        );
      }
    }
  }
  for (final mesh in meshes) {
    for (final i in mesh['indices'] as List) {
      word(i as int);
    }
  }
  return out.takeBytes();
}
