import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cad_view/features/viewer/cad_mesh_render_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'chunk bounds use indexed vertices and preserve exact source ranges',
    () {
      final xyz = Float64List.fromList([
        0.125,
        -0.5,
        7,
        20,
        30,
        40,
        -5,
        10,
        -2,
        1e300,
        1e300,
        1e300,
      ]);
      final indices = Uint32List.fromList([
        for (var i = 0; i < 512; i++) ...[2, 0, 1],
        0,
        0,
        0,
      ]);
      final index = CadMeshRenderIndex.build(xyz, indices);
      expect(index.chunkCount, 2);
      expect(index.indexCount, 1539);
      expect(index.bounds, [
        -5,
        -0.5,
        -2,
        20,
        30,
        40,
        0.125,
        -0.5,
        7,
        0.125,
        -0.5,
        7,
      ]);
      expect(() => index.bounds[0] = 10, throwsUnsupportedError);
      expect(
        CadMeshRenderIndex.build(Float64List(0), Uint32List(0)).chunkCount,
        0,
      );
      expect(
        () => CadMeshRenderIndex.build(xyz, Uint32List.fromList([0, 1, 4])),
        throwsFormatException,
      );
      expect(
        () => CadMeshRenderIndex.build(xyz, Uint32List(1)),
        throwsFormatException,
      );
      expect(
        () => CadMeshRenderIndex.build(Float64List(1), Uint32List(0)),
        throwsFormatException,
      );
      expect(
        () => CadMeshRenderIndex.build(
          Float64List.fromList([double.nan, 0, 0]),
          Uint32List(0),
        ),
        throwsFormatException,
      );
    },
  );

  test('interval rejection is conservative across large coordinates and orientations', () {
    final random = math.Random(614);
    var rejected = 0;
    for (final origin in [0.0, 1e12, -1e12]) {
      for (var view = 0; view < 100; view++) {
        final xyz = Float64List.fromList([
          for (var i = 0; i < 30; i++) origin + random.nextDouble() * 10 - 5,
        ]);
        final indices = Uint32List.fromList([0, 9, 4, 3, 7, 2, 6, 8, 1]);
        final index = CadMeshRenderIndex.build(xyz, indices);
        final right = List.generate(3, (_) => random.nextDouble() * 2 - 1);
        final up = List.generate(3, (_) => random.nextDouble() * 2 - 1);
        final centers = List.generate(
          3,
          (_) => origin + random.nextDouble() * 50 - 25,
        );
        final scale = math.pow(10, view % 8 - 3).toDouble();
        final screenX = view % 2 == 0 ? -1000.0 : 200.0;
        final outside = index.isOutside(
          0,
          centerX: centers[0],
          centerY: centers[1],
          centerZ: centers[2],
          rightX: right[0],
          rightY: right[1],
          rightZ: right[2],
          upX: up[0],
          upY: up[1],
          upZ: up[2],
          screenX: screenX,
          screenY: 200,
          scale: scale,
          width: 400,
          height: 400,
        );
        if (!outside) continue;
        rejected++;
        var common = 15;
        // Independent full vertex projection and float32 outcodes.
        for (final vertex in indices) {
          final x = xyz[vertex * 3] - centers[0],
              y = xyz[vertex * 3 + 1] - centers[1],
              z = xyz[vertex * 3 + 2] - centers[2];
          final p = Float32List.fromList([
            screenX + (x * right[0] + y * right[1] + z * right[2]) * scale,
            200 - (x * up[0] + y * up[1] + z * up[2]) * scale,
          ]);
          var code = 0;
          if (p[0] < -4) code |= 1;
          if (p[0] > 404) code |= 2;
          if (p[1] < -4) code |= 4;
          if (p[1] > 404) code |= 8;
          common &= code;
        }
        expect(
          common,
          isNot(0),
          reason: 'a rejected chunk must have every indexed vertex beyond one shared side',
        );
      }
    }
    expect(rejected, greaterThan(100));
  });

  test('overflow and invalid scale fail open rather than discard geometry', () {
    final index = CadMeshRenderIndex.build(
      Float64List.fromList([1e40, 0, 0]),
      Uint32List.fromList([0, 0, 0]),
    );
    for (final scale in [1.0, double.infinity, 0.0, -1.0]) {
      expect(
        index.isOutside(
          0,
          centerX: 0,
          centerY: 0,
          centerZ: 0,
          rightX: 1,
          rightY: 0,
          rightZ: 0,
          upX: 0,
          upY: 1,
          upZ: 0,
          screenX: 200,
          screenY: 200,
          scale: scale,
          width: 400,
          height: 400,
        ),
        isFalse,
      );
    }
  });
}
