import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_mesh_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';

/// Diagnostic reconstruction of the previous unculled 4096-triangle batching
/// path. Reuses typed projection storage, projects every vertex and submits
/// every source edge. Only for unselected packed meshes with no overlays.
class UncroppedMeshRecorder {
  final _points = <int, Float32List>{};

  ui.Picture record(
    CadDocumentModel document,
    Size size,
    double zoom,
    Offset pan,
    double yaw, {
    double pitch = 0.55,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff071017),
    );
    final view = Cad3DViewTransform.forScene(
      document,
      size,
      zoom,
      pan,
      yaw,
      pitch,
    );
    for (final mesh in document.meshes.cast<CadPackedMesh>()) {
      if (!document.visibleMeshIds.contains(mesh['id'])) continue;
      final vertices = mesh.coordinates;
      final indices = mesh.indices;
      final projected = _points.putIfAbsent(
        mesh['id'] as int,
        () => Float32List(vertices.length ~/ 3 * 2),
      );
      for (var i = 0; i < vertices.length ~/ 3; i++) {
        final x = vertices[i * 3] - view.center.x;
        final y = vertices[i * 3 + 1] - view.center.y;
        final z = vertices[i * 3 + 2] - view.center.z;
        projected[i * 2] =
            view.screenCenter.dx +
            (x * view.right.x + y * view.right.y + z * view.right.z) *
                view.scale;
        projected[i * 2 + 1] =
            view.screenCenter.dy -
            (x * view.up.x + y * view.up.y + z * view.up.z) * view.scale;
      }
      final meshRecorder = ui.PictureRecorder();
      final meshCanvas = Canvas(meshRecorder);
      final ink = Paint()
        ..color = const Color(0xff73dfff).withValues(alpha: 0.72)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;
      final buffer = Float32List(4096 * 12);
      var used = 0;
      void flush() {
        if (used == 0) return;
        meshCanvas.drawRawPoints(
          ui.PointMode.lines,
          Float32List.sublistView(buffer, 0, used),
          ink,
        );
        used = 0;
      }

      for (var i = 0; i < indices.length; i += 3) {
        final a = indices[i] * 2,
            b = indices[i + 1] * 2,
            c = indices[i + 2] * 2;
        buffer[used++] = projected[a];
        buffer[used++] = projected[a + 1];
        buffer[used++] = projected[b];
        buffer[used++] = projected[b + 1];
        buffer[used++] = projected[b];
        buffer[used++] = projected[b + 1];
        buffer[used++] = projected[c];
        buffer[used++] = projected[c + 1];
        buffer[used++] = projected[c];
        buffer[used++] = projected[c + 1];
        buffer[used++] = projected[a];
        buffer[used++] = projected[a + 1];
        if (used == buffer.length) flush();
      }
      flush();
      final picture = meshRecorder.endRecording();
      canvas.drawPicture(picture);
      picture.dispose();
    }
    return recorder.endRecording();
  }
}
