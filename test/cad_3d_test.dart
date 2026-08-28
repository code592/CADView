import 'dart:convert';

import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orthographic camera ray hits a visible mesh surface', () {
    final document = CadDocumentModel.fromJson({
      'metadata': {'format': 'stl', 'display_name': 'triangle.stl'},
      'scene': {
        'scene_kind': 'three_d',
        'scene': {
          'meshes': [
            {
              'id': 7,
              'positions': [
                {'x': -1, 'y': -1, 'z': 0},
                {'x': 1, 'y': -1, 'z': 0},
                {'x': 0, 'y': 1, 'z': 0},
              ],
              'indices': [0, 1, 2],
            },
          ],
          'root_nodes': [
            {
              'id': 1,
              'name': 'root',
              'visible': true,
              'mesh_ids': [7],
              'children': <Object>[],
            },
          ],
        },
      },
      'diagnostics': <Object>[],
    });
    final transform = Cad3DViewTransform.forScene(
      document,
      const Size(400, 400),
      1,
      Offset.zero,
      -0.75,
      0.55,
    );

    final hit = transform.hitTest(document, const Offset(200, 200));

    expect(hit, isNotNull);
    expect(hit!.meshId, BigInt.from(7));
    expect(hit.position.z, closeTo(0, 1e-9));

    const pinchCenter = Offset(275, 145);
    final anchor = transform.screenPlanePoint(pinchCenter);
    final pan = Cad3DViewTransform.panForAnchor(
      document,
      const Size(400, 400),
      2,
      -0.75,
      0.55,
      anchor,
      pinchCenter,
    );
    final zoomed = Cad3DViewTransform.forScene(
      document,
      const Size(400, 400),
      2,
      pan,
      -0.75,
      0.55,
    );
    expect(zoomed.project(anchor).dx, closeTo(pinchCenter.dx, 1e-9));
    expect(zoomed.project(anchor).dy, closeTo(pinchCenter.dy, 1e-9));
  });

  test('2D anchored zoom keeps the world point under the pinch center', () {
    final document = CadDocumentModel.fromJson({
      'metadata': {'format': 'dxf', 'display_name': 'zoom.dxf'},
      'scene': {
        'scene_kind': 'two_d',
        'scene': {
          'layers': <Object>[],
          'entities': <Object>[],
          'bounds': {
            'min': {'x': 0, 'y': 0},
            'max': {'x': 100, 'y': 100},
          },
        },
      },
      'diagnostics': <Object>[],
    });
    const size = Size(400, 600);
    const pinchCenter = Offset(310, 180);
    final initial = CadViewTransform.forScene(
      document,
      size,
      1,
      const Offset(20, -15),
    );
    final worldAnchor = initial.screenToWorld(pinchCenter);
    final pan = CadViewTransform.panForAnchor(
      document,
      size,
      3,
      worldAnchor,
      pinchCenter,
    );
    final zoomed = CadViewTransform.forScene(document, size, 3, pan);

    expect(zoomed.worldToScreen(worldAnchor).dx, closeTo(pinchCenter.dx, 1e-9));
    expect(zoomed.worldToScreen(worldAnchor).dy, closeTo(pinchCenter.dy, 1e-9));
  });

  test('3D annotation parser preserves its world-space anchor', () {
    final annotations = CadTextAnnotation.listFromJson(
      jsonEncode({
        'annotations': [
          {
            'id': '00000000-0000-0000-0000-000000000001',
            'geometry': {
              'kind': 'text',
              'value': 'surface note',
              'anchor': {
                'world_2d': null,
                'world_3d': {'x': 1.5, 'y': 2.5, 'z': 3.5},
              },
            },
          },
        ],
      }),
    );

    expect(annotations.single.is3D, isTrue);
    expect(annotations.single.z, 3.5);
  });
}
