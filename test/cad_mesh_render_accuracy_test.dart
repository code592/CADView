import 'dart:ui' as ui;

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_mesh_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_packet_fixture.dart';
import 'support/mesh_culling_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'viewport culling retains crossings, border ink and resized snapshots',
    () async {
      expect(await verifyMeshViewportCulling(), 56);
    },
  );
  test('assembly-only summaries retain exact mesh buffers and visibility', () {
    final meshes = [
      {'id': 1, 'positions': [], 'indices': []},
    ];
    Map<String, dynamic> tree(bool visible) => {
      'id': 0,
      'name': 'root',
      'visible': visible,
      'mesh_ids': [1],
      'children': [],
    };
    final original = CadDocumentModel(
      format: 'stl',
      displayName: 'mesh',
      sceneKind: 'three_d',
      diagnostics: [],
      scene: {
        'meshes': meshes,
        'root_nodes': [tree(true)],
        'stats': {'triangle_count': 10},
      },
    );
    final summary = CadDocumentModel(
      format: 'stl',
      displayName: 'mesh',
      sceneKind: 'three_d',
      diagnostics: [],
      scene: {
        'meshes': [],
        'root_nodes': [tree(false)],
      },
    );
    final updated = original.withAssemblyStateFrom(summary);
    expect(updated.scene['meshes'], same(meshes));
    expect(updated.visibleMeshIds, isEmpty);
    expect(original.visibleMeshIds, {1});
    expect(updated.scene['stats'], {'triangle_count': 10});
  });
  test(
    'batched wireframe preserves every edge, source order and measured faces',
    () async {
      const offset = 1000000000000.0;
      final positions = <Map<String, double>>[];
      final indices = <int>[];
      for (var i = 0; i < 4200; i++) {
        final x = offset + i % 70 * 2;
        final y = offset + i ~/ 70 * 2;
        final first = positions.length;
        positions.addAll([
          {'x': x, 'y': y, 'z': offset},
          {'x': x + 1, 'y': y, 'z': offset + 0.5},
          {'x': x, 'y': y + 1, 'z': offset},
        ]);
        indices.addAll([first, first + 1, first + 2]);
      }
      final document = CadDocumentModel(
        format: 'stl',
        displayName: 'exact',
        sceneKind: 'three_d',
        diagnostics: [],
        scene: {
          'bounds': {
            'min': {'x': offset, 'y': offset, 'z': offset},
            'max': {'x': offset + 140, 'y': offset + 120, 'z': offset + 1},
          },
          'root_nodes': [
            {
              'id': 0,
              'name': 'root',
              'visible': true,
              'mesh_ids': [1],
              'children': [],
            },
          ],
          'meshes': [
            {'id': 1, 'positions': positions, 'indices': indices},
          ],
        },
      );
      const size = Size(600, 500);
      final packed = CadDocumentModel.fromJson(
        decodeCadMeshPacket(
          meshPacketFixture({
            'metadata': {'format': 'stl', 'display_name': 'exact'},
            'scene': {'scene_kind': 'three_d', 'scene': document.scene},
            'diagnostics': [],
          }),
        ),
      );
      for (final mode in [
        (selected: false, packed: false),
        (selected: true, packed: false),
        (selected: false, packed: true),
        (selected: true, packed: true),
      ]) {
        final selected = mode.selected;
        final rendered = mode.packed ? packed : document;
        final transform = Cad3DViewTransform.forScene(
          rendered,
          size,
          1.5,
          const Offset(12, -15),
          -0.75,
          0.55,
        );
        final measured = [4095, 4096];
        final recorder = ui.PictureRecorder();
        final painter = CadScenePainter(
          document: rendered,
          zoom: 1.5,
          pan: const Offset(12, -15),
          showGrid: false,
          selectedMeshId: selected ? BigInt.one : null,
          measurement3DFaces: [
            for (var i = 0; i < measured.length; i++)
              CadMeshHit(
                meshId: BigInt.one,
                triangleIndex: measured[i],
                position: const CadPoint3(offset, offset, offset),
                distance: 1,
              ),
          ],
        );
        painter.paint(Canvas(recorder), size);
        final actual = recorder.endRecording();
        final reuseRecorder = ui.PictureRecorder();
        painter.paint(Canvas(reuseRecorder), size);
        final reused = reuseRecorder.endRecording();
        // Repaint the same mesh using another camera before rasterizing the
        // earlier picture. Native draw calls must snapshot staging buffers.
        final later = ui.PictureRecorder();
        CadScenePainter(
          document: rendered,
          zoom: 2,
          pan: Offset.zero,
          yaw: 0.2,
          showGrid: false,
        ).paint(Canvas(later), size);
        later.endRecording().dispose();
        CadScenePainter.releaseDocument(rendered);
        CadScenePainter.releaseDocument(
          rendered,
        ); // lifecycle cleanup is idempotent
        final rebuiltRecorder = ui.PictureRecorder();
        painter.paint(Canvas(rebuiltRecorder), size);
        final rebuilt = rebuiltRecorder.endRecording();
        final expectedRecorder = ui.PictureRecorder();
        final canvas = Canvas(expectedRecorder);
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = const Color(0xff071017),
        );
        final paint = Paint()
          ..color = selected
              ? const Color(0xffffd666)
              : const Color(0xff73dfff).withValues(alpha: 0.72)
          ..strokeWidth = selected ? 1.8 : 0.8
          ..style = PaintingStyle.stroke;
        for (var i = 0; i < indices.length; i += 3) {
          final order = measured.indexOf(i ~/ 3);
          final ink = order < 0
              ? paint
              : (Paint()
                  ..color = order == 0
                      ? const Color(0xffffd666)
                      : const Color(0xff69f0ae)
                  ..strokeWidth = 3
                  ..style = PaintingStyle.stroke);
          final a = transform.project(
            CadPoint3.fromJson(positions[indices[i]]),
          );
          final b = transform.project(
            CadPoint3.fromJson(positions[indices[i + 1]]),
          );
          final c = transform.project(
            CadPoint3.fromJson(positions[indices[i + 2]]),
          );
          canvas.drawLine(a, b, ink);
          canvas.drawLine(b, c, ink);
          canvas.drawLine(c, a, ink);
        }
        final expected = expectedRecorder.endRecording();
        final actualImage = await actual.toImage(600, 500);
        final expectedImage = await expected.toImage(600, 500);
        final actualPixels = (await actualImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final expectedPixels = (await expectedImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final reusedImage = await reused.toImage(600, 500);
        expect(
          (await reusedImage.toByteData(format: ui.ImageByteFormat.rawRgba))!
              .buffer
              .asUint8List(),
          actualPixels,
        );
        reusedImage.dispose();
        reused.dispose();
        final rebuiltImage = await rebuilt.toImage(600, 500);
        expect(
          (await rebuiltImage.toByteData(format: ui.ImageByteFormat.rawRgba))!
              .buffer
              .asUint8List(),
          actualPixels,
        );
        rebuiltImage.dispose();
        rebuilt.dispose();
        var changed = 0;
        for (var i = 0; i < actualPixels.length; i++) {
          if ((actualPixels[i] - expectedPixels[i]).abs() > 1) changed++;
        }
        expect(
          changed,
          0,
          reason: 'all 4200 triangles including staging/highlight boundaries must match the exact reference',
        );
        actualImage.dispose();
        expectedImage.dispose();
        actual.dispose();
        expected.dispose();
      }
    },
  );
}
