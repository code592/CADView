import 'dart:ui' as ui;

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_mesh_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';

import 'mesh_packet_fixture.dart';
import 'mesh_recording_reference.dart';

/// Independent, uncropped drawLine oracle. No production clipping helpers.
/// Tests endpoints all offscreen, border ink, measured faces, resizing with
/// identical projection, large coordinates and retained picture snapshots.
Future<int> verifyMeshViewportCulling() async {
  var checks = 0;
  for (final origin in [0.0, 1e12]) {
    final scene = <String, dynamic>{
      'bounds': {
        'min': {'x': origin - 100, 'y': origin - 100, 'z': origin},
        'max': {'x': origin + 100, 'y': origin + 100, 'z': origin},
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
      'meshes': <Map<String, dynamic>>[],
    };
    final seed = CadDocumentModel(
      format: 'stl',
      displayName: 'culling',
      sceneKind: 'three_d',
      diagnostics: [],
      scene: scene,
    );
    final view = Cad3DViewTransform.forScene(
      seed,
      const Size(400, 400),
      10,
      Offset.zero,
      0,
      0,
    );
    final positions = <Map<String, double>>[];
    final indices = <int>[];
    final triangles = <List<Offset>>[
      // All vertices outside, but the edges cross the whole viewport.
      [
        const Offset(-100, 180),
        const Offset(500, 210),
        const Offset(200, -100),
      ],
      [const Offset(150, -100), const Offset(210, 500), const Offset(500, 180)],
      // Visible 3px stroke/AA fringe at the left/top boundaries.
      [const Offset(-1, 30), const Offset(-1, 140), const Offset(-0.5, 80)],
      [const Offset(30, -1), const Offset(140, -1), const Offset(80, -0.5)],
      // Invisible initially, visible after widening with the same projection.
      [const Offset(450, 50), const Offset(550, 70), const Offset(480, 150)],
      [
        const Offset(-100, -100),
        const Offset(-50, -80),
        const Offset(-80, -50),
      ],
      [const Offset(100, 100), const Offset(210, 220), const Offset(180, 80)],
    ];
    while (triangles.length < 512) {
      triangles.add([
        const Offset(-100, -100),
        const Offset(-50, -80),
        const Offset(-80, -50),
      ]);
    }
    for (var i = 0; i < 512; i++) {
      triangles.add([
        const Offset(700, -100),
        const Offset(800, -80),
        const Offset(780, -50),
      ]);
    }
    for (var i = 0; i < 512; i++) {
      triangles.add([
        const Offset(-700, -100),
        const Offset(-500, -80),
        const Offset(-580, -50),
      ]);
    }
    for (var i = 0; i < 6 * 512; i++) {
      triangles.add([
        const Offset(-700, -100),
        const Offset(-500, -80),
        const Offset(-580, -50),
      ]);
    }
    // Visible highlight after eight entire hidden chunks: source face indices
    // and draw ordering must not be renumbered when those chunks are skipped.
    triangles.add([
      const Offset(70, 70),
      const Offset(170, 130),
      const Offset(140, 250),
    ]);
    for (final triangle in triangles) {
      final first = positions.length;
      for (final p in triangle) {
        final world =
            view.center +
            view.right * ((p.dx - view.screenCenter.dx) / view.scale) +
            view.up * ((view.screenCenter.dy - p.dy) / view.scale);
        positions.add({'x': world.x, 'y': world.y, 'z': world.z});
      }
      indices.addAll([first, first + 1, first + 2]);
    }
    (scene['meshes'] as List).add({
      'id': 1,
      'positions': positions,
      'indices': indices,
    });
    final packed = CadDocumentModel.fromJson(
      decodeCadMeshPacket(
        meshPacketFixture({
          'metadata': {'format': 'stl', 'display_name': 'culling'},
          'scene': {'scene_kind': 'three_d', 'scene': scene},
          'diagnostics': [],
        }),
      ),
    );
    final initiallyHidden = ui.PictureRecorder();
    CadScenePainter(
      document: packed,
      zoom: 10,
      pan: const Offset(2000, 2000),
      yaw: 0,
      pitch: 0,
      showGrid: false,
    ).paint(Canvas(initiallyHidden), const Size(400, 400));
    initiallyHidden.endRecording().dispose();
    final hiddenStats = CadScenePainter.meshRenderCacheStats(packed);
    if (hiddenStats['projection_bytes'] != 0 ||
        hiddenStats['clip_code_bytes'] != 0 ||
        hiddenStats['vertex_epoch_bytes'] != 0) {
      throw StateError(
        'Initially offscreen mesh allocated vertex projection buffers',
      );
    }
    CadScenePainter.releaseDocument(packed);
    for (final document in [seed, packed]) {
      for (final selected in [false, true]) {
        final retained = <(ui.Picture, ui.Picture, Size, bool, int)>[];
        for (final frame in [
          (const Size(400, 400), Offset.zero, 10.0, true),
          (const Size(600, 400), const Offset(-100, 0), 10.0, true),
          (const Size(400, 400), const Offset(-130, 60), 10.0, true),
          (const Size(400, 400), Offset.zero, 0.1, true),
          (const Size(400, 400), Offset.zero, 10.0, true),
          (const Size(400, 400), const Offset(2000, 2000), 10.0, false),
          (const Size(400, 400), Offset.zero, 10.0, true),
        ]) {
          final (size, pan, zoom, expectsInk) = frame;
          if (document == packed &&
              !selected &&
              pan == Offset.zero &&
              zoom == 10) {
            // Cross the byte-stamp wrap boundary, with a different camera
            // every time. Retained earlier pictures must still be immutable.
            for (var tick = 0; tick < 260; tick++) {
              final warm = ui.PictureRecorder();
              CadScenePainter(
                document: document,
                zoom: 10,
                pan: Offset(tick / 100, 0),
                yaw: 0,
                pitch: 0,
                showGrid: false,
              ).paint(Canvas(warm), size);
              warm.endRecording().dispose();
            }
          }
          final recorder = ui.PictureRecorder();
          const measured = [2, 3, 4608];
          CadScenePainter(
            document: document,
            zoom: zoom,
            pan: pan,
            yaw: 0,
            pitch: 0,
            showGrid: false,
            selectedMeshId: selected ? BigInt.one : null,
            measurement3DFaces: [
              for (final i in measured)
                CadMeshHit(
                  meshId: BigInt.one,
                  triangleIndex: i,
                  position: CadPoint3(origin, origin, origin),
                  distance: 0,
                ),
            ],
          ).paint(Canvas(recorder), size);
          final actual = recorder.endRecording();
          if (document == packed && zoom == 10 && expectsInk) {
            final stats = CadScenePainter.meshRenderCacheStats(document);
            if (stats['vertex_epoch_bytes'] == 0 ||
                stats['valid_projection_vertices']! >= positions.length ~/ 2) {
              throw StateError('Sparse projection path was not exercised');
            }
          }
          final reference = ui.PictureRecorder();
          final canvas = Canvas(reference);
          canvas.drawRect(
            Offset.zero & size,
            Paint()..color = const Color(0xff071017),
          );
          final transform = Cad3DViewTransform.forScene(
            document,
            size,
            zoom,
            pan,
            0,
            0,
          );
          for (var i = 0; i < indices.length; i += 3) {
            final order = measured.indexOf(i ~/ 3);
            final ink = Paint()
              ..color = order >= 0
                  ? (order == 0
                        ? const Color(0xffffd666)
                        : const Color(0xff69f0ae))
                  : selected
                  ? const Color(0xffffd666)
                  : const Color(0xff73dfff).withValues(alpha: 0.72)
              ..strokeWidth = order >= 0
                  ? 3
                  : selected
                  ? 1.8
                  : 0.8;
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
          retained.add((
            actual,
            reference.endRecording(),
            size,
            expectsInk,
            zoom < 1 ? 5 : 100,
          ));
        }
        // Previous recordings must remain valid after cache replacement/disposal.
        CadScenePainter.releaseDocument(document);
        if (CadScenePainter.meshRenderCacheStats(document).values
            .any((value) => value != 0)) {
          throw StateError('Mesh render cache was not released');
        }
        for (final (actual, reference, size, expectsInk, minimumInk)
            in retained) {
          final a = await actual.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          final b = await reference.toImage(
            size.width.toInt(),
            size.height.toInt(),
          );
          try {
            final actualPixels = (await a.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final expectedPixels = (await b.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            var ink = 0;
            for (var i = 0; i < actualPixels.length; i++) {
              if ((actualPixels[i] - expectedPixels[i]).abs() > 1) {
                throw StateError(
                  'Viewport culling changed pixel $i: origin=$origin, size=$size, selected=$selected',
                );
              }
              if (i % 4 == 1 && actualPixels[i] > 60) ink++;
            }
            if (expectsInk && ink < minimumInk) {
              throw StateError(
                'Culling oracle unexpectedly blank: ink=$ink, minimum=$minimumInk',
              );
            }
            if (!expectsInk && ink != 0) {
              throw StateError('Entirely offscreen view retained stale ink');
            }
            checks++;
          } finally {
            a.dispose();
            b.dispose();
            actual.dispose();
            reference.dispose();
          }
        }
        if (document == packed && !selected) {
          // Validate the diagnostic batching reference against the production
          // path too, so benchmark comparisons cannot use different geometry.
          final size = const Size(400, 400);
          final recorder = ui.PictureRecorder();
          CadScenePainter(
            document: document,
            zoom: 10,
            pan: Offset.zero,
            yaw: 0,
            pitch: 0,
            showGrid: false,
          ).paint(Canvas(recorder), size);
          final actual = recorder.endRecording();
          final reference = UncroppedMeshRecorder().record(
            document,
            size,
            10,
            Offset.zero,
            0,
            pitch: 0,
          );
          final a = await actual.toImage(400, 400);
          final b = await reference.toImage(400, 400);
          try {
            final left = (await a.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final right = (await b.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            for (var i = 0; i < left.length; i++) {
              if ((left[i] - right[i]).abs() > 1) {
                throw StateError(
                  'Uncropped benchmark reference changed pixel $i',
                );
              }
            }
          } finally {
            a.dispose();
            b.dispose();
            actual.dispose();
            reference.dispose();
            CadScenePainter.releaseDocument(document);
          }
        }
      }
    }
  }
  return checks;
}
