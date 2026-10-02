import 'dart:convert';
import 'dart:math' as math;

import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_entity_metrics.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:cad_view/features/viewer/cad_units.dart';
import 'package:cad_view/features/viewer/cad_viewer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('stable midpoint avoids overflow in 2D and 3D coordinates', () {
    final maximum = double.maxFinite;
    expect(cadStableMidpoint(maximum, maximum), maximum);
    expect(cadStableMidpoint(maximum, -maximum), 0);
    expect(
      cadMidpoint2D(
        const Offset(1000000000, -2000000000),
        const Offset(1000000010, -1999999994),
      ),
      const Offset(1000000005, -1999999997),
    );
    final midpoint3D = cadMidpoint3D(
      const CadPoint3(1000000000, -2000000000, 3000000000),
      const CadPoint3(1000000010, -1999999994, 3000000008),
    );
    expect(midpoint3D.x, 1000000005);
    expect(midpoint3D.y, -1999999997);
    expect(midpoint3D.z, 3000000004);
  });

  test('two points define a stable right-handed local coordinate frame', () {
    final frame = CadLocalCoordinateFrame2D.fromOriginAndXAxis(
      const Offset(10, 20),
      const Offset(10, 25),
    )!;
    expect(frame.xAxis.dx, closeTo(0, 1e-12));
    expect(frame.xAxis.dy, closeTo(1, 1e-12));
    expect(frame.yAxis.dx, closeTo(-1, 1e-12));
    expect(frame.yAxis.dy, closeTo(0, 1e-12));
    expect(frame.directionDegrees, closeTo(90, 1e-12));
    final local = frame.worldToLocal(const Offset(7, 25))!;
    expect(local.dx, closeTo(5, 1e-12));
    expect(local.dy, closeTo(3, 1e-12));
    final roundTrip = frame.localToWorld(local)!;
    expect(roundTrip.dx, closeTo(7, 1e-12));
    expect(roundTrip.dy, closeTo(25, 1e-12));

    final large = CadLocalCoordinateFrame2D.fromOriginAndXAxis(
      const Offset(1000000000000, -1000000000000),
      const Offset(1000000000003, -999999999996),
    )!;
    final largeXAxisPoint = large.worldToLocal(
      const Offset(1000000000003, -999999999996),
    )!;
    expect(largeXAxisPoint.dx, closeTo(5, 1e-12));
    expect(largeXAxisPoint.dy, closeTo(0, 1e-12));

    final aligned = CadLocalCoordinateFrame2D.axisAligned(const Offset(-4, 8))!;
    expect(aligned.worldToLocal(const Offset(1, 2)), const Offset(5, -6));
    expect(
      CadLocalCoordinateFrame2D.fromOriginAndXAxis(
        const Offset(1, 1),
        const Offset(1, 1),
      ),
      isNull,
    );
    expect(
      CadLocalCoordinateFrame2D.fromOriginAndXAxis(
        const Offset(0, 0),
        const Offset(double.infinity, 1),
      ),
      isNull,
    );
    expect(frame.worldToLocal(const Offset(double.nan, 0)), isNull);
  });

  test('polar stakeout follows survey azimuth and rejects false precision', () {
    final north = cadPolarStakeoutMeasurement2D(const Offset(10, 20), 5, 0)!;
    expect(north.target, const Offset(10, 25));
    expect(north.deltaX, 0);
    expect(north.deltaY, 5);

    final east = cadPolarStakeoutMeasurement2D(const Offset(10, 20), 5, 90)!;
    expect(east.target.dx, closeTo(15, 1e-12));
    expect(east.target.dy, closeTo(20, 1e-12));
    expect(cadSurveyDirection2D(east.origin, east.target)!.azimuthDegrees, 90);

    final rotatedFrame = CadLocalCoordinateFrame2D.fromOriginAndXAxis(
      Offset.zero,
      const Offset(0, 1),
    )!;
    final localOrigin = rotatedFrame.worldToLocal(const Offset(10, 20))!;
    final localEast = cadPolarStakeoutMeasurement2D(localOrigin, 10, 90)!;
    final rotatedTarget = rotatedFrame.localToWorld(localEast.target)!;
    expect(rotatedTarget.dx, closeTo(10, 1e-12));
    expect(rotatedTarget.dy, closeTo(30, 1e-12));

    final southwest = cadPolarStakeoutMeasurement2D(
      const Offset(1000000000000, -1000000000000),
      5000,
      225,
    )!;
    expect(southwest.deltaX, closeTo(-3535.533905932738, 1e-9));
    expect(southwest.deltaY, closeTo(-3535.533905932738, 1e-9));
    expect(
      cadSurveyDirection2D(southwest.origin, southwest.target)!.azimuthDegrees,
      closeTo(225, 1e-9),
    );

    expect(cadPolarStakeoutMeasurement2D(Offset.zero, 0, 45), isNull);
    expect(cadPolarStakeoutMeasurement2D(Offset.zero, -1, 45), isNull);
    expect(cadPolarStakeoutMeasurement2D(Offset.zero, 1, -0.1), isNull);
    expect(cadPolarStakeoutMeasurement2D(Offset.zero, 1, 360), isNull);
    expect(
      cadPolarStakeoutMeasurement2D(const Offset(1e20, 1e20), 1, 45),
      isNull,
    );
  });

  test(
    'two-distance location returns left/right, tangent, and no-solution',
    () {
      final crossing = cadTwoDistanceLocation2D(
        Offset.zero,
        const Offset(6, 0),
        5,
        5,
      )!;
      expect(crossing.baselineLength, 6);
      expect(crossing.solutions, hasLength(2));
      expect(crossing.solutions.first.dx, closeTo(3, 1e-12));
      expect(crossing.solutions.first.dy, closeTo(4, 1e-12));
      expect(crossing.solutions.last.dx, closeTo(3, 1e-12));
      expect(crossing.solutions.last.dy, closeTo(-4, 1e-12));

      final externalTangent = cadTwoDistanceLocation2D(
        Offset.zero,
        const Offset(10, 0),
        5,
        5,
      )!;
      expect(externalTangent.solutions, [const Offset(5, 0)]);

      final internalTangent = cadTwoDistanceLocation2D(
        Offset.zero,
        const Offset(3, 0),
        5,
        2,
      )!;
      expect(internalTangent.solutions, [const Offset(5, 0)]);

      final translated = cadTwoDistanceLocation2D(
        const Offset(1000000000000, -1000000000000),
        const Offset(1000000000006, -1000000000000),
        5,
        5,
      )!;
      expect(translated.solutions.first.dx, 1000000000003);
      expect(translated.solutions.first.dy, -999999999996);

      expect(
        cadTwoDistanceLocation2D(Offset.zero, const Offset(20, 0), 5, 5),
        isNull,
      );
      expect(
        cadTwoDistanceLocation2D(Offset.zero, const Offset(1, 0), 5, 2),
        isNull,
      );
      expect(cadTwoDistanceLocation2D(Offset.zero, Offset.zero, 5, 5), isNull);
      expect(
        cadTwoDistanceLocation2D(Offset.zero, const Offset(1, 0), 0, 1),
        isNull,
      );
    },
  );

  test('polyline equal division is linear, exact and bounded', () {
    final open = cadPolylineDivisionMeasurement2D(const [
      Offset(0, 0),
      Offset(3, 0),
      Offset(3, 0),
      Offset(3, 4),
    ], 7)!;
    expect(open.totalLength, 7);
    expect(open.intervalLength, 1);
    expect(open.divisionPoints, const [
      Offset(0, 0),
      Offset(1, 0),
      Offset(2, 0),
      Offset(3, 0),
      Offset(3, 1),
      Offset(3, 2),
      Offset(3, 3),
      Offset(3, 4),
    ]);

    final closed = cadPolylineDivisionMeasurement2D(
      const [Offset(0, 0), Offset(2, 0), Offset(2, 2), Offset(0, 2)],
      4,
      closed: true,
    )!;
    expect(closed.totalLength, 8);
    expect(closed.intervalLength, 2);
    expect(closed.divisionPoints, const [
      Offset(0, 0),
      Offset(2, 0),
      Offset(2, 2),
      Offset(0, 2),
    ]);

    final large = cadPolylineDivisionMeasurement2D(const [
      Offset(1000000000000, -1000000000000),
      Offset(1000000000040, -1000000000000),
    ], 4)!;
    expect(large.intervalLength, 10);
    expect(
      large.divisionPoints[2],
      const Offset(1000000000020, -1000000000000),
    );

    expect(
      cadPolylineDivisionMeasurement2D(const [Offset.zero, Offset(1, 0)], 1),
      isNull,
    );
    expect(
      cadPolylineDivisionMeasurement2D(const [
        Offset.zero,
        Offset(1, 0),
      ], cadMaximumPolylineDivisions + 1),
      isNull,
    );
    expect(
      cadPolylineDivisionMeasurement2D(const [Offset.zero, Offset.zero], 2),
      isNull,
    );
    expect(
      cadPolylineDivisionMeasurement2D(const [
        Offset(1e20, 1e20),
        Offset(1e20 + 1, 1e20),
      ], 2),
      isNull,
    );
  });

  test('closed boundary edge table preserves length and survey direction', () {
    final edges = cadClosedBoundaryEdges2D(const [
      Offset(0, 0),
      Offset(0, 3),
      Offset(4, 3),
      Offset(4, 0),
      Offset(0, 0),
    ])!;
    expect(edges, hasLength(4));
    expect(edges.map((edge) => edge.length), [3, 4, 3, 4]);
    expect(edges.map((edge) => edge.direction.azimuthDegrees), [
      0,
      90,
      180,
      270,
    ]);
    expect(edges.fold<double>(0, (total, edge) => total + edge.length), 14);
    expect(edges.map((edge) => edge.interiorAngleDegrees), [90, 90, 90, 90]);
    expect(edges.map((edge) => edge.deflectionAngleDegrees), [90, 90, 90, 90]);
    expect(
      edges.map((edge) => edge.vertexKind),
      everyElement(CadBoundaryVertexKind.convex),
    );

    final large = cadClosedBoundaryEdges2D(const [
      Offset(1000000000000, -1000000000000),
      Offset(1000000000000, -999999999997),
      Offset(1000000000004, -999999999997),
      Offset(1000000000004, -1000000000000),
    ])!;
    expect(large.map((edge) => edge.length), [3, 4, 3, 4]);

    final rotatedFrame = CadLocalCoordinateFrame2D.fromOriginAndXAxis(
      Offset.zero,
      const Offset(0, 1),
    )!;
    final rotated = cadClosedBoundaryEdges2D(
      const [
        Offset(0, 0),
        Offset(2, 0),
        Offset(2, 1),
        Offset(0, 1),
      ].map((point) => rotatedFrame.worldToLocal(point)!).toList(),
    )!;
    expect(rotated.first.direction.azimuthDegrees, 180);

    final concavePoints = const [
      Offset(0, 0),
      Offset(4, 0),
      Offset(4, 4),
      Offset(2, 2),
      Offset(0, 4),
    ];
    final concave = cadClosedBoundaryEdges2D(concavePoints)!;
    expect(concave[3].interiorAngleDegrees, closeTo(270, 1e-12));
    expect(concave[3].deflectionAngleDegrees, closeTo(-90, 1e-12));
    expect(concave[3].vertexKind, CadBoundaryVertexKind.concave);
    final reversed = cadClosedBoundaryEdges2D(concavePoints.reversed.toList())!;
    for (final edge in concave) {
      final reverseEdge = reversed.singleWhere(
        (item) => item.start == edge.start,
      );
      expect(
        reverseEdge.interiorAngleDegrees,
        closeTo(edge.interiorAngleDegrees, 1e-12),
      );
      expect(reverseEdge.vertexKind, edge.vertexKind);
    }

    final withStraightVertex = cadClosedBoundaryEdges2D(const [
      Offset(0, 0),
      Offset(2, 0),
      Offset(4, 0),
      Offset(4, 2),
      Offset(0, 2),
    ])!;
    expect(withStraightVertex[1].interiorAngleDegrees, 180);
    expect(withStraightVertex[1].deflectionAngleDegrees, 0);
    expect(withStraightVertex[1].vertexKind, CadBoundaryVertexKind.straight);

    expect(
      cadClosedBoundaryEdges2D(const [
        Offset(0, 0),
        Offset(2, 2),
        Offset(0, 2),
        Offset(2, 0),
      ]),
      isNull,
    );
    expect(
      cadClosedBoundaryEdges2D(const [
        Offset.zero,
        Offset(1, 0),
        Offset(1, 0),
        Offset(0, 1),
      ]),
      isNull,
    );
    expect(
      cadClosedBoundaryEdges2D(const [
        Offset.zero,
        Offset(double.infinity, 0),
        Offset(0, 1),
      ]),
      isNull,
    );
  });

  test('planar shape metrics are stable and reject impossible compactness', () {
    final circle = cadPlanarShapeMetrics2D(math.pi * 100, math.pi * 20)!;
    expect(circle.equivalentCircleDiameter, closeTo(20, 1e-12));
    expect(circle.hydraulicRadius, closeTo(5, 1e-12));
    expect(circle.hydraulicDiameter, closeTo(20, 1e-12));
    expect(circle.compactness, closeTo(1, 1e-12));

    final square = cadPlanarShapeMetrics2D(100, 40)!;
    expect(
      square.equivalentCircleDiameter,
      closeTo(2 * math.sqrt(100 / math.pi), 1e-12),
    );
    expect(square.hydraulicRadius, 2.5);
    expect(square.hydraulicDiameter, 10);
    expect(square.compactness, closeTo(math.pi / 4, 1e-12));

    final large = cadPlanarShapeMetrics2D(1e300, 1e151)!;
    expect(large.equivalentCircleDiameter.isFinite, isTrue);
    expect(large.hydraulicRadius, 1e149);
    expect(large.hydraulicDiameter, 4e149);
    expect(large.compactness, closeTo(0.04 * math.pi, 1e-12));

    expect(cadPlanarShapeMetrics2D(100, 1), isNull);
    expect(cadPlanarShapeMetrics2D(0, 10), isNull);
    expect(cadPlanarShapeMetrics2D(double.nan, 10), isNull);
  });

  test('open traverse reports only consecutive legs without false closure', () {
    final traverse = cadOpenTraverse2D(const [
      Offset(0, 0),
      Offset(0, 3),
      Offset(4, 3),
    ])!;
    expect(traverse.legs, hasLength(2));
    expect(traverse.legs.map((leg) => leg.length), [3, 4]);
    expect(traverse.legs.map((leg) => leg.direction.azimuthDegrees), [0, 90]);
    expect(traverse.totalLength, 7);
    expect(traverse.displacement, 5);
    expect(
      traverse.displacementDirection?.azimuthDegrees,
      closeTo(53.13010235415598, 1e-12),
    );

    final closure = cadTraverseClosure2D(traverse, const Offset(4.3, 2.6))!;
    expect(closure.observedEndpoint, const Offset(4, 3));
    expect(closure.knownEndpoint, const Offset(4.3, 2.6));
    expect(closure.correction.dx, closeTo(0.3, 1e-12));
    expect(closure.correction.dy, closeTo(-0.4, 1e-12));
    expect(closure.linearMisclosure, closeTo(0.5, 1e-12));
    expect(closure.relativePrecision, closeTo(14, 1e-12));
    expect(
      closure.correctionDirection?.azimuthDegrees,
      closeTo(143.13010235415598, 1e-12),
    );

    final exactClosure = cadTraverseClosure2D(traverse, const Offset(4, 3))!;
    expect(exactClosure.linearMisclosure, 0);
    expect(exactClosure.relativePrecision, double.infinity);
    expect(exactClosure.correctionDirection, isNull);

    final adjustment = cadBowditchAdjustment2D(
      traverse,
      const Offset(4.7, 2.3),
    )!;
    expect(adjustment.points, hasLength(3));
    expect(adjustment.points[0].observed, Offset.zero);
    expect(adjustment.points[0].correction, Offset.zero);
    expect(adjustment.points[0].adjusted, Offset.zero);
    expect(adjustment.points[1].observed, const Offset(0, 3));
    expect(adjustment.points[1].correction.dx, closeTo(0.3, 1e-12));
    expect(adjustment.points[1].correction.dy, closeTo(-0.3, 1e-12));
    expect(adjustment.points[1].adjusted.dx, closeTo(0.3, 1e-12));
    expect(adjustment.points[1].adjusted.dy, closeTo(2.7, 1e-12));
    expect(adjustment.points[1].cumulativeLength, 3);
    expect(adjustment.points[2].correction.dx, closeTo(0.7, 1e-12));
    expect(adjustment.points[2].correction.dy, closeTo(-0.7, 1e-12));
    expect(adjustment.points[2].adjusted, const Offset(4.7, 2.3));
    expect(adjustment.points[2].cumulativeLength, 7);

    final exactAdjustment = cadBowditchAdjustment2D(traverse, traverse.end)!;
    expect(
      exactAdjustment.points.map((point) => point.correction),
      everyElement(Offset.zero),
    );
    expect(exactAdjustment.points.map((point) => point.adjusted), [
      Offset.zero,
      const Offset(0, 3),
      const Offset(4, 3),
    ]);
    expect(
      cadTraverseClosure2D(traverse, const Offset(double.infinity, 0)),
      isNull,
    );
    expect(
      cadBowditchAdjustment2D(traverse, const Offset(double.infinity, 0)),
      isNull,
    );

    final large = cadOpenTraverse2D(const [
      Offset(1000000000000, -1000000000000),
      Offset(1000000000000, -999999999997),
      Offset(1000000000004, -999999999997),
    ])!;
    expect(large.totalLength, 7);
    expect(large.displacement, 5);
    final largeAdjustment = cadBowditchAdjustment2D(
      large,
      const Offset(1000000000004.5, -999999999997.5),
    )!;
    expect(
      largeAdjustment.points.last.adjusted,
      const Offset(1000000000004.5, -999999999997.5),
    );
    expect(largeAdjustment.points[1].correction.dx, closeTo(1.5 / 7, 1e-12));
    expect(largeAdjustment.points[1].correction.dy, closeTo(-1.5 / 7, 1e-12));

    final rotatedFrame = CadLocalCoordinateFrame2D.fromOriginAndXAxis(
      const Offset(20, 30),
      const Offset(20, 40),
    )!;
    final local = cadOpenTraverse2D(
      const [
        Offset(10, 40),
        Offset(10, 50),
      ].map((point) => rotatedFrame.worldToLocal(point)!).toList(),
    )!;
    expect(local.legs.single.direction.azimuthDegrees, 90);

    final closed = cadOpenTraverse2D(const [
      Offset.zero,
      Offset(3, 0),
      Offset(3, 4),
      Offset.zero,
    ])!;
    expect(closed.totalLength, 12);
    expect(closed.displacement, 0);
    expect(closed.displacementDirection, isNull);

    expect(cadOpenTraverse2D(const [Offset.zero]), isNull);
    expect(
      cadOpenTraverse2D(const [Offset.zero, Offset.zero, Offset(1, 0)]),
      isNull,
    );
    expect(
      cadOpenTraverse2D(const [Offset.zero, Offset(double.nan, 1)]),
      isNull,
    );
  });

  test('two-corner rectangle measurement is exact and rejects lines', () {
    final measurement = cadRectangleMeasurement2D(
      const Offset(12, 9),
      const Offset(-3, 1),
    );

    expect(measurement, isNotNull);
    expect(measurement!.width, 15);
    expect(measurement.height, 8);
    expect(measurement.diagonal, 17);
    expect(measurement.center, const Offset(4.5, 5));
    expect(measurement.area, 120);
    expect(measurement.perimeter, 46);
    expect(
      cadRectangleMeasurement2D(const Offset(2, 1), const Offset(2, 8)),
      isNull,
    );
    final large = cadRectangleMeasurement2D(
      const Offset(1000000000000, -2000000000000),
      const Offset(1000000000008, -1999999999996),
    )!;
    expect(large.diagonal, closeTo(math.sqrt(80), 1e-12));
    expect(large.center, const Offset(1000000000004, -1999999999998));
    expect(
      cadRectangleMeasurement2D(
        const Offset(double.nan, 1),
        const Offset(2, 8),
      ),
      isNull,
    );
  });

  test('three-point rotated rectangle projects a strict perpendicular', () {
    final measurement = cadOrientedRectangleMeasurement2D(
      const Offset(1, 2),
      const Offset(4, 6),
      const Offset(1.2, 5.6),
    );

    expect(measurement, isNotNull);
    expect(measurement!.width, closeTo(5, 1e-12));
    expect(measurement.height, closeTo(2, 1e-12));
    expect(measurement.diagonal, closeTo(math.sqrt(29), 1e-12));
    expect(measurement.center.dx, closeTo(1.7, 1e-12));
    expect(measurement.center.dy, closeTo(4.6, 1e-12));
    expect(measurement.area, closeTo(10, 1e-12));
    expect(measurement.perimeter, closeTo(14, 1e-12));
    expect(measurement.directionDegrees, closeTo(53.1301023542, 1e-9));
    final widthEdge = measurement.corners[1] - measurement.corners[0];
    final heightEdge = measurement.corners[3] - measurement.corners[0];
    expect(
      widthEdge.dx * heightEdge.dx + widthEdge.dy * heightEdge.dy,
      closeTo(0, 1e-12),
    );
    expect(
      cadOrientedRectangleMeasurement2D(
        const Offset(1, 1),
        const Offset(1, 1),
        const Offset(3, 4),
      ),
      isNull,
    );
    expect(
      cadOrientedRectangleMeasurement2D(
        Offset.zero,
        const Offset(4, 0),
        const Offset(2, 0),
      ),
      isNull,
    );
  });

  test('three-point triangle reports stable engineering geometry', () {
    final triangle = cadTriangleMeasurement2D(
      const Offset(1000000000000, -2000000000000),
      const Offset(1000000000003, -2000000000000),
      const Offset(1000000000000, -1999999999996),
    )!;
    expect(triangle.angleDegrees, closeTo(90, 1e-12));
    expect(triangle.firstRayLength, closeTo(3, 1e-12));
    expect(triangle.secondRayLength, closeTo(4, 1e-12));
    expect(triangle.oppositeLength, closeTo(5, 1e-12));
    expect(triangle.area, closeTo(6, 1e-12));
    expect(triangle.perimeter, closeTo(12, 1e-12));
    expect(triangle.firstRayPointAngleDegrees, closeTo(53.130102354, 1e-9));
    expect(triangle.secondRayPointAngleDegrees, closeTo(36.869897646, 1e-9));
    expect(
      triangle.angleDegrees +
          triangle.firstRayPointAngleDegrees! +
          triangle.secondRayPointAngleDegrees!,
      closeTo(180, 1e-9),
    );
    expect(triangle.altitudeFromVertex, closeTo(2.4, 1e-12));
    expect(triangle.inradius, closeTo(1, 1e-12));
    expect(triangle.circumradius, closeTo(2.5, 1e-12));

    final straight = cadTriangleMeasurement2D(
      Offset.zero,
      const Offset(2, 0),
      const Offset(-3, 0),
    )!;
    expect(straight.angleDegrees, closeTo(180, 1e-12));
    expect(straight.area, 0);
    expect(straight.perimeter, closeTo(10, 1e-12));
    expect(straight.firstRayPointAngleDegrees, isNull);
    expect(straight.secondRayPointAngleDegrees, isNull);
    expect(straight.altitudeFromVertex, isNull);
    expect(straight.inradius, isNull);
    expect(straight.circumradius, isNull);

    final coincidentRayPoints = cadTriangleMeasurement2D(
      Offset.zero,
      const Offset(2, 0),
      const Offset(2, 0),
    )!;
    expect(coincidentRayPoints.angleDegrees, 0);
    expect(coincidentRayPoints.oppositeLength, 0);
    expect(coincidentRayPoints.area, 0);
    expect(coincidentRayPoints.firstRayPointAngleDegrees, isNull);
    expect(coincidentRayPoints.altitudeFromVertex, isNull);

    expect(
      cadTriangleMeasurement2D(Offset.zero, Offset.zero, const Offset(1, 0)),
      isNull,
    );
  });

  test('three-point circle remains stable at large CAD coordinates', () {
    const center = Offset(1000000000, -2000000000);
    final measurement = cadThreePointCircleMeasurement2D(
      center + const Offset(5, 0),
      center + const Offset(0, 5),
      center + const Offset(-5, 0),
    );

    expect(measurement, isNotNull);
    expect(measurement!.center.dx, closeTo(center.dx, 1e-9));
    expect(measurement.center.dy, closeTo(center.dy, 1e-9));
    expect(measurement.radius, closeTo(5, 1e-12));
    expect(measurement.diameter, closeTo(10, 1e-12));
    expect(measurement.circumference, closeTo(10 * math.pi, 1e-12));
    expect(measurement.area, closeTo(25 * math.pi, 1e-12));
    expect(
      cadThreePointCircleMeasurement2D(
        Offset.zero,
        const Offset(1, 0),
        const Offset(2, 1e-12),
      ),
      isNull,
    );
    expect(
      cadThreePointCircleMeasurement2D(
        Offset.zero,
        Offset.zero,
        const Offset(0, 1),
      ),
      isNull,
    );
  });

  test('three-point arc preserves direction, major arc and zero crossing', () {
    final minor = cadThreePointArcMeasurement2D(
      const Offset(1, 0),
      Offset(math.sqrt1_2, math.sqrt1_2),
      const Offset(0, 1),
    )!;
    expect(minor.center.dx, closeTo(0, 1e-12));
    expect(minor.center.dy, closeTo(0, 1e-12));
    expect(minor.radius, closeTo(1, 1e-12));
    expect(minor.sweepDegrees, closeTo(90, 1e-10));
    expect(minor.arcLength, closeTo(math.pi / 2, 1e-12));
    expect(minor.chordLength, closeTo(math.sqrt2, 1e-12));
    expect(minor.sagitta, closeTo(1 - math.sqrt1_2, 1e-12));
    expect(minor.sectorArea, closeTo(math.pi / 4, 1e-12));
    expect(minor.segmentArea, closeTo(math.pi / 4 - 0.5, 1e-12));
    expect(minor.counterClockwise, isTrue);

    final major = cadThreePointArcMeasurement2D(
      const Offset(1, 0),
      const Offset(0, -1),
      const Offset(0, 1),
    )!;
    expect(major.sweepDegrees, closeTo(270, 1e-10));
    expect(major.arcLength, closeTo(math.pi * 1.5, 1e-12));
    expect(major.sagitta, closeTo(1 + math.sqrt1_2, 1e-12));
    expect(major.sectorArea, closeTo(math.pi * 0.75, 1e-12));
    expect(major.segmentArea, closeTo(math.pi * 0.75 + 0.5, 1e-12));
    expect(major.counterClockwise, isFalse);

    Offset onUnitCircle(double degrees) {
      final radians = degrees * math.pi / 180;
      return Offset(math.cos(radians), math.sin(radians));
    }

    final crossingZero = cadThreePointArcMeasurement2D(
      onUnitCircle(350),
      onUnitCircle(0),
      onUnitCircle(10),
    )!;
    expect(crossingZero.sweepDegrees, closeTo(20, 1e-9));
    expect(crossingZero.counterClockwise, isTrue);

    final clockwise = cadThreePointArcMeasurement2D(
      onUnitCircle(10),
      onUnitCircle(0),
      onUnitCircle(350),
    )!;
    expect(clockwise.sweepDegrees, closeTo(20, 1e-9));
    expect(clockwise.counterClockwise, isFalse);
  });

  test('three-point arc is stable at large coordinates and rejects lines', () {
    const center = Offset(1000000000, -2000000000);
    final arc = cadThreePointArcMeasurement2D(
      center + const Offset(5, 0),
      center + const Offset(0, 5),
      center + const Offset(-5, 0),
    )!;
    expect(arc.center.dx, closeTo(center.dx, 1e-9));
    expect(arc.center.dy, closeTo(center.dy, 1e-9));
    expect(arc.radius, closeTo(5, 1e-12));
    expect(arc.sweepDegrees, closeTo(180, 1e-10));
    expect(arc.arcLength, closeTo(5 * math.pi, 1e-12));
    expect(arc.chordLength, closeTo(10, 1e-12));
    expect(arc.sagitta, closeTo(5, 1e-12));
    expect(arc.sectorArea, closeTo(12.5 * math.pi, 1e-12));
    expect(arc.segmentArea, closeTo(12.5 * math.pi, 1e-12));
    expect(arc.counterClockwise, isTrue);

    expect(
      cadThreePointArcMeasurement2D(
        Offset.zero,
        const Offset(1, 0),
        const Offset(2, 1e-12),
      ),
      isNull,
    );
    expect(
      cadThreePointArcMeasurement2D(
        Offset.zero,
        Offset.zero,
        const Offset(0, 1),
      ),
      isNull,
    );
  });

  test('simple circular curve reports validated minor-arc tangents', () {
    final counterClockwise = cadSimpleCircularCurve2D(
      center: Offset.zero,
      start: const Offset(10, 0),
      end: const Offset(0, 10),
      radius: 10,
      sweepRadians: math.pi / 2,
      counterClockwise: true,
    )!;
    expect(counterClockwise.tangentIntersection.dx, closeTo(10, 1e-12));
    expect(counterClockwise.tangentIntersection.dy, closeTo(10, 1e-12));
    expect(counterClockwise.tangentLength, closeTo(10, 1e-12));
    expect(
      counterClockwise.externalDistance,
      closeTo(10 * (math.sqrt2 - 1), 1e-12),
    );
    expect(
      counterClockwise.middleOrdinate,
      closeTo(10 * (1 - math.sqrt1_2), 1e-12),
    );
    expect(counterClockwise.startTangentDirectionDegrees, closeTo(90, 1e-12));
    expect(counterClockwise.endTangentDirectionDegrees, closeTo(180, 1e-12));

    final clockwise = cadSimpleCircularCurve2D(
      center: Offset.zero,
      start: const Offset(0, 10),
      end: const Offset(10, 0),
      radius: 10,
      sweepRadians: math.pi / 2,
      counterClockwise: false,
    )!;
    expect(clockwise.tangentIntersection.dx, closeTo(10, 1e-12));
    expect(clockwise.tangentIntersection.dy, closeTo(10, 1e-12));
    expect(clockwise.startTangentDirectionDegrees, closeTo(0, 1e-12));
    expect(clockwise.endTangentDirectionDegrees, closeTo(270, 1e-12));

    const center = Offset(1000000000000, -1000000000000);
    final large = cadSimpleCircularCurve2D(
      center: center,
      start: const Offset(1000000000010, -1000000000000),
      end: const Offset(1000000000000, -999999999990),
      radius: 10,
      sweepRadians: math.pi / 2,
      counterClockwise: true,
    )!;
    expect(large.tangentIntersection.dx, closeTo(1000000000010, 1e-4));
    expect(large.tangentIntersection.dy, closeTo(-999999999990, 1e-4));
    expect(large.tangentLength, closeTo(10, 1e-12));

    expect(
      cadSimpleCircularCurve2D(
        center: Offset.zero,
        start: const Offset(10, 0),
        end: const Offset(-10, 0),
        radius: 10,
        sweepRadians: math.pi,
        counterClockwise: true,
      ),
      isNull,
    );
    expect(
      cadSimpleCircularCurve2D(
        center: Offset.zero,
        start: const Offset(10, 0),
        end: const Offset(0, -10),
        radius: 10,
        sweepRadians: 3 * math.pi / 2,
        counterClockwise: true,
      ),
      isNull,
    );
    expect(
      cadSimpleCircularCurve2D(
        center: Offset.zero,
        start: const Offset(10, 0),
        end: const Offset(0, 9),
        radius: 10,
        sweepRadians: math.pi / 2,
        counterClockwise: true,
      ),
      isNull,
    );
  });

  test('directed baseline offset preserves station and left-right sign', () {
    const first = Offset(1000000000, -2000000000);
    const second = Offset(1000000003, -1999999996);
    final leftPoint = first + const Offset(4.4, 9.2);
    final left = cadPointLineMeasurement2D(first, second, leftPoint);

    expect(left, isNotNull);
    expect(left!.station, closeTo(10, 1e-7));
    expect(left.signedOffset, closeTo(2, 1e-7));
    expect(left.perpendicularDistance, closeTo(2, 1e-7));
    expect(left.foot.dx, closeTo(first.dx + 6, 1e-7));
    expect(left.foot.dy, closeTo(first.dy + 8, 1e-7));
    expect(left.directionDegrees, closeTo(53.1301023542, 1e-9));

    final right = cadPointLineMeasurement2D(
      Offset.zero,
      const Offset(10, 0),
      const Offset(-3, -4),
    );
    expect(right, isNotNull);
    expect(right!.station, -3);
    expect(right.signedOffset, -4);
    expect(right.perpendicularDistance, 4);
    expect(right.foot, const Offset(-3, 0));
    expect(
      cadPointLineMeasurement2D(
        const Offset(2, 2),
        const Offset(2, 2),
        const Offset(3, 4),
      ),
      isNull,
    );
  });

  test('polyline station uses finite segments and deterministic chainage', () {
    final baseline = cadPolylineBaselineFromGeometry({
      'kind': 'polyline',
      'points': [
        {'x': 0, 'y': 0},
        {'x': 10, 'y': 0},
        {'x': 10, 'y': 10},
      ],
      'closed': false,
    });
    expect(baseline, isNotNull);
    expect(baseline!.closed, isFalse);
    expect(baseline.points, const [
      Offset(0, 0),
      Offset(10, 0),
      Offset(10, 10),
    ]);

    final left = cadPolylineStationMeasurement2D(
      baseline.points,
      const Offset(5, 2),
    )!;
    expect(left.foot, const Offset(5, 0));
    expect(left.station, 5);
    expect(left.totalLength, 20);
    expect(left.remainingLength, 15);
    expect(left.signedOffset, 2);
    expect(left.perpendicularDistance, 2);
    expect(left.segmentIndex, 0);
    expect(left.directionDegrees, 0);

    final right = cadPolylineStationMeasurement2D(
      baseline.points,
      const Offset(12, 6),
    )!;
    expect(right.foot, const Offset(10, 6));
    expect(right.station, 16);
    expect(right.totalLength, 20);
    expect(right.remainingLength, 4);
    expect(right.signedOffset, -2);
    expect(right.perpendicularDistance, 2);
    expect(right.segmentIndex, 1);
    expect(right.directionDegrees, 90);

    final endpoint = cadPolylineStationMeasurement2D(
      baseline.points,
      const Offset(12, -2),
    )!;
    expect(endpoint.foot, const Offset(10, 0));
    expect(endpoint.station, 10);
    expect(endpoint.perpendicularDistance, closeTo(math.sqrt(8), 1e-12));
    expect(endpoint.segmentIndex, 0);
  });

  test('polyline station handles closed, zero-length and large segments', () {
    final closed = cadPolylineStationMeasurement2D(
      const [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)],
      const Offset(-1, 5),
      closed: true,
    )!;
    expect(closed.foot, const Offset(0, 5));
    expect(closed.station, 35);
    expect(closed.totalLength, 40);
    expect(closed.remainingLength, 5);
    expect(closed.signedOffset, -1);
    expect(closed.segmentIndex, 3);
    expect(closed.directionDegrees, 270);

    final zeroSegment = cadPolylineStationMeasurement2D(const [
      Offset(0, 0),
      Offset(0, 0),
      Offset(10, 0),
    ], const Offset(5, 2))!;
    expect(zeroSegment.station, 5);
    expect(zeroSegment.totalLength, 10);
    expect(zeroSegment.segmentIndex, 1);

    final large = cadPolylineStationMeasurement2D(const [
      Offset(1000000000000, -1000000000000),
      Offset(1000000000010, -1000000000000),
    ], const Offset(1000000000005, -999999999998))!;
    expect(large.station, 5);
    expect(large.signedOffset, 2);
    expect(large.perpendicularDistance, 2);

    expect(
      cadPolylineStationMeasurement2D(const [
        Offset.zero,
        Offset.zero,
      ], const Offset(1, 1)),
      isNull,
    );
    expect(
      cadPolylineStationMeasurement2D(const [
        Offset.zero,
        Offset(double.infinity, 0),
      ], Offset.zero),
      isNull,
    );
    expect(
      cadPolylineBaselineFromGeometry({
        'kind': 'line',
        'start': {'x': 2, 'y': 2},
        'end': {'x': 2, 'y': 2},
      }),
      isNull,
    );
    expect(
      cadPolylineBaselineFromGeometry({
        'kind': 'circle',
        'center': {'x': 0, 'y': 0},
        'radius': 2,
      }),
      isNull,
    );
  });

  test('station offset stakeout follows segments and rejects out of range', () {
    const open = [Offset(0, 0), Offset(10, 0), Offset(10, 10)];
    final secondSegment = cadPolylineStakeoutMeasurement2D(open, 15, 2)!;
    expect(secondSegment.basePoint, const Offset(10, 5));
    expect(secondSegment.targetPoint, const Offset(8, 5));
    expect(secondSegment.station, 15);
    expect(secondSegment.signedOffset, 2);
    expect(secondSegment.totalLength, 20);
    expect(secondSegment.remainingLength, 5);
    expect(secondSegment.segmentIndex, 1);
    expect(secondSegment.directionDegrees, 90);

    final right = cadPolylineStakeoutMeasurement2D(open, 5, -3)!;
    expect(right.basePoint, const Offset(5, 0));
    expect(right.targetPoint, const Offset(5, -3));
    final vertex = cadPolylineStakeoutMeasurement2D(open, 10, 2)!;
    expect(vertex.segmentIndex, 0);
    expect(vertex.targetPoint, const Offset(10, 2));

    const loop = [Offset(0, 0), Offset(10, 0), Offset(10, 10), Offset(0, 10)];
    final closing = cadPolylineStakeoutMeasurement2D(
      loop,
      35,
      -1,
      closed: true,
    )!;
    expect(closing.basePoint, const Offset(0, 5));
    expect(closing.targetPoint, const Offset(-1, 5));
    expect(closing.segmentIndex, 3);
    expect(closing.directionDegrees, 270);
    final loopEnd = cadPolylineStakeoutMeasurement2D(
      loop,
      40,
      0,
      closed: true,
    )!;
    expect(loopEnd.basePoint, Offset.zero);
    expect(loopEnd.remainingLength, 0);

    final large = cadPolylineStakeoutMeasurement2D(
      const [
        Offset(1000000000000, -1000000000000),
        Offset(1000000000010, -1000000000000),
      ],
      5,
      2,
    )!;
    expect(large.targetPoint.dx, closeTo(1000000000005, 1e-4));
    expect(large.targetPoint.dy, closeTo(-999999999998, 1e-4));

    expect(cadPolylineStakeoutMeasurement2D(open, -1, 0), isNull);
    expect(cadPolylineStakeoutMeasurement2D(open, 20.1, 0), isNull);
    expect(cadPolylineStakeoutMeasurement2D(open, 1, double.infinity), isNull);
  });

  test('circular arc station supports projection stakeout and division', () {
    final baseline = cadStationBaselineFromGeometry({
      'kind': 'arc',
      'center': {'x': 0, 'y': 0},
      'radius': 10,
      'start_angle': 0,
      'end_angle': math.pi / 2,
    });
    expect(baseline, isA<CadArcStationBaseline2D>());
    final arc = baseline! as CadArcStationBaseline2D;
    expect(arc.closed, isFalse);
    expect(arc.sweepRadians, closeTo(math.pi / 2, 1e-12));

    final inside = cadStationMeasurement2D(
      arc,
      Offset(4 * math.sqrt2, 4 * math.sqrt2),
    )!;
    expect(inside.foot.dx, closeTo(5 * math.sqrt2, 1e-12));
    expect(inside.foot.dy, closeTo(5 * math.sqrt2, 1e-12));
    expect(inside.station, closeTo(2.5 * math.pi, 1e-12));
    expect(inside.totalLength, closeTo(5 * math.pi, 1e-12));
    expect(inside.remainingLength, closeTo(2.5 * math.pi, 1e-12));
    expect(inside.signedOffset, closeTo(2, 1e-12));
    expect(inside.perpendicularDistance, closeTo(2, 1e-12));
    expect(inside.directionDegrees, closeTo(135, 1e-12));
    expect(inside.elementKind, CadStationElementKind2D.arc);

    final outside = cadArcStationMeasurement2D(
      arc,
      Offset(6 * math.sqrt2, 6 * math.sqrt2),
    )!;
    expect(outside.signedOffset, closeTo(-2, 1e-12));
    expect(outside.perpendicularDistance, closeTo(2, 1e-12));

    final beyondEnd = cadArcStationMeasurement2D(arc, const Offset(-10, 0))!;
    expect(beyondEnd.foot.dx, closeTo(0, 1e-12));
    expect(beyondEnd.foot.dy, closeTo(10, 1e-12));
    expect(beyondEnd.station, closeTo(5 * math.pi, 1e-12));
    expect(beyondEnd.perpendicularDistance, closeTo(10 * math.sqrt2, 1e-12));
    expect(beyondEnd.signedOffset, closeTo(10, 1e-12));
    expect(cadArcStationMeasurement2D(arc, Offset.zero), isNull);

    final stakeout = cadStationStakeoutMeasurement2D(arc, 2.5 * math.pi, 2)!;
    expect(stakeout.basePoint.dx, closeTo(5 * math.sqrt2, 1e-12));
    expect(stakeout.basePoint.dy, closeTo(5 * math.sqrt2, 1e-12));
    expect(stakeout.targetPoint.dx, closeTo(4 * math.sqrt2, 1e-12));
    expect(stakeout.targetPoint.dy, closeTo(4 * math.sqrt2, 1e-12));
    expect(stakeout.directionDegrees, closeTo(135, 1e-12));
    expect(stakeout.elementKind, CadStationElementKind2D.arc);
    expect(cadStationStakeoutMeasurement2D(arc, -1, 0), isNull);
    expect(cadStationStakeoutMeasurement2D(arc, 5 * math.pi + 0.1, 0), isNull);

    final division = cadStationDivisionMeasurement2D(arc, 4)!;
    expect(division.totalLength, closeTo(5 * math.pi, 1e-12));
    expect(division.intervalLength, closeTo(1.25 * math.pi, 1e-12));
    expect(division.divisionPoints, hasLength(5));
    expect(division.divisionPoints.first, const Offset(10, 0));
    expect(division.divisionPoints.last.dx, closeTo(0, 1e-12));
    expect(division.divisionPoints.last.dy, closeTo(10, 1e-12));

    final full = cadArcStationBaselineFromGeometry({
      'kind': 'arc',
      'center': {'x': 2, 'y': 3},
      'radius': 4,
      'start_angle': 0,
      'end_angle': 0,
    })!;
    expect(full.closed, isTrue);
    final fullDivision = cadArcStationDivisionMeasurement2D(full, 4)!;
    expect(fullDivision.divisionPoints, hasLength(4));
    expect(fullDivision.divisionPoints[0], const Offset(6, 3));
    expect(fullDivision.divisionPoints[1].dx, closeTo(2, 1e-12));
    expect(fullDivision.divisionPoints[1].dy, closeTo(7, 1e-12));
    expect(fullDivision.divisionPoints[2].dx, closeTo(-2, 1e-12));
    expect(fullDivision.divisionPoints[2].dy, closeTo(3, 1e-12));

    expect(
      cadStationBaselineFromGeometry({
        'kind': 'arc',
        'center': {'x': 0, 'y': 0},
        'radius': 0,
        'start_angle': 0,
        'end_angle': 1,
      }),
      isNull,
    );
  });

  test('equal divisions produce a checked field stakeout table', () {
    final arc = cadArcStationBaselineFromGeometry({
      'kind': 'arc',
      'center': {'x': 0, 'y': 0},
      'radius': 10,
      'start_angle': 0,
      'end_angle': math.pi / 2,
    })!;
    final arcReport = cadDivisionStakeoutReport2D(arc, 4)!;
    expect(arcReport.divisions, 4);
    expect(arcReport.points, hasLength(5));
    expect(arcReport.hasSimpleCircularCurveValues, isTrue);
    expect(arcReport.points.first.station, 0);
    expect(arcReport.points.first.tangentDirectionDegrees, 90);
    expect(arcReport.points.first.cumulativeDeflectionDegrees, 0);
    expect(arcReport.points.first.longChordFromStart, 0);
    expect(arcReport.points[2].station, closeTo(2.5 * math.pi, 1e-12));
    expect(
      arcReport.points[2].cumulativeDeflectionDegrees,
      closeTo(22.5, 1e-12),
    );
    expect(
      arcReport.points[2].longChordFromStart,
      closeTo(10 * math.sqrt(2 - math.sqrt2), 1e-12),
    );
    expect(arcReport.points.last.station, closeTo(5 * math.pi, 1e-12));
    expect(
      arcReport.points.last.cumulativeDeflectionDegrees,
      closeTo(45, 1e-12),
    );
    expect(
      arcReport.points.last.longChordFromStart,
      closeTo(10 * math.sqrt2, 1e-12),
    );
    expect(arcReport.points.last.tangentDirectionDegrees, closeTo(180, 1e-12));

    final polyline = cadStationBaselineFromGeometry({
      'kind': 'polyline',
      'closed': false,
      'points': [
        {'x': 0, 'y': 0},
        {'x': 10, 'y': 0},
        {'x': 10, 'y': 10},
      ],
    })!;
    final polylineReport = cadDivisionStakeoutReport2D(polyline, 4)!;
    expect(polylineReport.points, hasLength(5));
    expect(polylineReport.hasSimpleCircularCurveValues, isFalse);
    expect(polylineReport.points.map((row) => row.station), [0, 5, 10, 15, 20]);
    expect(polylineReport.points[2].segmentIndex, 0);
    expect(polylineReport.points[2].tangentDirectionDegrees, 0);
    expect(polylineReport.points[3].segmentIndex, 1);
    expect(polylineReport.points[3].tangentDirectionDegrees, 90);
    expect(polylineReport.points.last.point, const Offset(10, 10));
    expect(cadDivisionStakeoutReport2D(polyline, 1), isNull);

    final fullArc = cadArcStationBaselineFromGeometry({
      'kind': 'arc',
      'center': {'x': 0, 'y': 0},
      'radius': 10,
      'start_angle': 0,
      'end_angle': 0,
    })!;
    final fullReport = cadDivisionStakeoutReport2D(fullArc, 4)!;
    expect(fullReport.closed, isTrue);
    expect(fullReport.points, hasLength(4));
    expect(fullReport.hasSimpleCircularCurveValues, isFalse);
    expect(
      fullReport.points.every(
        (row) =>
            row.cumulativeDeflectionDegrees == null &&
            row.longChordFromStart == null,
      ),
      isTrue,
    );
  });

  test('nearest polyline segment follows the tapped edge', () {
    final geometry = <String, dynamic>{
      'kind': 'polyline',
      'closed': true,
      'points': [
        {'x': 0, 'y': 0},
        {'x': 10, 'y': 0},
        {'x': 10, 'y': 10},
        {'x': 0, 'y': 10},
      ],
    };
    final bottom = cadNearestLineSegmentFromGeometry(
      geometry,
      const Offset(6, 0.2),
    )!;
    expect(bottom.segmentIndex, 0);
    expect(bottom.start, const Offset(0, 0));
    expect(bottom.end, const Offset(10, 0));
    expect(bottom.length, 10);
    expect(bottom.directionDegrees, 0);

    final right = cadNearestLineSegmentFromGeometry(
      geometry,
      const Offset(9.8, 6),
    )!;
    expect(right.segmentIndex, 1);
    expect(right.directionDegrees, 90);

    final closing = cadNearestLineSegmentFromGeometry(
      geometry,
      const Offset(-0.2, 6),
    )!;
    expect(closing.segmentIndex, 3);
    expect(closing.directionDegrees, 270);

    expect(
      cadNearestLineSegmentFromGeometry({
        'kind': 'circle',
        'center': const {'x': 0, 'y': 0},
        'radius': 2,
      }, Offset.zero),
      isNull,
    );
  });

  test('extended-line intersection reports angle and required extensions', () {
    CadLineSegment2D segment(Offset start, Offset end, {int index = 0}) {
      final vector = end - start;
      var direction = math.atan2(vector.dy, vector.dx) * 180 / math.pi;
      if (direction < 0) direction += 360;
      return CadLineSegment2D(
        start: start,
        end: end,
        segmentIndex: index,
        length: vector.distance,
        directionDegrees: direction,
      );
    }

    final crossing = cadLineIntersectionMeasurement2D(
      segment(const Offset(0, 0), const Offset(10, 0)),
      segment(const Offset(5, -5), const Offset(5, 5)),
    )!;
    expect(crossing.intersection.dx, closeTo(5, 1e-12));
    expect(crossing.intersection.dy, closeTo(0, 1e-12));
    expect(crossing.includedAngleDegrees, closeTo(90, 1e-12));
    expect(crossing.firstExtensionLength, 0);
    expect(crossing.secondExtensionLength, 0);
    expect(crossing.liesOnBothSegments, isTrue);

    final extended = cadLineIntersectionMeasurement2D(
      segment(const Offset(0, 0), const Offset(5, 0), index: 2),
      segment(const Offset(10, -5), const Offset(10, -1), index: 4),
    )!;
    expect(extended.intersection.dx, closeTo(10, 1e-12));
    expect(extended.intersection.dy, closeTo(0, 1e-12));
    expect(extended.includedAngleDegrees, closeTo(90, 1e-12));
    expect(extended.firstExtensionLength, closeTo(5, 1e-12));
    expect(extended.secondExtensionLength, closeTo(1, 1e-12));
    expect(extended.first.segmentIndex, 2);
    expect(extended.second.segmentIndex, 4);
    expect(extended.liesOnBothSegments, isFalse);

    final large = cadLineIntersectionMeasurement2D(
      segment(
        const Offset(1000000000000, -1000000000000),
        const Offset(1000000000010, -1000000000000),
      ),
      segment(
        const Offset(1000000000005, -1000000000010),
        const Offset(1000000000005, -999999999990),
      ),
    )!;
    expect(large.intersection.dx, closeTo(1000000000005, 1e-4));
    expect(large.intersection.dy, closeTo(-1000000000000, 1e-4));
    expect(large.liesOnBothSegments, isTrue);

    expect(
      cadLineIntersectionMeasurement2D(
        segment(const Offset(0, 0), const Offset(10, 0)),
        segment(const Offset(0, 1), const Offset(10, 1)),
      ),
      isNull,
    );
    expect(
      cadLineIntersectionMeasurement2D(
        segment(const Offset(0, 0), const Offset(10, 0)),
        segment(const Offset(0, 1), const Offset(10, 1.0000000001)),
      ),
      isNull,
    );
  });

  test('parallel line spacing is direction-neutral and stable at scale', () {
    CadLineSegment2D segment(Offset start, Offset end, {int index = 0}) {
      final vector = end - start;
      var direction = math.atan2(vector.dy, vector.dx) * 180 / math.pi;
      if (direction < 0) direction += 360;
      return CadLineSegment2D(
        start: start,
        end: end,
        segmentIndex: index,
        length: vector.distance,
        directionDegrees: direction,
      );
    }

    final horizontal = cadParallelLineSpacingMeasurement2D(
      segment(const Offset(0, 0), const Offset(10, 0), index: 1),
      segment(const Offset(20, 3), const Offset(0, 3), index: 4),
    )!;
    expect(horizontal.spacing, closeTo(3, 1e-12));
    expect(horizontal.directionDegrees, closeTo(0, 1e-12));
    expect(horizontal.first.segmentIndex, 1);
    expect(horizontal.second.segmentIndex, 4);
    expect(horizontal.firstFoot.dy, closeTo(0, 1e-12));
    expect(horizontal.secondFoot.dy, closeTo(3, 1e-12));

    final diagonal = cadParallelLineSpacingMeasurement2D(
      segment(const Offset(0, 0), const Offset(10, 10)),
      segment(const Offset(0, 2), const Offset(10, 12)),
    )!;
    expect(diagonal.spacing, closeTo(math.sqrt(2), 1e-12));
    expect(diagonal.directionDegrees, closeTo(45, 1e-12));

    final large = cadParallelLineSpacingMeasurement2D(
      segment(
        const Offset(1000000000000, -1000000000000),
        const Offset(1000000000020, -1000000000000),
      ),
      segment(
        const Offset(1000000000020, -999999999997),
        const Offset(1000000000000, -999999999997),
      ),
    )!;
    expect(large.spacing, closeTo(3, 1e-4));

    expect(
      cadParallelLineSpacingMeasurement2D(
        segment(const Offset(0, 0), const Offset(10, 0)),
        segment(const Offset(0, 1), const Offset(10, 2)),
      ),
      isNull,
    );
  });

  test('finite segment clearance returns exact closest points', () {
    CadLineSegment2D segment(Offset start, Offset end, {int index = 0}) {
      final vector = end - start;
      var direction = math.atan2(vector.dy, vector.dx) * 180 / math.pi;
      if (direction < 0) direction += 360;
      return CadLineSegment2D(
        start: start,
        end: end,
        segmentIndex: index,
        length: vector.distance,
        directionDegrees: direction,
      );
    }

    final endpoint = cadSegmentClearanceMeasurement2D(
      segment(const Offset(0, 0), const Offset(4, 0), index: 2),
      segment(const Offset(7, 3), const Offset(7, 8), index: 5),
    )!;
    expect(endpoint.clearance, closeTo(math.sqrt(18), 1e-12));
    expect(endpoint.firstClosestPoint, const Offset(4, 0));
    expect(endpoint.secondClosestPoint, const Offset(7, 3));
    expect(endpoint.first.segmentIndex, 2);
    expect(endpoint.second.segmentIndex, 5);
    expect(endpoint.intersects, isFalse);

    final perpendicular = cadSegmentClearanceMeasurement2D(
      segment(const Offset(0, 0), const Offset(10, 0)),
      segment(const Offset(4, 3), const Offset(4, 7)),
    )!;
    expect(perpendicular.clearance, closeTo(3, 1e-12));
    expect(perpendicular.firstClosestPoint, const Offset(4, 0));
    expect(perpendicular.secondClosestPoint, const Offset(4, 3));

    final crossing = cadSegmentClearanceMeasurement2D(
      segment(const Offset(0, 0), const Offset(10, 10)),
      segment(const Offset(0, 10), const Offset(10, 0)),
    )!;
    expect(crossing.clearance, 0);
    expect(crossing.firstClosestPoint.dx, closeTo(5, 1e-12));
    expect(crossing.firstClosestPoint.dy, closeTo(5, 1e-12));
    expect(crossing.secondClosestPoint, crossing.firstClosestPoint);
    expect(crossing.intersects, isTrue);

    final overlapping = cadSegmentClearanceMeasurement2D(
      segment(const Offset(0, 0), const Offset(10, 0)),
      segment(const Offset(4, 0), const Offset(12, 0)),
    )!;
    expect(overlapping.clearance, 0);
    expect(overlapping.firstClosestPoint, const Offset(4, 0));
    expect(overlapping.secondClosestPoint, const Offset(4, 0));

    final large = cadSegmentClearanceMeasurement2D(
      segment(
        const Offset(1000000000000, -1000000000000),
        const Offset(1000000000020, -1000000000000),
      ),
      segment(
        const Offset(1000000000025, -999999999997),
        const Offset(1000000000030, -999999999997),
      ),
    )!;
    expect(large.clearance, closeTo(math.sqrt(34), 1e-4));
    expect(
      large.firstClosestPoint,
      const Offset(1000000000020, -1000000000000),
    );
    expect(
      large.secondClosestPoint,
      const Offset(1000000000025, -999999999997),
    );

    expect(
      cadSegmentClearanceMeasurement2D(
        segment(Offset.zero, Offset.zero),
        segment(const Offset(0, 1), const Offset(1, 1)),
      ),
      isNull,
    );
  });

  test('CAD length, area, volume and section units convert by dimension', () {
    final millimeters = cadEngineeringUnitById('mm')!;
    final meters = cadEngineeringUnitById('m')!;
    final inches = cadEngineeringUnitById('in')!;
    expect(convertCadLength(1000, millimeters, meters), closeTo(1, 1e-12));
    expect(convertCadLength(25.4, millimeters, inches), closeTo(1, 1e-12));
    expect(convertCadArea(1000000, millimeters, meters), closeTo(1, 1e-12));
    expect(
      convertCadVolume(1000000000, millimeters, meters),
      closeTo(1, 1e-12),
    );
    expect(
      convertCadFourthPower(1000000000000, millimeters, meters),
      closeTo(1, 1e-12),
    );
    expect(
      cadDrawingVolumeToDisplayUnits(
        1000000000,
        source: millimeters,
        display: meters,
      ),
      closeTo(1, 1e-12),
    );
    expect(
      cadDrawingFourthPowerToDisplayUnits(
        1000000000000,
        source: millimeters,
        display: meters,
      ),
      closeTo(1, 1e-12),
    );
    expect(
      cadDrawingFourthPowerToDisplayUnits(
        6250000,
        display: meters,
        metersPerDrawingUnit: 0.02,
      ),
      closeTo(1, 1e-12),
    );
    expect(
      cadDisplayLengthToDrawingUnits(
        -2,
        source: millimeters,
        display: cadEngineeringUnitById('cm'),
      ),
      closeTo(-20, 1e-12),
    );
    expect(
      cadDisplayAreaToDrawingUnits(
        2,
        source: millimeters,
        display: cadEngineeringUnitById('cm'),
      ),
      closeTo(200, 1e-12),
    );
    expect(
      cadDisplayAreaToDrawingUnits(
        4,
        display: meters,
        metersPerDrawingUnit: 0.5,
      ),
      closeTo(16, 1e-12),
    );
    expect(
      cadDisplayLengthToDrawingUnits(
        10,
        source: millimeters,
        display: meters,
        metersPerDrawingUnit: 0.5,
      ),
      closeTo(20, 1e-12),
    );
    expect(
      cadDrawingLengthToDisplayUnits(
        20,
        source: millimeters,
        display: cadEngineeringUnitById('cm'),
      ),
      closeTo(2, 1e-12),
    );
    expect(
      cadDrawingLengthToDisplayUnits(
        20,
        source: millimeters,
        display: meters,
        metersPerDrawingUnit: 0.5,
      ),
      closeTo(10, 1e-12),
    );
    expect(cadDisplayLengthToDrawingUnits(double.infinity), isNull);
    expect(cadDisplayAreaToDrawingUnits(double.infinity), isNull);
    expect(cadDrawingLengthToDisplayUnits(double.infinity), isNull);
    expect(cadDrawingVolumeToDisplayUnits(double.infinity), isNull);
    expect(cadDrawingFourthPowerToDisplayUnits(double.infinity), isNull);
    expect(
      cadDrawingFourthPowerToDisplayUnits(
        1,
        display: meters,
        metersPerDrawingUnit: 0,
      ),
      isNull,
    );
    expect(
      cadDisplayLengthToDrawingUnits(
        1,
        display: meters,
        metersPerDrawingUnit: 0,
      ),
      isNull,
    );
    expect(
      cadDisplayAreaToDrawingUnits(1, display: meters, metersPerDrawingUnit: 0),
      isNull,
    );
    expect(cadEngineeringUnitById(null), isNull);
    expect(cadEngineeringUnitById('unknown'), isNull);
  });

  test('area coverage quantity rounds procurement units safely', () {
    final result = cadCoverageQuantityMeasurement2D(100, 9, 10)!;
    expect(result.area, 100);
    expect(result.coveragePerUnit, 9);
    expect(result.wastePercent, 10);
    expect(result.adjustedArea, closeTo(110, 1e-12));
    expect(result.exactUnits, closeTo(110 / 9, 1e-12));
    expect(result.wholeUnits, 13);
    expect(result.procuredCoverageArea, 117);
    expect(result.surplusArea, closeTo(7, 1e-12));

    final exact = cadCoverageQuantityMeasurement2D(10, 2, 0)!;
    expect(exact.exactUnits, 5);
    expect(exact.wholeUnits, 5);
    expect(exact.surplusArea, 0);

    final floatingInteger = cadCoverageQuantityMeasurement2D(0.3, 0.1, 0)!;
    expect(floatingInteger.exactUnits, closeTo(3, 1e-12));
    expect(floatingInteger.wholeUnits, 3);
    expect(floatingInteger.surplusArea, 0);

    final fractionalSingleUnit = cadCoverageQuantityMeasurement2D(1e-15, 1, 0)!;
    expect(fractionalSingleUnit.exactUnits, 1e-15);
    expect(fractionalSingleUnit.wholeUnits, 1);
    expect(fractionalSingleUnit.surplusArea, closeTo(1 - 1e-15, 1e-15));

    for (final scale in [1e-18, 1e-9, 1.0, 1e9, 1e100]) {
      final scaled = cadCoverageQuantityMeasurement2D(
        1.0 * scale,
        0.3 * scale,
        0,
      )!;
      expect(scaled.exactUnits, closeTo(10 / 3, 1e-12));
      expect(scaled.wholeUnits, 4);
      expect(scaled.surplusArea / scale, closeTo(0.2, 1e-12));
    }

    final maximum = cadCoverageQuantityMeasurement2D(
      cadMaximumCoverageUnits.toDouble(),
      1,
      0,
    )!;
    expect(maximum.wholeUnits, cadMaximumCoverageUnits);

    final fullWaste = cadCoverageQuantityMeasurement2D(10, 2, 100)!;
    expect(fullWaste.adjustedArea, 20);
    expect(fullWaste.wholeUnits, 10);

    expect(cadCoverageQuantityMeasurement2D(0, 1, 0), isNull);
    expect(cadCoverageQuantityMeasurement2D(1, 0, 0), isNull);
    expect(cadCoverageQuantityMeasurement2D(1, 1, -0.1), isNull);
    expect(cadCoverageQuantityMeasurement2D(1, 1, 100.1), isNull);
    expect(cadCoverageQuantityMeasurement2D(double.maxFinite, 1, 100), isNull);
    expect(
      cadCoverageQuantityMeasurement2D(cadMaximumCoverageUnits + 1.0, 1, 0),
      isNull,
    );
  });

  test(
    'linear material quantity shares bounded stable whole-unit rounding',
    () {
      final result = cadLinearQuantityMeasurement2D(2 * math.pi, 2, 10)!;
      expect(result.length, closeTo(2 * math.pi, 1e-12));
      expect(result.lengthPerUnit, 2);
      expect(result.wastePercent, 10);
      expect(result.adjustedLength, closeTo(2.2 * math.pi, 1e-12));
      expect(result.exactUnits, closeTo(1.1 * math.pi, 1e-12));
      expect(result.wholeUnits, 4);
      expect(result.procuredLength, 8);
      expect(result.surplusLength, closeTo(8 - 2.2 * math.pi, 1e-12));

      final decimal = cadLinearQuantityMeasurement2D(0.3, 0.1, 0)!;
      expect(decimal.wholeUnits, 3);
      expect(decimal.surplusLength, 0);

      final tiny = cadLinearQuantityMeasurement2D(1e-18, 3e-19, 0)!;
      expect(tiny.wholeUnits, 4);
      expect(tiny.surplusLength, closeTo(2e-19, 1e-30));

      expect(cadLinearQuantityMeasurement2D(0, 1, 0), isNull);
      expect(cadLinearQuantityMeasurement2D(1, 0, 0), isNull);
      expect(cadLinearQuantityMeasurement2D(1, 1, -0.1), isNull);
      expect(cadLinearQuantityMeasurement2D(1, 1, 100.1), isNull);
      expect(
        cadLinearQuantityMeasurement2D(cadMaximumCoverageUnits + 1.0, 1, 0),
        isNull,
      );
    },
  );

  test('plan run and vertical rise produce a scale-stable slope', () {
    final result = cadPlanSlopeMeasurement2D(3, 4)!;
    expect(result.horizontalRun, 3);
    expect(result.verticalRise, 4);
    expect(result.slopeLength, 5);
    expect(result.gradePercent, closeTo(400 / 3, 1e-12));
    expect(result.slopeRatio, closeTo(0.75, 1e-12));
    expect(result.slopeAngleDegrees, closeTo(53.1301023542, 1e-10));

    final level = cadPlanSlopeMeasurement2D(8, 0)!;
    expect(level.slopeLength, 8);
    expect(level.gradePercent, 0);
    expect(level.slopeRatio, double.infinity);
    expect(level.slopeAngleDegrees, 0);

    for (final scale in [1e-300, 1e-100, 1e-18, 1.0, 1e18, 1e100, 1e200]) {
      final scaled = cadPlanSlopeMeasurement2D(3 * scale, 4 * scale)!;
      expect(scaled.slopeLength / scale, closeTo(5, 1e-12));
      expect(scaled.gradePercent, closeTo(400 / 3, 1e-12));
      expect(scaled.slopeRatio, closeTo(0.75, 1e-12));
      expect(scaled.slopeAngleDegrees, closeTo(53.1301023542, 1e-10));
    }

    expect(cadPlanSlopeMeasurement2D(0, 1), isNull);
    expect(cadPlanSlopeMeasurement2D(-1, 1), isNull);
    expect(cadPlanSlopeMeasurement2D(1, -1), isNull);
    expect(cadPlanSlopeMeasurement2D(double.infinity, 1), isNull);
    expect(cadPlanSlopeMeasurement2D(1, double.nan), isNull);
    expect(
      cadPlanSlopeMeasurement2D(double.maxFinite, double.maxFinite),
      isNull,
    );
  });

  test('validated plan area and positive depth produce prismatic volume', () {
    final result = cadPrismaticVolumeMeasurement2D(24, 0.2)!;
    expect(result.area, 24);
    expect(result.depth, 0.2);
    expect(result.volume, closeTo(4.8, 1e-12));
    expect(cadPrismaticVolumeMeasurement2D(0, 1), isNull);
    expect(cadPrismaticVolumeMeasurement2D(-1, 1), isNull);
    expect(cadPrismaticVolumeMeasurement2D(1, 0), isNull);
    expect(cadPrismaticVolumeMeasurement2D(1, double.infinity), isNull);
    expect(cadPrismaticVolumeMeasurement2D(double.maxFinite, 2), isNull);
  });

  test('average end areas and positive interval produce finite volume', () {
    final result = cadAverageEndAreaVolumeMeasurement2D(12, 20, 5)!;
    expect(result.firstArea, 12);
    expect(result.secondArea, 20);
    expect(result.intervalLength, 5);
    expect(result.meanArea, 16);
    expect(result.volume, 80);

    final daylight = cadAverageEndAreaVolumeMeasurement2D(12, 0, 5)!;
    expect(daylight.meanArea, 6);
    expect(daylight.volume, 30);

    expect(cadAverageEndAreaVolumeMeasurement2D(0, 0, 5), isNull);
    expect(cadAverageEndAreaVolumeMeasurement2D(-1, 2, 5), isNull);
    expect(cadAverageEndAreaVolumeMeasurement2D(1, -2, 5), isNull);
    expect(cadAverageEndAreaVolumeMeasurement2D(1, 2, 0), isNull);
    expect(cadAverageEndAreaVolumeMeasurement2D(1, 2, double.infinity), isNull);
    expect(
      cadAverageEndAreaVolumeMeasurement2D(
        double.maxFinite,
        double.maxFinite,
        1,
      )?.meanArea,
      double.maxFinite,
    );
    expect(
      cadAverageEndAreaVolumeMeasurement2D(double.maxFinite, 1, 2)?.volume,
      double.maxFinite,
    );
    expect(
      cadAverageEndAreaVolumeMeasurement2D(double.maxFinite, 1, 3),
      isNull,
    );
  });

  test('prismoidal volume requires an exact midpoint section', () {
    final result = cadPrismoidalVolumeMeasurement2D(12, 18, 24, 5)!;
    expect(result.firstArea, 12);
    expect(result.midpointArea, 18);
    expect(result.secondArea, 24);
    expect(result.intervalLength, 5);
    expect(result.weightedMeanArea, closeTo(18, 1e-12));
    expect(result.volume, closeTo(90, 1e-12));

    final daylight = cadPrismoidalVolumeMeasurement2D(0, 6, 0, 3)!;
    expect(daylight.weightedMeanArea, 4);
    expect(daylight.volume, 12);

    for (final scale in [1e-100, 1e-18, 1.0, 1e18, 1e100]) {
      final scaled = cadPrismoidalVolumeMeasurement2D(
        12 * scale,
        18 * scale,
        24 * scale,
        5,
      )!;
      expect(scaled.weightedMeanArea / scale, closeTo(18, 1e-12));
      expect(scaled.volume / scale, closeTo(90, 1e-12));
    }

    final large = cadPrismoidalVolumeMeasurement2D(
      double.maxFinite,
      double.maxFinite,
      double.maxFinite,
      1,
    )!;
    expect(large.weightedMeanArea.isFinite, isTrue);
    expect(large.volume.isFinite, isTrue);

    expect(cadPrismoidalVolumeMeasurement2D(0, 0, 0, 1), isNull);
    expect(cadPrismoidalVolumeMeasurement2D(-1, 2, 3, 1), isNull);
    expect(cadPrismoidalVolumeMeasurement2D(1, -2, 3, 1), isNull);
    expect(cadPrismoidalVolumeMeasurement2D(1, 2, -3, 1), isNull);
    expect(cadPrismoidalVolumeMeasurement2D(1, 2, 3, 0), isNull);
    expect(cadPrismoidalVolumeMeasurement2D(1, 2, 3, double.infinity), isNull);
    expect(
      cadPrismoidalVolumeMeasurement2D(
        double.maxFinite,
        double.maxFinite,
        double.maxFinite,
        2,
      ),
      isNull,
    );
  });

  test('validated perimeter and positive height produce lateral area', () {
    final result = cadExtrudedPerimeterAreaMeasurement2D(14, 3)!;
    expect(result.perimeter, 14);
    expect(result.height, 3);
    expect(result.lateralArea, 42);
    expect(cadExtrudedPerimeterAreaMeasurement2D(0, 1), isNull);
    expect(cadExtrudedPerimeterAreaMeasurement2D(-1, 1), isNull);
    expect(cadExtrudedPerimeterAreaMeasurement2D(1, 0), isNull);
    expect(cadExtrudedPerimeterAreaMeasurement2D(1, double.infinity), isNull);
    expect(cadExtrudedPerimeterAreaMeasurement2D(double.maxFinite, 2), isNull);
  });

  test('known-distance calibration scales length and area consistently', () {
    final millimeters = cadEngineeringUnitById('mm')!;
    final meters = cadEngineeringUnitById('m')!;
    final scale = cadCalibrationMetersPerDrawingUnit(
      drawingDistance: 250,
      knownLength: 5,
      knownUnit: meters,
    );

    expect(scale, closeTo(0.02, 1e-12));
    expect(
      convertCalibratedCadLength(50, scale!, millimeters),
      closeTo(1000, 1e-12),
    );
    expect(convertCalibratedCadArea(2500, scale, meters), closeTo(1, 1e-12));
    expect(
      convertCalibratedCadVolume(125000, scale, meters),
      closeTo(1, 1e-12),
    );
    expect(
      cadDrawingVolumeToDisplayUnits(
        125000,
        display: meters,
        metersPerDrawingUnit: scale,
      ),
      closeTo(1, 1e-12),
    );
    expect(
      cadCalibrationMetersPerDrawingUnit(
        drawingDistance: 0,
        knownLength: 5,
        knownUnit: meters,
      ),
      isNull,
    );
    expect(
      cadCalibrationMetersPerDrawingUnit(
        drawingDistance: 5,
        knownLength: double.nan,
        knownUnit: meters,
      ),
      isNull,
    );
  });

  test('material mass converts explicit density units consistently', () {
    final metric = cadMaterialMassMeasurement(
      2,
      2400,
      CadDensityUnit.kilogramsPerCubicMeter,
    )!;
    expect(metric.densityKilogramsPerCubicMeter, 2400);
    expect(metric.massKilograms, 4800);
    expect(metric.massTonnes, 4.8);
    expect(metric.massPounds, closeTo(10582.188584874124, 1e-9));

    final tonnes = cadMaterialMassMeasurement(
      2,
      2.4,
      CadDensityUnit.tonnesPerCubicMeter,
    )!;
    expect(tonnes.massKilograms, closeTo(metric.massKilograms, 1e-12));
    expect(
      cadDensityKilogramsPerCubicMeter(150, CadDensityUnit.poundsPerCubicFoot),
      closeTo(2402.769506094021, 1e-9),
    );
    expect(
      cadMaterialMassMeasurement(
        0,
        2400,
        CadDensityUnit.kilogramsPerCubicMeter,
      ),
      isNull,
    );
    expect(
      cadMaterialMassMeasurement(1, 0, CadDensityUnit.kilogramsPerCubicMeter),
      isNull,
    );
    expect(
      cadMaterialMassMeasurement(
        double.maxFinite,
        double.maxFinite,
        CadDensityUnit.kilogramsPerCubicMeter,
      ),
      isNull,
    );
  });

  test('engineering values use bounded precision without negative zero', () {
    expect(formatEngineeringValue(12.346, 2), '12.35');
    expect(formatEngineeringValue(12.6, 0), '13');
    expect(formatEngineeringValue(-0.0001, 3), '0.000');
    expect(formatEngineeringValue(1.23456789, 9), '1.234568');
    expect(formatEngineeringValue(1.6, -1), '2');
  });

  test('standard 3D views align to engineering world axes', () {
    final document = CadDocumentModel.fromJson({
      'metadata': {'format': 'stl', 'display_name': 'axes.stl'},
      'scene': {
        'scene_kind': 'three_d',
        'scene': {
          'meshes': <Object>[],
          'root_nodes': <Object>[],
          'bounds': {
            'min': {'x': -1, 'y': -1, 'z': -1},
            'max': {'x': 1, 'y': 1, 'z': 1},
          },
        },
      },
      'diagnostics': <Object>[],
    });
    Cad3DViewTransform transform(CadStandardView view) {
      final orientation = cadStandardViewOrientation(view);
      return Cad3DViewTransform.forScene(
        document,
        const Size(400, 400),
        1,
        Offset.zero,
        orientation.yaw,
        orientation.pitch,
      );
    }

    void expectAxis(CadPoint3 actual, double x, double y, double z) {
      expect(actual.x, closeTo(x, 1e-12));
      expect(actual.y, closeTo(y, 1e-12));
      expect(actual.z, closeTo(z, 1e-12));
    }

    final front = transform(CadStandardView.front);
    expectAxis(front.cameraAxis, 0, -1, 0);
    expectAxis(front.right, 1, 0, 0);
    expectAxis(front.up, 0, 0, 1);

    final top = transform(CadStandardView.top);
    expectAxis(top.cameraAxis, 0, 0, 1);
    expectAxis(top.right, 1, 0, 0);
    expectAxis(top.up, 0, 1, 0);

    final right = transform(CadStandardView.right);
    expectAxis(right.cameraAxis, 1, 0, 0);
    expectAxis(right.right, 0, 1, 0);
    expectAxis(right.up, 0, 0, 1);

    final isometric = transform(CadStandardView.isometric).cameraAxis;
    expect(isometric.x, greaterThan(0));
    expect(isometric.y, lessThan(0));
    expect(isometric.z, greaterThan(0));
  });

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

    final topOrientation = cadStandardViewOrientation(CadStandardView.top);
    final top = Cad3DViewTransform.forScene(
      document,
      const Size(400, 400),
      1,
      Offset.zero,
      topOrientation.yaw,
      topOrientation.pitch,
    );
    const surfacePoint = CadPoint3(0.2, 0.1, 0);
    final surfaceHit = top.hitTest(document, top.project(surfacePoint));
    expect(surfaceHit, isNotNull);
    expect(surfaceHit!.position.x, closeTo(surfacePoint.x, 1e-9));
    expect(surfaceHit.position.y, closeTo(surfacePoint.y, 1e-9));
    expect(surfaceHit.position.z, closeTo(surfacePoint.z, 1e-9));

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

  test('polygon area closes the selected boundary', () {
    expect(
      polygonArea2D(const [
        Offset(0, 0),
        Offset(6, 0),
        Offset(6, 4),
        Offset(0, 4),
      ]),
      24,
    );
    expect(
      polygonArea2D(const [
        Offset(1000000000000, 1000000000000),
        Offset(1000000000006, 1000000000000),
        Offset(1000000000006, 1000000000004),
        Offset(1000000000000, 1000000000004),
      ]),
      closeTo(24, 1e-12),
    );
    expect(polygonArea2D(const [Offset.zero, Offset(1, 0)]), 0);
  });

  test(
    'validated area rejects self-intersecting and degenerate boundaries',
    () {
      expect(
        simplePolygonArea2D(const [
          Offset(0, 0),
          Offset(4, 0),
          Offset(0, 3),
          Offset(0, 0),
        ]),
        closeTo(6, 1e-12),
      );
      expect(
        simplePolygonArea2D(const [
          Offset(0, 0),
          Offset(4, 4),
          Offset(0, 4),
          Offset(4, 0),
        ]),
        isNull,
      );
      expect(
        simplePolygonArea2D(const [Offset(0, 0), Offset(2, 0), Offset(4, 0)]),
        isNull,
      );
    },
  );

  test('polygon centroid is stable for large coordinates and winding', () {
    const largeRectangle = [
      Offset(1000000000000, -2000000000000),
      Offset(1000000000008, -2000000000000),
      Offset(1000000000008, -1999999999996),
      Offset(1000000000000, -1999999999996),
    ];
    expect(
      cadPolygonCentroid2D(largeRectangle),
      const Offset(1000000000004, -1999999999998),
    );
    expect(
      cadPolygonCentroid2D(largeRectangle.reversed.toList()),
      const Offset(1000000000004, -1999999999998),
    );
    expect(
      cadPolygonCentroid2D(const [
        Offset(0, 0),
        Offset(6, 0),
        Offset(0, 3),
        Offset(0, 0),
      ]),
      const Offset(2, 1),
    );
    expect(
      cadPolygonCentroid2D(const [
        Offset(0, 0),
        Offset(4, 4),
        Offset(0, 4),
        Offset(4, 0),
      ]),
      isNull,
    );
    expect(
      cadPolygonCentroid2D(const [Offset(0, 0), Offset(2, 0), Offset(4, 0)]),
      isNull,
    );
  });

  test('section properties are stable for large coordinates and winding', () {
    const rectangle = [
      Offset(1000000000000, -2000000000000),
      Offset(1000000000004, -2000000000000),
      Offset(1000000000004, -1999999999998),
      Offset(1000000000000, -1999999999998),
    ];
    final properties = cadPolygonSectionProperties2D(rectangle)!;
    expect(properties.area, closeTo(8, 1e-12));
    expect(properties.centroid, const Offset(1000000000002, -1999999999999));
    expect(properties.centroidalMomentX, closeTo(8 / 3, 1e-12));
    expect(properties.centroidalMomentY, closeTo(32 / 3, 1e-12));
    expect(properties.centroidalProductXY, closeTo(0, 1e-12));
    expect(properties.polarMoment, closeTo(40 / 3, 1e-12));
    expect(properties.principalMomentMaximum, closeTo(32 / 3, 1e-12));
    expect(properties.principalMomentMinimum, closeTo(8 / 3, 1e-12));
    expect(properties.principalAxisMaximumDegrees, closeTo(90, 1e-12));
    expect(properties.sectionModulusXPositiveY, closeTo(8 / 3, 1e-12));
    expect(properties.sectionModulusXNegativeY, closeTo(8 / 3, 1e-12));
    expect(properties.sectionModulusYPositiveX, closeTo(16 / 3, 1e-12));
    expect(properties.sectionModulusYNegativeX, closeTo(16 / 3, 1e-12));
    expect(properties.radiusOfGyrationX, closeTo(math.sqrt(1 / 3), 1e-12));
    expect(properties.radiusOfGyrationY, closeTo(math.sqrt(4 / 3), 1e-12));

    final reversed = cadPolygonSectionProperties2D(
      rectangle.reversed.toList(),
    )!;
    expect(
      reversed.centroidalMomentX,
      closeTo(properties.centroidalMomentX, 1e-12),
    );
    expect(
      reversed.centroidalMomentY,
      closeTo(properties.centroidalMomentY, 1e-12),
    );
    expect(
      reversed.centroidalProductXY,
      closeTo(properties.centroidalProductXY, 1e-12),
    );
    expect(
      reversed.principalAxisMaximumDegrees,
      closeTo(properties.principalAxisMaximumDegrees!, 1e-12),
    );

    final rotated = cadPolygonSectionProperties2D(const [
      Offset(0, 0),
      Offset(0, 4),
      Offset(-2, 4),
      Offset(-2, 0),
    ])!;
    expect(rotated.centroidalMomentX, closeTo(32 / 3, 1e-12));
    expect(rotated.centroidalMomentY, closeTo(8 / 3, 1e-12));
    expect(rotated.centroidalProductXY, closeTo(0, 1e-12));
    expect(rotated.principalMomentMaximum, closeTo(32 / 3, 1e-12));
    expect(rotated.principalMomentMinimum, closeTo(8 / 3, 1e-12));
    expect(rotated.principalAxisMaximumDegrees, closeTo(0, 1e-12));
    expect(rotated.sectionModulusXPositiveY, closeTo(16 / 3, 1e-12));
    expect(rotated.sectionModulusXNegativeY, closeTo(16 / 3, 1e-12));
    expect(rotated.sectionModulusYPositiveX, closeTo(8 / 3, 1e-12));
    expect(rotated.sectionModulusYNegativeX, closeTo(8 / 3, 1e-12));

    final diagonalCosine = math.sqrt(0.5);
    Offset rotate45(double x, double y) =>
        Offset((x - y) * diagonalCosine, (x + y) * diagonalCosine);
    final diagonal = cadPolygonSectionProperties2D([
      rotate45(-2, -1),
      rotate45(2, -1),
      rotate45(2, 1),
      rotate45(-2, 1),
    ])!;
    expect(diagonal.principalMomentMaximum, closeTo(32 / 3, 1e-10));
    expect(diagonal.principalMomentMinimum, closeTo(8 / 3, 1e-10));
    expect(diagonal.principalAxisMaximumDegrees, closeTo(135, 1e-10));

    final tiny = cadPolygonSectionProperties2D(const [
      Offset(0, 0),
      Offset(4e-9, 0),
      Offset(4e-9, 2e-9),
      Offset(0, 2e-9),
    ])!;
    expect(tiny.principalMomentMaximum, closeTo(32e-36 / 3, 1e-46));
    expect(tiny.principalMomentMinimum, closeTo(8e-36 / 3, 1e-46));
    expect(tiny.principalAxisMaximumDegrees, closeTo(90, 1e-10));

    final circle = cadCircleSectionProperties2D(Offset.zero, 2)!;
    expect(circle.area, closeTo(4 * math.pi, 1e-12));
    expect(circle.centroidalMomentX, closeTo(4 * math.pi, 1e-12));
    expect(circle.centroidalMomentY, closeTo(4 * math.pi, 1e-12));
    expect(circle.polarMoment, closeTo(8 * math.pi, 1e-12));
    expect(circle.radiusOfGyrationX, closeTo(1, 1e-12));
    expect(circle.radiusOfGyrationY, closeTo(1, 1e-12));
    expect(circle.principalMomentMaximum, closeTo(4 * math.pi, 1e-12));
    expect(circle.principalMomentMinimum, closeTo(4 * math.pi, 1e-12));
    expect(circle.principalAxisMaximumDegrees, isNull);
    expect(circle.sectionModulusXPositiveY, closeTo(2 * math.pi, 1e-12));
    expect(circle.sectionModulusXNegativeY, closeTo(2 * math.pi, 1e-12));
    expect(circle.sectionModulusYPositiveX, closeTo(2 * math.pi, 1e-12));
    expect(circle.sectionModulusYNegativeX, closeTo(2 * math.pi, 1e-12));

    final triangle = cadPolygonSectionProperties2D(const [
      Offset(0, 0),
      Offset(6, 0),
      Offset(0, 3),
    ])!;
    expect(triangle.centroid, const Offset(2, 1));
    expect(triangle.sectionModulusXPositiveY, closeTo(2.25, 1e-12));
    expect(triangle.sectionModulusXNegativeY, closeTo(4.5, 1e-12));
    expect(triangle.sectionModulusYPositiveX, closeTo(4.5, 1e-12));
    expect(triangle.sectionModulusYNegativeX, closeTo(9, 1e-12));

    final square = cadPolygonSectionProperties2D(const [
      Offset(-1, -1),
      Offset(1, -1),
      Offset(1, 1),
      Offset(-1, 1),
    ])!;
    expect(square.principalMomentMaximum, closeTo(4 / 3, 1e-12));
    expect(square.principalMomentMinimum, closeTo(4 / 3, 1e-12));
    expect(square.principalAxisMaximumDegrees, isNull);

    expect(
      cadPolygonSectionProperties2D(const [
        Offset(0, 0),
        Offset(4, 4),
        Offset(0, 4),
        Offset(4, 0),
      ]),
      isNull,
    );
    expect(
      cadPolygonSectionProperties2D(const [
        Offset(0, 0),
        Offset(double.infinity, 0),
        Offset(0, 1),
      ]),
      isNull,
    );
    expect(cadCircleSectionProperties2D(Offset.zero, 0), isNull);
  });

  test('path length distinguishes open length from closed perimeter', () {
    const points = [Offset(0, 0), Offset(3, 4), Offset(3, 0)];
    expect(polylineLength2D(points), closeTo(9, 1e-12));
    expect(polylineLength2D(points, closed: true), closeTo(12, 1e-12));
    expect(polylineLength2D(const [Offset.zero]), 0);
  });

  test('two-point engineering delta preserves drawing-axis signs', () {
    expect(
      measurementDelta2D(const Offset(10, 20), const Offset(13, 15)),
      const Offset(3, -5),
    );
  });

  test('direction angle is counter-clockwise from drawing positive X', () {
    expect(
      directionDegrees2D(Offset.zero, const Offset(1, 0)),
      closeTo(0, 1e-12),
    );
    expect(
      directionDegrees2D(Offset.zero, const Offset(0, 1)),
      closeTo(90, 1e-12),
    );
    expect(
      directionDegrees2D(Offset.zero, const Offset(-1, 0)),
      closeTo(180, 1e-12),
    );
    expect(
      directionDegrees2D(Offset.zero, const Offset(0, -1)),
      closeTo(270, 1e-12),
    );
    for (final scale in [1e-300, 1e-18, 1.0, 1e18, 1e200]) {
      expect(
        directionDegrees2D(Offset.zero, Offset(3 * scale, 4 * scale)),
        closeTo(53.1301023542, 1e-9),
      );
    }
    expect(directionDegrees2D(Offset.zero, Offset.zero), isNull);
    expect(
      directionDegrees2D(Offset.zero, const Offset(double.infinity, 0)),
      isNull,
    );
  });

  test('entity properties use the same visible CAD geometry', () {
    final line = cadEntityMetrics2D({
      'kind': 'line',
      'start': {'x': 0, 'y': 0},
      'end': {'x': 3, 'y': 4},
    });
    expect(line.length, closeTo(5, 1e-12));
    expect(line.bounds?.width, closeTo(3, 1e-12));
    expect(line.bounds?.height, closeTo(4, 1e-12));

    final polyline = cadEntityMetrics2D({
      'kind': 'polyline',
      'closed': true,
      'points': [
        {'x': 0, 'y': 0},
        {'x': 3, 'y': 0},
        {'x': 3, 'y': 4},
      ],
    });
    expect(polyline.vertexCount, 3);
    expect(polyline.closed, isTrue);
    expect(polyline.length, closeTo(12, 1e-12));
    expect(polyline.area, closeTo(6, 1e-12));
    expect(polyline.bounds?.width, closeTo(3, 1e-12));
    expect(polyline.bounds?.height, closeTo(4, 1e-12));

    final selfIntersecting = cadEntityMetrics2D({
      'kind': 'polyline',
      'closed': true,
      'points': [
        {'x': 0, 'y': 0},
        {'x': 4, 'y': 4},
        {'x': 0, 'y': 4},
        {'x': 4, 'y': 0},
      ],
    });
    expect(selfIntersecting.closed, isTrue);
    expect(selfIntersecting.area, isNull);
    expect(
      cadClosedEntityAreaMeasurement2D({
        'kind': 'polyline',
        'closed': true,
        'points': [
          {'x': 0, 'y': 0},
          {'x': 4, 'y': 4},
          {'x': 0, 'y': 4},
          {'x': 4, 'y': 0},
        ],
      }),
      isNull,
    );

    final closedArea = cadClosedEntityAreaMeasurement2D({
      'kind': 'polyline',
      'closed': true,
      'points': [
        {'x': 0, 'y': 0},
        {'x': 6, 'y': 0},
        {'x': 6, 'y': 4},
        {'x': 0, 'y': 4},
      ],
    });
    expect(closedArea?.area, closeTo(24, 1e-12));
    expect(closedArea?.perimeter, closeTo(20, 1e-12));
    expect(closedArea?.centroid, const Offset(3, 2));

    final circle = cadEntityMetrics2D({
      'kind': 'circle',
      'center': {'x': 2, 'y': 3},
      'radius': 2,
    });
    expect(circle.diameter, closeTo(4, 1e-12));
    expect(circle.circumference, closeTo(4 * 3.141592653589793, 1e-12));
    expect(circle.area, closeTo(4 * 3.141592653589793, 1e-12));
    expect(circle.bounds, const Rect.fromLTRB(0, 1, 4, 5));
    final circleArea = cadClosedEntityAreaMeasurement2D({
      'kind': 'circle',
      'center': {'x': 2, 'y': 3},
      'radius': 2,
    });
    expect(circleArea?.area, closeTo(4 * math.pi, 1e-12));
    expect(circleArea?.perimeter, closeTo(4 * math.pi, 1e-12));
    expect(circleArea?.centroid, const Offset(2, 3));
    expect(
      cadClosedEntityAreaMeasurement2D({
        'kind': 'circle',
        'center': {'x': 2, 'y': 3},
        'radius': 0,
      }),
      isNull,
    );

    final arc = cadEntityMetrics2D({
      'kind': 'arc',
      'center': {'x': 0, 'y': 0},
      'radius': 2,
      'start_angle': 0,
      'end_angle': 3.141592653589793 / 2,
    });
    expect(arc.sweepDegrees, closeTo(90, 1e-12));
    expect(arc.arcLength, closeTo(3.141592653589793, 1e-12));
    expect(arc.chordLength, closeTo(math.sqrt(8), 1e-12));
    expect(arc.sagitta, closeTo(2 * (1 - math.sqrt1_2), 1e-12));
    expect(arc.start?.dx, closeTo(2, 1e-12));
    expect(arc.start?.dy, closeTo(0, 1e-12));
    expect(arc.end?.dx, closeTo(0, 1e-12));
    expect(arc.end?.dy, closeTo(2, 1e-12));
    expect(arc.sectorArea, closeTo(math.pi, 1e-12));
    expect(arc.segmentArea, closeTo(math.pi - 2, 1e-12));
    expect(arc.bounds?.left, closeTo(0, 1e-12));
    expect(arc.bounds?.top, closeTo(0, 1e-12));
    expect(arc.bounds?.right, closeTo(2, 1e-12));
    expect(arc.bounds?.bottom, closeTo(2, 1e-12));

    final selectedCircle = cadRadialEntityMeasurement2D({
      'kind': 'circle',
      'center': {'x': 1000000000002, 'y': -999999999997},
      'radius': 2,
    });
    expect(selectedCircle?.center, const Offset(1000000000002, -999999999997));
    expect(selectedCircle?.diameter, closeTo(4, 1e-12));
    expect(selectedCircle?.circumference, closeTo(4 * math.pi, 1e-12));
    expect(selectedCircle?.area, closeTo(4 * math.pi, 1e-12));

    final crossingZeroArc = cadRadialEntityMeasurement2D({
      'kind': 'arc',
      'center': {'x': 8, 'y': 5},
      'radius': 10,
      'start_angle': 350 * math.pi / 180,
      'end_angle': 10 * math.pi / 180,
    });
    expect(crossingZeroArc?.sweepDegrees, closeTo(20, 1e-10));
    expect(crossingZeroArc?.arcLength, closeTo(10 * math.pi / 9, 1e-10));
    expect(
      crossingZeroArc?.chordLength,
      closeTo(20 * math.sin(10 * math.pi / 180), 1e-10),
    );
    expect(
      crossingZeroArc?.sagitta,
      closeTo(20 * math.pow(math.sin(5 * math.pi / 180), 2), 1e-12),
    );
    expect(crossingZeroArc?.chordStart, isNotNull);
    expect(crossingZeroArc?.chordEnd, isNotNull);
    expect(crossingZeroArc?.sectorArea, closeTo(50 * math.pi / 9, 1e-10));
    expect(
      crossingZeroArc?.segmentArea,
      closeTo(50 * (math.pi / 9 - math.sin(math.pi / 9)), 1e-10),
    );
    expect(
      cadArcSweepRadians(350 * math.pi / 180, 10 * math.pi / 180),
      closeTo(math.pi / 9, 1e-12),
    );
    expect(
      cadRadialEntityMeasurement2D({
        'kind': 'arc',
        'center': {'x': 0, 'y': 0},
        'radius': 2,
      }),
      isNull,
    );
    expect(
      cadRadialEntityMeasurement2D({'kind': 'circle', 'radius': 2}),
      isNull,
    );
    expect(
      cadRadialEntityMeasurement2D({
        'kind': 'circle',
        'center': {'x': 0, 'y': 0},
        'radius': 0,
      }),
      isNull,
    );
    final fullArc = cadRadialEntityMeasurement2D({
      'kind': 'arc',
      'center': {'x': 0, 'y': 0},
      'radius': 2,
      'start_angle': 1,
      'end_angle': 1,
    });
    expect(fullArc?.sweepDegrees, closeTo(360, 1e-12));
    expect(fullArc?.arcLength, closeTo(4 * math.pi, 1e-12));
    expect(fullArc?.chordLength, 0);
    expect(fullArc?.sagitta, isNull);
    expect(fullArc?.chordStart, isNull);
    expect(fullArc?.chordEnd, isNull);
    expect(fullArc?.sectorArea, closeTo(4 * math.pi, 1e-12));
    expect(fullArc?.segmentArea, closeTo(4 * math.pi, 1e-12));

    final shallowArc = cadRadialEntityMeasurement2D({
      'kind': 'arc',
      'center': {'x': 0, 'y': 0},
      'radius': 1,
      'start_angle': 0,
      'end_angle': 1e-6,
    });
    expect(shallowArc?.sectorArea, closeTo(5e-7, 1e-16));
    expect(shallowArc?.segmentArea, closeTo(1e-18 / 12, 1e-28));
    expect(shallowArc?.sagitta, closeTo(1.25e-13, 1e-22));
    expect(cadArcSagitta2D(2, 2 * math.pi), isNull);
    expect(cadArcSagitta2D(0, math.pi), isNull);
    final extremeSemicircle = cadArcSagitta2D(double.maxFinite, math.pi);
    expect(extremeSemicircle, isNotNull);
    expect(extremeSemicircle!.isFinite, isTrue);
    expect(extremeSemicircle / double.maxFinite, closeTo(1, 1e-15));
    expect(cadArcSagitta2D(double.maxFinite, 3 * math.pi / 2), isNull);
    expect(
      cadRadialEntityMeasurement2D({
        'kind': 'circle',
        'center': {'x': double.infinity, 'y': 0},
        'radius': 2,
      }),
      isNull,
    );
  });

  test('radial clearance distinguishes separation tangency and overlap', () {
    CadRadialMeasurement2D circle(Offset center, double radius) =>
        CadRadialMeasurement2D(
          kind: 'circle',
          center: center,
          radius: radius,
          diameter: radius * 2,
        );

    final separate = cadRadialClearanceMeasurement2D(
      circle(Offset.zero, 2),
      circle(const Offset(10, 0), 3),
    )!;
    expect(separate.centerDistance, 10);
    expect(separate.signedClearance, 5);
    expect(separate.directionDegrees, 0);
    expect(separate.relation, CadRadialClearanceRelation2D.separate);

    final tangent = cadRadialClearanceMeasurement2D(
      circle(Offset.zero, 2),
      circle(const Offset(3, 4), 3),
    )!;
    expect(tangent.centerDistance, 5);
    expect(tangent.signedClearance, 0);
    expect(tangent.directionDegrees, closeTo(53.1301023542, 1e-9));
    expect(tangent.relation, CadRadialClearanceRelation2D.tangent);

    final overlap = cadRadialClearanceMeasurement2D(
      circle(Offset.zero, 4),
      circle(const Offset(-3, 0), 2),
    )!;
    expect(overlap.centerDistance, 3);
    expect(overlap.signedClearance, -3);
    expect(overlap.directionDegrees, 180);
    expect(overlap.relation, CadRadialClearanceRelation2D.overlap);

    final concentric = cadRadialClearanceMeasurement2D(
      circle(const Offset(1e12, -1e12), 2),
      circle(const Offset(1e12, -1e12), 1),
    )!;
    expect(concentric.centerDistance, 0);
    expect(concentric.signedClearance, -3);
    expect(concentric.directionDegrees, isNull);

    final large = cadRadialClearanceMeasurement2D(
      circle(const Offset(1000000000000, -1000000000000), 1),
      circle(const Offset(1000000000003, -999999999996), 1),
    )!;
    expect(large.centerDistance, closeTo(5, 1e-4));
    expect(large.signedClearance, closeTo(3, 1e-4));
  });

  test('mesh properties calculate cached axis-aligned engineering extents', () {
    final mesh = <String, dynamic>{
      'positions': [
        {'x': -3, 'y': 2, 'z': 7},
        {'x': 5, 'y': -4, 'z': 9},
        {'x': 1, 'y': 8, 'z': -2},
      ],
    };
    final bounds = cadMeshBounds3D(mesh);
    expect(bounds?.sizeX, closeTo(8, 1e-12));
    expect(bounds?.sizeY, closeTo(12, 1e-12));
    expect(bounds?.sizeZ, closeTo(11, 1e-12));
    expect(identical(cadMeshBounds3D(mesh), bounds), isTrue);
    expect(cadMeshBounds3D(<String, dynamic>{'positions': <Object>[]}), isNull);
  });

  test('selected mesh face reports stable local engineering metrics', () {
    final mesh = <String, dynamic>{
      'positions': [
        {'x': 1000000000000, 'y': -1000000000000, 'z': 7},
        {'x': 1000000000003, 'y': -1000000000000, 'z': 7},
        {'x': 1000000000000, 'y': -999999999996, 'z': 7},
      ],
      'indices': [0, 1, 2, 0, 2, 1],
    };
    final face = cadMeshTriangleMetrics3D(mesh, 0)!;
    expect(face.firstEdgeLength, closeTo(3, 1e-12));
    expect(face.secondEdgeLength, closeTo(5, 1e-12));
    expect(face.thirdEdgeLength, closeTo(4, 1e-12));
    expect(face.perimeter, closeTo(12, 1e-12));
    expect(face.area, closeTo(6, 1e-12));
    expect(face.centroid.x, closeTo(1000000000001, 1e-4));
    expect(face.centroid.y, closeTo(-999999999998.6666, 1e-4));
    expect(face.centroid.z, 7);
    expect(face.normal?.x, closeTo(0, 1e-12));
    expect(face.normal?.y, closeTo(0, 1e-12));
    expect(face.normal?.z, closeTo(1, 1e-12));
    expect(face.slope?.inclinationDegrees, closeTo(0, 1e-12));
    expect(face.slope?.gradePercent, closeTo(0, 1e-12));
    expect(face.slope?.downslopeAzimuthDegrees, isNull);

    final reversed = cadMeshTriangleMetrics3D(mesh, 1)!;
    expect(reversed.area, closeTo(6, 1e-12));
    expect(reversed.normal?.z, closeTo(-1, 1e-12));
    expect(reversed.slope?.inclinationDegrees, closeTo(0, 1e-12));

    final degenerate = cadMeshTriangleMetrics3D({
      'positions': [
        {'x': 0, 'y': 0, 'z': 0},
        {'x': 1, 'y': 0, 'z': 0},
        {'x': 2, 'y': 0, 'z': 0},
      ],
      'indices': [0, 1, 2],
    }, 0)!;
    expect(degenerate.area, 0);
    expect(degenerate.perimeter, 4);
    expect(degenerate.normal, isNull);
    expect(degenerate.slope, isNull);

    expect(cadMeshTriangleMetrics3D(mesh, -1), isNull);
    expect(cadMeshTriangleMetrics3D(mesh, 2), isNull);
    expect(
      cadMeshTriangleMetrics3D({
        'positions': mesh['positions'],
        'indices': [0, 1, 9],
      }, 0),
      isNull,
    );
    expect(
      cadMeshTriangleMetrics3D({
        'positions': [
          {'x': 0, 'y': 0, 'z': 0},
          {'x': double.infinity, 'y': 0, 'z': 0},
          {'x': 0, 'y': 1, 'z': 0},
        ],
        'indices': [0, 1, 2],
      }, 0),
      isNull,
    );
  });

  test('face slope is winding independent and omits undefined directions', () {
    final fallingSouth = cadMeshFaceSlope3D(const CadPoint3(0, -1, 1))!;
    expect(fallingSouth.inclinationDegrees, closeTo(45, 1e-12));
    expect(fallingSouth.gradePercent, closeTo(100, 1e-12));
    expect(fallingSouth.downslopeAzimuthDegrees, closeTo(180, 1e-12));

    final reversed = cadMeshFaceSlope3D(const CadPoint3(0, 1, -1))!;
    expect(reversed.inclinationDegrees, closeTo(45, 1e-12));
    expect(reversed.gradePercent, closeTo(100, 1e-12));
    expect(reversed.downslopeAzimuthDegrees, closeTo(180, 1e-12));

    final northeast = cadMeshFaceSlope3D(const CadPoint3(1, 1, 1))!;
    expect(
      northeast.inclinationDegrees,
      closeTo(math.atan(math.sqrt(2)) * 180 / math.pi, 1e-12),
    );
    expect(northeast.gradePercent, closeTo(math.sqrt(2) * 100, 1e-12));
    expect(northeast.downslopeAzimuthDegrees, closeTo(45, 1e-12));

    final horizontal = cadMeshFaceSlope3D(const CadPoint3(0, 0, -2))!;
    expect(horizontal.inclinationDegrees, closeTo(0, 1e-12));
    expect(horizontal.gradePercent, closeTo(0, 1e-12));
    expect(horizontal.downslopeAzimuthDegrees, isNull);

    final vertical = cadMeshFaceSlope3D(const CadPoint3(8, 0, 0))!;
    expect(vertical.inclinationDegrees, closeTo(90, 1e-12));
    expect(vertical.gradePercent, isNull);
    expect(vertical.downslopeAzimuthDegrees, isNull);

    final huge = cadMeshFaceSlope3D(
      const CadPoint3(double.maxFinite, double.maxFinite, double.maxFinite),
    )!;
    expect(
      huge.inclinationDegrees,
      closeTo(northeast.inclinationDegrees, 1e-12),
    );
    expect(huge.downslopeAzimuthDegrees, closeTo(45, 1e-12));

    expect(cadMeshFaceSlope3D(const CadPoint3(0, 0, 0)), isNull);
    expect(cadMeshFaceSlope3D(const CadPoint3(double.infinity, 0, 1)), isNull);

    final almostCollinear = cadMeshTriangleMetrics3D({
      'positions': [
        {'x': 0, 'y': 0, 'z': 0},
        {'x': 1, 'y': 0, 'z': 0},
        {'x': 2, 'y': 1e-14, 'z': 0},
      ],
      'indices': [0, 1, 2],
    }, 0)!;
    expect(almostCollinear.area, greaterThan(0));
    expect(almostCollinear.normal, isNull);
    expect(almostCollinear.slope, isNull);
  });

  test('face angle reports the smaller winding-independent plane angle', () {
    const up = CadPoint3(0, 0, 1);
    expect(
      cadMeshFaceAngleDegrees3D(up, const CadPoint3(0, 0, 4)),
      closeTo(0, 1e-12),
    );
    expect(
      cadMeshFaceAngleDegrees3D(up, const CadPoint3(0, 0, -4)),
      closeTo(0, 1e-12),
    );
    expect(
      cadMeshFaceAngleDegrees3D(up, const CadPoint3(1, 0, 0)),
      closeTo(90, 1e-12),
    );
    expect(
      cadMeshFaceAngleDegrees3D(up, const CadPoint3(0, 1, 1)),
      closeTo(45, 1e-12),
    );
    expect(
      cadMeshFaceAngleDegrees3D(up, const CadPoint3(0, -1, -1)),
      closeTo(45, 1e-12),
    );
    expect(
      cadMeshFaceAngleDegrees3D(
        const CadPoint3(double.maxFinite, 0, double.maxFinite),
        const CadPoint3(0, double.maxFinite, double.maxFinite),
      ),
      closeTo(60, 1e-12),
    );
    expect(cadMeshFaceAngleDegrees3D(up, const CadPoint3(0, 0, 0)), isNull);
    expect(
      cadMeshFaceAngleDegrees3D(up, const CadPoint3(double.nan, 0, 1)),
      isNull,
    );
  });

  test('parallel face spacing uses plane distance instead of tap distance', () {
    final parallel = cadMeshFaceRelation3D(
      const CadPoint3(1000000000000, -1000000000000, 7),
      const CadPoint3(0, 0, 1),
      const CadPoint3(1000000000123, -999999999544, 10),
      const CadPoint3(0, 0, -5),
    )!;
    expect(parallel.angleDegrees, closeTo(0, 1e-12));
    expect(parallel.parallelSeparation, closeTo(3, 1e-12));

    final coplanar = cadMeshFaceRelation3D(
      const CadPoint3(0, 0, 4),
      const CadPoint3(0, 0, 2),
      const CadPoint3(80, -20, 4),
      const CadPoint3(0, 0, 9),
    )!;
    expect(coplanar.parallelSeparation, closeTo(0, 1e-12));

    final perpendicular = cadMeshFaceRelation3D(
      const CadPoint3(0, 0, 0),
      const CadPoint3(0, 0, 1),
      const CadPoint3(30, 0, 0),
      const CadPoint3(1, 0, 0),
    )!;
    expect(perpendicular.angleDegrees, closeTo(90, 1e-12));
    expect(perpendicular.parallelSeparation, isNull);

    final visiblySkew = cadMeshFaceRelation3D(
      const CadPoint3(0, 0, 0),
      const CadPoint3(0, 0, 1),
      const CadPoint3(0, 0, 5),
      const CadPoint3(1e-11, 0, 1),
    )!;
    expect(visiblySkew.parallelSeparation, isNull);

    expect(
      cadMeshFaceRelation3D(
        const CadPoint3(double.infinity, 0, 0),
        const CadPoint3(0, 0, 1),
        const CadPoint3(0, 0, 1),
        const CadPoint3(0, 0, 1),
      ),
      isNull,
    );
  });

  test('entity length takeoff validates supported source geometry', () {
    expect(
      cadMeasurableEntityLength2D({
        'kind': 'line',
        'start': {'x': 0, 'y': 0},
        'end': {'x': 30, 'y': 40},
      }),
      50,
    );
    expect(
      cadMeasurableEntityLength2D({
        'kind': 'polyline',
        'closed': false,
        'points': [
          {'x': 0, 'y': 0},
          {'x': 0, 'y': 30},
          {'x': 40, 'y': 30},
        ],
      }),
      70,
    );
    expect(
      cadMeasurableEntityLength2D({
        'kind': 'circle',
        'center': {'x': 0, 'y': 0},
        'radius': 10,
      }),
      closeTo(20 * math.pi, 1e-12),
    );
    expect(
      cadMeasurableEntityLength2D({
        'kind': 'arc',
        'center': {'x': 0, 'y': 0},
        'radius': 10,
        'start_angle': 350 * math.pi / 180,
        'end_angle': 10 * math.pi / 180,
      }),
      closeTo(10 * math.pi / 9, 1e-12),
    );
    expect(
      cadMeasurableEntityLength2D({
        'kind': 'line',
        'start': {'x': 0, 'y': 0},
        'end': {'x': 0, 'y': 0},
      }),
      isNull,
    );
    expect(cadMeasurableEntityLength2D({'kind': 'text'}), isNull);
  });

  test(
    'layer summaries update visibility without dropping retained geometry',
    () {
      CadDocumentModel documentWith(bool visible, List<Object> entities) =>
          CadDocumentModel.fromJson({
            'metadata': {'format': 'dxf', 'display_name': 'layers.dxf'},
            'scene': {
              'scene_kind': 'two_d',
              'scene': {
                'layers': [
                  {
                    'id': 1,
                    'name': 'Walls',
                    'visible': visible,
                    'color_argb': 0xffffffff,
                  },
                ],
                'entities': entities,
                'bounds': {
                  'min': {'x': 0, 'y': 0},
                  'max': {'x': 10, 'y': 10},
                },
              },
            },
            'diagnostics': <Object>[],
          });

      final retained = documentWith(true, [
        {
          'id': 7,
          'layer_id': 1,
          'color_argb': 0xffffffff,
          'stroke_width': 0,
          'filled': false,
          'geometry': {
            'kind': 'line',
            'start': {'x': 0, 'y': 0},
            'end': {'x': 10, 'y': 10},
          },
        },
      ]);
      final summary = documentWith(false, const []);
      final merged = retained.withLayerStateFrom(summary);

      expect(merged.layers.single.visible, isFalse);
      expect(merged.entities.single['id'], 7);
    },
  );

  test('3D grade uses signed rise over horizontal projection', () {
    final uphill = cadGrade3D(
      const CadPoint3(0, 0, 0),
      const CadPoint3(3, 4, 1),
    );
    expect(uphill.horizontalDistance, closeTo(5, 1e-12));
    expect(uphill.deltaZ, closeTo(1, 1e-12));
    expect(uphill.percent, closeTo(20, 1e-12));
    expect(uphill.ratio, closeTo(5, 1e-12));
    expect(uphill.slopeAngleDegrees, closeTo(11.309932474, 1e-9));
    expect(
      uphill.horizontalDirection?.azimuthDegrees,
      closeTo(36.869897646, 1e-9),
    );
    expect(uphill.horizontalDirection?.bearingFrom, CadCardinalDirection.north);
    expect(uphill.horizontalDirection?.bearingTo, CadCardinalDirection.east);

    final downhill = cadGrade3D(
      const CadPoint3(3, 4, 1),
      const CadPoint3(0, 0, 0),
    );
    expect(downhill.percent, closeTo(-20, 1e-12));
    expect(downhill.ratio, closeTo(5, 1e-12));
    expect(downhill.slopeAngleDegrees, closeTo(-11.309932474, 1e-9));
    expect(
      downhill.horizontalDirection?.azimuthDegrees,
      closeTo(216.869897646, 1e-9),
    );
    expect(
      downhill.horizontalDirection?.bearingFrom,
      CadCardinalDirection.south,
    );
    expect(downhill.horizontalDirection?.bearingTo, CadCardinalDirection.west);

    final vertical = cadGrade3D(
      const CadPoint3(0, 0, 0),
      const CadPoint3(0, 0, 5),
    );
    expect(vertical.horizontalDistance, 0);
    expect(vertical.percent, isNull);
    expect(vertical.ratio, 0);
    expect(vertical.slopeAngleDegrees, 90);
    expect(vertical.horizontalDirection, isNull);

    final level = cadGrade3D(
      const CadPoint3(0, 0, 5),
      const CadPoint3(0, 8, 5),
    );
    expect(level.percent, 0);
    expect(level.ratio, double.infinity);
    expect(level.slopeAngleDegrees, 0);
    expect(level.horizontalDirection?.cardinal, CadCardinalDirection.north);

    final coincident = cadGrade3D(
      const CadPoint3(1, 2, 3),
      const CadPoint3(1, 2, 3),
    );
    expect(coincident.percent, isNull);
    expect(coincident.ratio, isNull);
    expect(coincident.slopeAngleDegrees, isNull);
    expect(coincident.horizontalDirection, isNull);

    final large = cadGrade3D(
      const CadPoint3(1e200, -1e200, 0),
      const CadPoint3(1.0000000003e200, -0.9999999996e200, 1e189),
    );
    expect(large.horizontalDistance.isFinite, isTrue);
    // The coordinate subtraction itself is rounded at this magnitude; the
    // result must remain finite and preserve the expected engineering scale.
    expect(large.horizontalDistance, closeTo(5e190, 1e184));
    expect(large.percent, closeTo(2, 1e-6));
    expect(large.ratio, closeTo(50, 1e-5));
  });

  test('2D grade preserves pick direction and handles axis limits', () {
    final uphill = cadGrade2D(Offset.zero, const Offset(4, 2));
    expect(uphill.run, 4);
    expect(uphill.rise, 2);
    expect(uphill.percent, closeTo(50, 1e-12));
    expect(uphill.ratio, closeTo(2, 1e-12));

    final downhill = cadGrade2D(const Offset(4, 2), Offset.zero);
    expect(downhill.percent, closeTo(-50, 1e-12));
    expect(downhill.ratio, closeTo(2, 1e-12));

    final level = cadGrade2D(
      const Offset(1000000000000, -2000000000000),
      const Offset(1000000000005, -2000000000000),
    );
    expect(level.percent, 0);
    expect(level.ratio, double.infinity);

    final verticalUp = cadGrade2D(Offset.zero, const Offset(0, 5));
    expect(verticalUp.percent, double.infinity);
    expect(verticalUp.ratio, 0);
    final verticalDown = cadGrade2D(const Offset(0, 5), Offset.zero);
    expect(verticalDown.percent, double.negativeInfinity);
    expect(verticalDown.ratio, 0);

    final coincident = cadGrade2D(const Offset(2, 3), const Offset(2, 3));
    expect(coincident.percent, isNull);
    expect(coincident.ratio, isNull);

    for (final scale in [1e-300, 1e-18, 1.0, 1e18, 1e200]) {
      final scaled = cadGrade2D(Offset.zero, Offset(4 * scale, 2 * scale));
      expect(scaled.percent, closeTo(50, 1e-12));
      expect(scaled.ratio, closeTo(2, 1e-12));
    }
  });

  test('survey direction covers drawing axes and all quadrants', () {
    CadSurveyDirection2D direction(Offset end) =>
        cadSurveyDirection2D(Offset.zero, end)!;

    final north = direction(const Offset(0, 1));
    expect(north.azimuthDegrees, 0);
    expect(north.cardinal, CadCardinalDirection.north);
    final east = direction(const Offset(1, 0));
    expect(east.azimuthDegrees, 90);
    expect(east.cardinal, CadCardinalDirection.east);
    final south = direction(const Offset(0, -1));
    expect(south.azimuthDegrees, 180);
    expect(south.cardinal, CadCardinalDirection.south);
    final west = direction(const Offset(-1, 0));
    expect(west.azimuthDegrees, 270);
    expect(west.cardinal, CadCardinalDirection.west);

    final northEast = direction(const Offset(1, 1));
    expect(northEast.azimuthDegrees, closeTo(45, 1e-12));
    expect(northEast.bearingFrom, CadCardinalDirection.north);
    expect(northEast.bearingDegrees, closeTo(45, 1e-12));
    expect(northEast.bearingTo, CadCardinalDirection.east);
    final southEast = direction(const Offset(1, -1));
    expect(southEast.azimuthDegrees, closeTo(135, 1e-12));
    expect(southEast.bearingFrom, CadCardinalDirection.south);
    expect(southEast.bearingDegrees, closeTo(45, 1e-12));
    expect(southEast.bearingTo, CadCardinalDirection.east);
    final southWest = direction(const Offset(-1, -1));
    expect(southWest.azimuthDegrees, closeTo(225, 1e-12));
    expect(southWest.bearingFrom, CadCardinalDirection.south);
    expect(southWest.bearingDegrees, closeTo(45, 1e-12));
    expect(southWest.bearingTo, CadCardinalDirection.west);
    final northWest = direction(const Offset(-1, 1));
    expect(northWest.azimuthDegrees, closeTo(315, 1e-12));
    expect(northWest.bearingFrom, CadCardinalDirection.north);
    expect(northWest.bearingDegrees, closeTo(45, 1e-12));
    expect(northWest.bearingTo, CadCardinalDirection.west);

    final largeCoordinate = cadSurveyDirection2D(
      const Offset(1000000000000, -2000000000000),
      const Offset(1000000000003, -1999999999996),
    )!;
    expect(largeCoordinate.azimuthDegrees, closeTo(36.8698976458, 1e-9));
    for (final scale in [1e-300, 1e-18, 1.0, 1e18, 1e200]) {
      final scaled = cadSurveyDirection2D(
        Offset.zero,
        Offset(3 * scale, 4 * scale),
      )!;
      expect(scaled.azimuthDegrees, closeTo(36.8698976458, 1e-9));
    }
    expect(
      cadSurveyDirection2D(const Offset(2, 3), const Offset(2, 3)),
      isNull,
    );
  });

  test('three surface points measure a stable spatial angle', () {
    expect(
      angleDegrees3D(
        const CadPoint3(0, 0, 0),
        const CadPoint3(1, 0, 0),
        const CadPoint3(0, 0, 1),
      ),
      closeTo(90, 1e-12),
    );
    expect(
      angleDegrees3D(
        const CadPoint3(1e200, 1e200, 1e200),
        const CadPoint3(2e200, 1e200, 1e200),
        const CadPoint3(1e200, 2e200, 1e200),
      ),
      closeTo(90, 1e-12),
    );
    expect(
      angleDegrees3D(
        const CadPoint3(1, 1, 1),
        const CadPoint3(1, 1, 1),
        const CadPoint3(2, 1, 1),
      ),
      isNull,
    );
  });

  test('three snapped points measure the smaller engineering angle', () {
    expect(
      angleDegrees2D(Offset.zero, const Offset(10, 0), const Offset(0, 10)),
      closeTo(90, 1e-12),
    );
    expect(
      angleDegrees2D(Offset.zero, const Offset(10, 0), const Offset(10, 10)),
      closeTo(45, 1e-12),
    );
    expect(angleDegrees2D(Offset.zero, Offset.zero, const Offset(1, 0)), 0);
  });

  test('text remains visible when its insertion point is off-screen', () {
    const transform = CadViewTransform(
      worldCenter: Offset.zero,
      screenCenter: Offset(100, 100),
      scale: 1,
    );
    final bounds = cadTextScreenBounds({
      'kind': 'text',
      'origin': {'x': -105, 'y': 0},
      'value': 'LONG LABEL',
      'height': 20,
      'rotation': 0,
      'width_factor': 1,
      'horizontal_alignment': 'left',
      'vertical_alignment': 'baseline',
    }, transform);

    expect(const Rect.fromLTWH(0, 0, 200, 200).overlaps(bounds), isTrue);
    expect(
      const Rect.fromLTWH(0, 0, 200, 200).contains(const Offset(-5, 100)),
      isFalse,
    );
  });

  test('multiline and mirrored text remains in its actual screen envelope', () {
    const transform = CadViewTransform(
      worldCenter: Offset.zero,
      screenCenter: Offset(100, 100),
      scale: 1,
    );
    final geometry = <String, dynamic>{
      'kind': 'text',
      'origin': {'x': 105, 'y': 0},
      'value': '中文\nالعربية\n⌀ 120',
      'height': 20,
      'rotation': 0,
      'width_factor': 1,
      'horizontal_alignment': 'left',
      'vertical_alignment': 'top',
      'mirrored_x': true,
    };
    final bounds = cadTextScreenBounds(geometry, transform);
    expect(const Rect.fromLTWH(0, 0, 200, 200).overlaps(bounds), isTrue);
    expect(bounds.height, greaterThan(60));
    expect(bounds.left, lessThan(200));
    final mirroredY = cadTextScreenBounds({
      ...geometry,
      'mirrored_y': true,
    }, transform);
    expect(mirroredY.top, lessThan(bounds.top));
    final rotated = cadTextScreenBounds({
      ...geometry,
      'rotation': math.pi / 2,
    }, transform);
    expect(rotated.width, closeTo(bounds.height, 1e-8));
    expect(rotated.height, closeTo(bounds.width, 1e-8));
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
