// Opt-in CPU display-list benchmark, not a physical-device FPS/energy claim.
// CADVIEW_RENDER_JSON=... flutter test test/performance_render_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_mesh_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mesh_recording_reference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['CADVIEW_RENDER_JSON'];
  final packetPath = Platform.environment['CADVIEW_RENDER_PACKET'];
  test('large corpus display-list benchmark', () {
    final watch = Stopwatch()..start();
    final document = CadDocumentModel.fromJson(
      packetPath != null
          ? decodeCadDocumentPacket(File(packetPath).readAsBytesSync())
          : jsonDecode(File(path!).readAsStringSync()) as Map<String, dynamic>,
    );
    final decodeMs = watch.elapsedMicroseconds / 1000;
    final frames = <double>[];
    for (var frame = 0; frame < 6; frame++) {
      watch
        ..reset()
        ..start();
      final recorder = ui.PictureRecorder();
      CadScenePainter(
        document: document,
        zoom: 1 + frame * 0.1,
        pan: Offset(frame * 2, 0),
        yaw: -0.75 + frame * 0.03,
      ).paint(Canvas(recorder), const Size(800, 600));
      final picture = recorder.endRecording();
      watch.stop();
      frames.add(watch.elapsedMicroseconds / 1000);
      picture.dispose();
    }
    // ignore: avoid_print
    print(
      'RENDER_PERFORMANCE ${jsonEncode({'path': packetPath ?? path, 'transport': packetPath == null ? 'json' : (document.sceneKind == 'three_d' ? 'CAD3D001' : 'CAD2D001'), 'decode_ms': decodeMs, 'first_record_ms': frames.first, 'warm_record_ms': frames.skip(1).toList(), 'note': 'Flutter test/debug display-list CPU time; excludes GPU raster'})}',
    );
    if (document.sceneKind == 'three_d' && packetPath != null) {
      final reference = UncroppedMeshRecorder();
      final results = <Map<String, dynamic>>[];
      for (final zoom in [1.0, 8.0, 16.0, 32.0]) {
        final croppedMs = <double>[], uncroppedMs = <double>[];
        for (var frame = 0; frame < 4; frame++) {
          final pan = Offset(frame * 4.0, 0);
          final yaw = -0.75 + frame * 0.03;
          watch
            ..reset()
            ..start();
          final before = reference.record(
            document,
            const Size(800, 600),
            zoom,
            pan,
            yaw,
          );
          uncroppedMs.add(watch.elapsedMicroseconds / 1000);
          before.dispose();
          watch
            ..reset()
            ..start();
          final recorder = ui.PictureRecorder();
          CadScenePainter(
            document: document,
            zoom: zoom,
            pan: pan,
            yaw: yaw,
            showGrid: false,
          ).paint(Canvas(recorder), const Size(800, 600));
          final after = recorder.endRecording();
          croppedMs.add(watch.elapsedMicroseconds / 1000);
          after.dispose();
        }
        results.add({
          'zoom': zoom,
          'uncropped_reference_ms': uncroppedMs,
          'conservative_culling_ms': croppedMs,
          'render_cache': CadScenePainter.meshRenderCacheStats(document),
        });
      }
      // ignore: avoid_print
      print('MESH_CULLING_PERFORMANCE ${jsonEncode(results)}');
      // ignore: avoid_print
      print(
        'MESH_RENDER_INDEX ${jsonEncode({'chunks': document.meshes.whereType<CadPackedMesh>().fold<int>(0, (count, mesh) => count + mesh.renderIndex.chunkCount), 'bytes': document.meshes.whereType<CadPackedMesh>().fold<int>(0, (count, mesh) => count + mesh.renderIndex.bounds.lengthInBytes)})}',
      );
    }
    CadScenePainter.releaseDocument(document);
  }, skip: path == null && packetPath == null);
  test(
    'sparse packet lookup benchmark',
    () {
      final bytes = File(packetPath!).readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      final records = ((32 + data.getUint32(8, Endian.little) + 7) ~/ 8) * 8;
      final count = data.getUint32(12, Endian.little);
      // Numeric-line corpus only; never rewrite fallback text identities.
      for (var i = 0; i < count; i++) {
        expect(data.getUint32(records + i * 32 + 20, Endian.little) & 255, 2);
        data.setUint64(records + i * 32, 5001 + 2 * i, Endian.little);
      }
      final document = CadDocumentModel.fromJson(decodeCadScenePacket(bytes));
      final entities = document.entities as CadPackedEntities;
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        final id = 5001 + (count - 1 - i) * 2;
        var index = -1;
        for (var j = 0; j < count; j++) {
          if (entities.idAt(j) == id) {
            index = j;
            break;
          }
        }
        expect(index, count - 1 - i);
      }
      final scanMs = watch.elapsedMicroseconds / 1000 / 20;
      watch
        ..reset()
        ..start();
      for (var i = 0; i < 20; i++) {
        final id = 5001 + (count - 1 - i) * 2;
        expect(document.entityById(id)!['id'], id);
        expect(entities.indicesOfIds({id}).single, count - 1 - i);
      }
      final lookupMs = watch.elapsedMicroseconds / 1000 / 20;
      // ignore: avoid_print
      print(
        'SPARSE_LOOKUP_PERFORMANCE ${jsonEncode({'entities': count, 'numeric_scan_mean_ms': scanMs, 'property_and_selection_lookup_mean_ms': lookupMs})}',
      );
      final timings = <double>[];
      for (var i = 0; i < 4; i++) {
        watch
          ..reset()
          ..start();
        final recorder = ui.PictureRecorder();
        CadScenePainter(
          document: document,
          zoom: 1,
          pan: Offset.zero,
          showGrid: false,
          selectedEntityIds: {BigInt.from(5001 + (count - 1 - i) * 2)},
        ).paint(Canvas(recorder), const Size(800, 600));
        recorder.endRecording().dispose();
        timings.add(watch.elapsedMicroseconds / 1000);
      }
      // ignore: avoid_print
      print('SPARSE_SELECTION_RECORD_MS ${jsonEncode(timings)}');
      CadScenePainter.releaseDocument(document);
    },
    skip:
        packetPath == null ||
        !const bool.fromEnvironment('CADVIEW_BENCH_SPARSE_IDS'),
  );
}
