import 'dart:convert';
import 'dart:typed_data';

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_mesh_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_packet_fixture.dart';

Map<String, dynamic> _source({bool empty = false}) => {
  'metadata': {
    'format': 'obj',
    'display_name': '完整_mesh',
    'units': 'millimeters',
  },
  'diagnostics': [],
  'scene': {
    'scene_kind': 'three_d',
    'scene': {
      'root_nodes': [
        {
          'id': 0,
          'name': 'root',
          'visible': true,
          'mesh_ids': [42],
          'children': [],
        },
      ],
      'materials': [
        {
          'name': '材质',
          'base_color': [0.25, 0.5, 1.0, 1.0],
          'metallic': 0.0,
          'roughness': 1.0,
        },
      ],
      'stats': {'mesh_count': 1, 'vertex_count': 3, 'triangle_count': 1},
      'meshes': empty
          ? []
          : [
              {
                'id': 42,
                'name': '部件_日本語',
                'material_index': 0,
                'surface_area': 0.5,
                'closed_manifold': false,
                'enclosed_volume': null,
                'volume_centroid': null,
                'positions': [
                  {'x': 1e12 + 0.125, 'y': -0.0, 'z': 0.0},
                  {'x': 1e12 + 1.125, 'y': 0.0, 'z': 0.0},
                  {'x': 1e12 + 0.125, 'y': 1.0, 'z': 0.0},
                ],
                'normals': [
                  [0.25, -0.5, 1.0],
                  [0.25, -0.5, 1.0],
                  [0.25, -0.5, 1.0],
                ],
                'indices': [2, 0, 1],
              },
            ],
    },
  },
};

void main() {
  test('mesh buffers retain f64 geometry, topology, properties and exact measurements', () {
    final original = _source();
    final decoded = decodeCadMeshPacket(meshPacketFixture(original));
    expect(jsonDecode(jsonEncode(decoded)), original);
    final model = CadDocumentModel.fromJson(decoded);
    final mesh = model.meshes.single as CadPackedMesh;
    expect(mesh.coordinates, isA<Float64List>());
    expect(mesh.indices, isA<Uint32List>());
    expect(mesh.coordinates.first, 1e12 + 0.125);
    expect(mesh.coordinates[1].isNegative, isTrue);
    expect(() => mesh.coordinates[0] = 0, throwsUnsupportedError);
    expect(() => mesh.indices[0] = 0, throwsUnsupportedError);
    expect(() => mesh['normals'][0][0] = 0.0, throwsUnsupportedError);
    expect(() => mesh['positions'][0]['x'] = 0, throwsUnsupportedError);
    expect(() => mesh['name'] = 'changed', throwsUnsupportedError);
    final metrics = cadMeshTriangleMetrics3D(mesh, 0)!;
    expect(metrics.area, 0.5);
    expect(metrics.perimeter, 2 + 1.4142135623730951);
    expect(metrics.normal!.z, 1);
    expect(model.visibleMeshIds, {42});
    expect(
      CadDocumentModel.fromJson(
        decodeCadMeshPacket(meshPacketFixture(_source(empty: true))),
      ).meshes,
      isEmpty,
    );
  });
  test('unaligned slices preserve exact values and native f32 normal bits', () {
    final source = _source();
    final meshes = ((source['scene'] as Map)['scene'] as Map)['meshes'] as List;
    meshes[0]['normals'][0][0] = 0.1;
    meshes.add({
      'id': 99,
      'name': 'empty',
      'positions': [],
      'normals': [],
      'indices': [],
    });
    final packet = meshPacketFixture(source);
    final bytes = Uint8List.fromList([0, 0, 0, ...packet]);
    final model = CadDocumentModel.fromJson(
      decodeCadMeshPacket(Uint8List.sublistView(bytes, 3)),
    );
    expect(model.meshes.length, 2);
    final mesh = model.meshes.first as CadPackedMesh;
    expect(mesh.coordinates.first, 1e12 + 0.125);
    expect(mesh['normals'][0][0], Float32List.fromList([0.1]).single);
    expect(mesh.indices, [2, 0, 1]);
  });
  test('malformed mesh lengths, directory, topology, nonfinite and flags are rejected', () {
    final packet = meshPacketFixture(_source());
    for (final input in [
      Uint8List(8),
      packet.sublist(0, packet.length - 1),
      [...packet, 0],
    ]) {
      expect(
        () => decodeCadMeshPacket(Uint8List.fromList(input)),
        throwsFormatException,
      );
    }
    void invalid(void Function(ByteData) change) {
      final copy = Uint8List.fromList(packet);
      change(ByteData.sublistView(copy));
      expect(() => decodeCadMeshPacket(copy), throwsFormatException);
    }

    invalid((d) => d.setUint32(28, 1, Endian.little));
    invalid((d) => d.setUint32(8, 0xffffffff, Endian.little));
    invalid((d) => d.setUint32(12, 2, Endian.little));
    invalid((d) => d.setUint32(packet.length - 4, 3, Endian.little));
    invalid((d) {
      final directory = ((32 + d.getUint32(8, Endian.little) + 7) ~/ 8) * 8;
      final positions = ((directory + 12 + 7) ~/ 8) * 8;
      d.setFloat64(positions, double.nan, Endian.little);
    });
  });
}
