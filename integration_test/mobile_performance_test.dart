// Opt-in local corpus. Never bundled in the application or uploaded.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/features/viewer/cad_mesh_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:cad_view/src/rust/frb_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/mesh_recording_reference.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'mode': kProfileMode ? 'profile' : (kReleaseMode ? 'release' : 'debug'),
    'scope': 'local integration; not a physical-device FPS or power claim',
    'files': <Map<String, dynamic>>[],
  };
  binding.reportData = report;
  var initialized = false;
  for (final path in [
    const String.fromEnvironment('CADVIEW_PERF_DXF'),
    const String.fromEnvironment('CADVIEW_PERF_STL'),
  ].where((path) => path.isNotEmpty)) {
    testWidgets('large corpus opens, renders all geometry and picks: $path', (
      tester,
    ) async {
      if (!initialized) {
        await RustLib.init();
        initialized = true;
      }
      final engine = NativeCadEngine()..setApplicationBackgrounded(false);
      final watch = Stopwatch()..start();
      final opened = await engine.openDocument(path);
      final openMs = watch.elapsedMicroseconds / 1000;
      var document = opened.document;
      try {
        var viewportMs = 0.0;
        if (document.sceneKind == 'two_d') {
          watch
            ..reset()
            ..start();
          // Full overview, NOT a sampled preview or a tiny cropped benchmark.
          document = await engine.loadViewport(
            opened.sessionId,
            document.bounds2D!,
          );
          viewportMs = watch.elapsedMicroseconds / 1000;
          expect(document.entities.length, opened.totalEntityCount.toInt());
        }
        final recordMs = <double>[];
        for (var frame = 0; frame < 4; frame++) {
          final recorder = ui.PictureRecorder();
          watch
            ..reset()
            ..start();
          CadScenePainter(
            document: document,
            zoom: 1 + frame * 0.2,
            pan: Offset(frame * 4.0, 0),
            yaw: -0.75 + frame * 0.03,
          ).paint(Canvas(recorder), const Size(400, 400));
          final picture = recorder.endRecording();
          recordMs.add(watch.elapsedMicroseconds / 1000);
          if (frame == 0) {
            final image = await picture.toImage(400, 400);
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            var ink = 0;
            for (var pixel = 0; pixel < data.length; pixel += 4) {
              if (data[pixel + 1] > 60 || data[pixel] > 60) ink++;
            }
            expect(
              ink,
              greaterThan(500),
              reason: 'large source must not open as a blank/sampled success',
            );
            image.dispose();
          }
          picture.dispose();
          await Future<void>.delayed(Duration.zero);
        }
        watch
          ..reset()
          ..start();
        if (document.sceneKind == 'two_d') {
          // Actual line endpoints in the deterministic million-entity fixture.
          for (var i = 0; i < 30; i++) {
            final hit = await engine.hitTest(
              opened.sessionId,
              i * 10.0,
              0,
              0.01,
            );
            expect(hit, isNotNull);
            expect(document.entityById(hit!.entityId.toInt()), isNotNull);
            expect(
              await engine.snap(opened.sessionId, i * 10.0, 0, 0.01),
              isNotNull,
            );
          }
          expect(document.entityById(1000000)!['id'], 1000000);
          expect(engine.measureDistance(0, 0, 4, 0), 4);
        } else {
          final transform = Cad3DViewTransform.forScene(
            document,
            const Size(400, 400),
            1,
            Offset.zero,
            -0.75,
            0.55,
          );
          for (var i = 0; i < 30; i++) {
            await engine.hitTestRay(
              opened.sessionId,
              transform.screenRay(Offset(180.0 + i, 200)),
            );
          }
        }
        final pickMs = watch.elapsedMicroseconds / 1000 / 30;
        final overlayRecordMs = <double>[];
        final zoomRecordMs = <Map<String, dynamic>>[];
        final renderCacheStats = <Map<String, int>>[];
        if (document.sceneKind == 'three_d') {
          // Same camera: moving measurement points must reuse exact mesh
          // commands, rather than rebuilding all topology on the UI isolate.
          for (var frame = 0; frame < 4; frame++) {
            final recorder = ui.PictureRecorder();
            watch
              ..reset()
              ..start();
            CadScenePainter(
              document: document,
              zoom: 1.6,
              pan: const Offset(12, 0),
              yaw: -0.66,
              measurement3DPoints: [CadPoint3(frame.toDouble(), 0, 0)],
            ).paint(Canvas(recorder), const Size(400, 400));
            final picture = recorder.endRecording();
            overlayRecordMs.add(watch.elapsedMicroseconds / 1000);
            picture.dispose();
          }
          final reference = UncroppedMeshRecorder();
          for (final zoom in [1.0, 8.0, 16.0, 32.0]) {
            final cropped = <double>[], uncropped = <double>[];
            for (var frame = 0; frame < 4; frame++) {
              final pan = Offset(frame * 4.0, 0);
              final yaw = -0.75 + frame * 0.03;
              watch
                ..reset()
                ..start();
              final before = reference.record(
                document,
                const Size(400, 400),
                zoom,
                pan,
                yaw,
              );
              uncropped.add(watch.elapsedMicroseconds / 1000);
              before.dispose();
              final recorder = ui.PictureRecorder();
              watch
                ..reset()
                ..start();
              CadScenePainter(
                document: document,
                zoom: zoom,
                pan: pan,
                yaw: yaw,
                showGrid: false,
              ).paint(Canvas(recorder), const Size(400, 400));
              final after = recorder.endRecording();
              cropped.add(watch.elapsedMicroseconds / 1000);
              after.dispose();
              await Future<void>.delayed(Duration.zero);
            }
            zoomRecordMs.add({
              'zoom': zoom,
              'uncropped_reference_ms': uncropped,
              'conservative_culling_ms': cropped,
            });
            renderCacheStats.add(
              CadScenePainter.meshRenderCacheStats(document),
            );
          }
        }
        (report['files'] as List<Map<String, dynamic>>).add({
          'path': path,
          'bytes': await File(path).length(),
          'entities': opened.totalEntityCount.toString(),
          'open_ms': openMs,
          'full_viewport_decode_ms': viewportMs,
          'record_ms': recordMs,
          'measurement_overlay_record_ms': overlayRecordMs,
          'zoom_record_ms': zoomRecordMs,
          'zoom_render_cache_stats': renderCacheStats,
          'triangles': document.sceneKind == 'three_d'
              ? document.scene['stats']['triangle_count']
              : 0,
          'mesh_source_chunks': document.meshes
              .whereType<CadPackedMesh>()
              .fold<int>(
                0,
                (count, mesh) => count + mesh.renderIndex.chunkCount,
              ),
          'mesh_render_index_bytes': document.meshes
              .whereType<CadPackedMesh>()
              .fold<int>(
                0,
                (count, mesh) => count + mesh.renderIndex.bounds.lengthInBytes,
              ),
          'transport': document.sceneKind == 'two_d' ? 'CAD2D001' : 'CAD3D001',
          'pick_roundtrip_mean_ms': pickMs,
        });
      } finally {
        CadScenePainter.releaseDocument(document);
        expect(
          CadScenePainter.meshRenderCacheStats(document).values,
          everyElement(0),
        );
        await engine.closeDocument(opened.sessionId);
      }
      // ignore: avoid_print
      print('MOBILE_PERFORMANCE ${jsonEncode(report)}');
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
