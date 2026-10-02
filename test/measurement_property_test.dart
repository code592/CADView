import 'dart:math' as math;

import 'package:cad_view/features/viewer/cad_entity_metrics.dart';
import 'package:cad_view/features/viewer/cad_units.dart';
import 'package:flutter_test/flutter_test.dart';

// Randomized cross-checks of the measurement tools against independently
// derived formulas (triangle decomposition, Heron, parallel-axis theorem,
// reconstruction identities). A fixed seed keeps failures reproducible.
const _cases = 400;

void main() {
  double relative(double actual, double expected) =>
      (actual - expected).abs() / math.max(1.0, expected.abs());

  Offset randomPoint(math.Random random, double origin, double spread) =>
      Offset(
        origin + (random.nextDouble() - 0.5) * spread,
        origin + (random.nextDouble() - 0.5) * spread,
      );

  test('triangle results satisfy Heron and circle identities', () {
    final random = math.Random(1);
    var checked = 0;
    for (var index = 0; index < _cases; index++) {
      final origin = random.nextBool() ? 0.0 : 5e5;
      final a = randomPoint(random, origin, 200);
      final b = randomPoint(random, origin, 200);
      final c = randomPoint(random, origin, 200);
      final result = cadTriangleMeasurement2D(a, b, c);
      final ab = (b - a).distance;
      final ac = (c - a).distance;
      final bc = (c - b).distance;
      final s = (ab + ac + bc) / 2;
      final heron = math.sqrt(math.max(0, s * (s - ab) * (s - ac) * (s - bc)));
      if (heron < 1) continue; // Skip needle triangles for a stable oracle.
      checked++;
      expect(result, isNotNull);
      expect(relative(result!.area, heron), lessThan(1e-6));
      expect(relative(result.perimeter, ab + ac + bc), lessThan(1e-12));
      final angleSum =
          result.angleDegrees +
          result.firstRayPointAngleDegrees! +
          result.secondRayPointAngleDegrees!;
      expect(angleSum, closeTo(180, 1e-8));
      final cosineA = (ab * ab + ac * ac - bc * bc) / (2 * ab * ac);
      expect(
        result.angleDegrees,
        closeTo(math.acos(cosineA.clamp(-1, 1)) * 180 / math.pi, 1e-6),
      );
      expect(
        relative(result.circumradius!, ab * ac * bc / (4 * heron)),
        lessThan(1e-6),
      );
      expect(relative(result.inradius!, heron / s), lessThan(1e-6));
      expect(
        relative(result.altitudeFromVertex!, 2 * heron / bc),
        lessThan(1e-6),
      );
    }
    expect(checked, greaterThan(_cases ~/ 2));
  });

  test('three-point circle and arc pass through their picks', () {
    final random = math.Random(2);
    for (var index = 0; index < _cases; index++) {
      final center = randomPoint(random, random.nextBool() ? 0 : 1e5, 1000);
      final radius = 0.5 + random.nextDouble() * 200;
      final start = random.nextDouble() * 2 * math.pi;
      final sweep = 0.2 + random.nextDouble() * (2 * math.pi - 0.4);
      final direction = random.nextBool() ? 1.0 : -1.0;
      Offset at(double fraction) {
        final angle = start + direction * sweep * fraction;
        return center + Offset(math.cos(angle), math.sin(angle)) * radius;
      }

      final first = at(0);
      final middle = at(0.1 + random.nextDouble() * 0.8);
      final third = at(1);
      final circle = cadThreePointCircleMeasurement2D(first, middle, third);
      expect(circle, isNotNull);
      expect((circle!.center - center).distance, lessThan(radius * 1e-7));
      expect(relative(circle.radius, radius), lessThan(1e-8));

      final arc = cadThreePointArcMeasurement2D(first, middle, third)!;
      expect(arc.counterClockwise, direction > 0);
      expect(arc.sweepRadians, closeTo(sweep, 1e-7));
      expect(relative(arc.arcLength, radius * sweep), lessThan(1e-7));
      expect(
        relative(arc.chordLength, (third - first).distance),
        lessThan(1e-9),
      );
      // Sagitta: chord midpoint to the arc midpoint.
      final chordMidpoint = (first + third) / 2;
      expect(
        arc.sagitta,
        closeTo((at(0.5) - chordMidpoint).distance, radius * 1e-7),
      );
      final segment = radius * radius / 2 * (sweep - math.sin(sweep));
      expect(relative(arc.segmentArea, segment), lessThan(1e-6));
      expect(
        relative(arc.sectorArea, radius * radius * sweep / 2),
        lessThan(1e-7),
      );
    }
  });

  test('two-distance location returns points at both distances', () {
    final random = math.Random(3);
    var found = 0;
    for (var index = 0; index < _cases; index++) {
      final a = randomPoint(random, 2e5, 500);
      final b = randomPoint(random, 2e5, 500);
      final target = randomPoint(random, 2e5, 500);
      final firstDistance = (target - a).distance;
      final secondDistance = (target - b).distance;
      final result = cadTwoDistanceLocation2D(
        a,
        b,
        firstDistance,
        secondDistance,
      );
      if ((b - a).distance < 1) continue;
      expect(result, isNotNull);
      found++;
      final scale = math.max(firstDistance, secondDistance);
      for (final point in result!.solutions) {
        expect((point - a).distance, closeTo(firstDistance, scale * 1e-8));
        expect((point - b).distance, closeTo(secondDistance, scale * 1e-8));
      }
      expect(
        result.solutions.any(
          (point) => (point - target).distance < scale * 1e-6,
        ),
        isTrue,
      );
      if (result.solutions.length == 2) {
        // First solution is on the left of A→B.
        final baseline = b - a;
        final left = result.solutions[0] - a;
        expect(baseline.dx * left.dy - baseline.dy * left.dx, greaterThan(0));
      }
    }
    expect(found, greaterThan(_cases ~/ 2));
  });

  test('polygon section properties match a triangle decomposition', () {
    final random = math.Random(4);
    for (var index = 0; index < _cases ~/ 4; index++) {
      final center = randomPoint(random, random.nextBool() ? 0 : 3e5, 100);
      final count = 3 + random.nextInt(10);
      final angles = List.generate(
        count,
        (_) => random.nextDouble() * 2 * math.pi,
      )..sort();
      // Distinct angles produce a convex (hence simple) polygon.
      if (List.generate(
        count,
        (i) => (angles[(i + 1) % count] - angles[i]) % (2 * math.pi),
      ).any((gap) => gap < 0.05)) {
        continue;
      }
      final radius = 1 + random.nextDouble() * 50;
      var points = [
        for (final angle in angles)
          center + Offset(math.cos(angle), math.sin(angle)) * radius,
      ];
      if (random.nextBool()) points = points.reversed.toList();

      // Independent oracle: fan of triangles about a local origin.
      final origin = points.first;
      var area = 0.0, sx = 0.0, sy = 0.0, ixx = 0.0, iyy = 0.0, ixy = 0.0;
      for (var i = 1; i + 1 < points.length; i++) {
        final p = [Offset.zero, points[i] - origin, points[i + 1] - origin];
        final t = (p[1].dx * p[2].dy - p[2].dx * p[1].dy) / 2;
        area += t;
        sx += t * (p[0].dx + p[1].dx + p[2].dx) / 3;
        sy += t * (p[0].dy + p[1].dy + p[2].dy) / 3;
        double sumSquares(double Function(Offset) f) =>
            f(p[0]) * f(p[0]) +
            f(p[1]) * f(p[1]) +
            f(p[2]) * f(p[2]) +
            f(p[0]) * f(p[1]) +
            f(p[1]) * f(p[2]) +
            f(p[0]) * f(p[2]);
        iyy += t / 6 * sumSquares((v) => v.dx);
        ixx += t / 6 * sumSquares((v) => v.dy);
        ixy +=
            t /
            12 *
            (2 * (p[0].dx * p[0].dy + p[1].dx * p[1].dy + p[2].dx * p[2].dy) +
                p[0].dx * p[1].dy +
                p[1].dx * p[0].dy +
                p[0].dx * p[2].dy +
                p[2].dx * p[0].dy +
                p[1].dx * p[2].dy +
                p[2].dx * p[1].dy);
      }
      final sign = area.sign;
      area = area.abs();
      final cx = sx * sign / area, cy = sy * sign / area;
      // Parallel-axis theorem to the centroid.
      final ix = ixx * sign - area * cy * cy;
      final iy = iyy * sign - area * cx * cx;
      final pxy = ixy * sign - area * cx * cy;

      final result = cadPolygonSectionProperties2D(points)!;
      final momentScale = math.max(ix, iy);
      expect(relative(result.area, area), lessThan(1e-9));
      expect(
        (result.centroid - (origin + Offset(cx, cy))).distance,
        lessThan(radius * 1e-9),
      );
      expect(result.centroidalMomentX, closeTo(ix, momentScale * 1e-7));
      expect(result.centroidalMomentY, closeTo(iy, momentScale * 1e-7));
      expect(result.centroidalProductXY, closeTo(pxy, momentScale * 1e-7));
      final mean = (ix + iy) / 2;
      final spread = math.sqrt(math.pow((ix - iy) / 2, 2) + pxy * pxy);
      expect(
        result.principalMomentMaximum,
        closeTo(mean + spread, momentScale * 1e-7),
      );
      expect(
        result.principalMomentMinimum,
        closeTo(mean - spread, momentScale * 1e-7),
      );
      expect(
        cadPolygonCentroid2D(points)!,
        isA<Offset>().having(
          (centroid) => (centroid - result.centroid).distance,
          'distance from section centroid',
          lessThan(radius * 1e-9),
        ),
      );
    }
  });

  test('polar stakeout and survey direction are inverses', () {
    final random = math.Random(5);
    for (var index = 0; index < _cases; index++) {
      final origin = randomPoint(random, 1e5, 1e4);
      final distance = 0.01 + random.nextDouble() * 1000;
      final azimuth = random.nextDouble() * 360;
      final stakeout = cadPolarStakeoutMeasurement2D(
        origin,
        distance,
        azimuth,
      )!;
      expect(
        relative((stakeout.target - origin).distance, distance),
        lessThan(1e-6),
      );
      final direction = cadSurveyDirection2D(origin, stakeout.target)!;
      final error = ((direction.azimuthDegrees - azimuth + 540) % 360) - 180;
      expect(error.abs(), lessThan(1e-6));
      final bearing = direction.bearingDegrees;
      if (bearing != null) {
        expect(bearing, inInclusiveRange(0, 90));
        final quadrant = switch ((direction.bearingFrom, direction.bearingTo)) {
          (CadCardinalDirection.north, CadCardinalDirection.east) => bearing,
          (CadCardinalDirection.south, CadCardinalDirection.east) =>
            180 - bearing,
          (CadCardinalDirection.south, CadCardinalDirection.west) =>
            180 + bearing,
          _ => 360 - bearing,
        };
        expect(quadrant, closeTo(direction.azimuthDegrees, 1e-9));
      }
    }
  });

  test('point-line projection reconstructs the picked point', () {
    final random = math.Random(6);
    for (var index = 0; index < _cases; index++) {
      final first = randomPoint(random, 0, 1000);
      final second = randomPoint(random, 0, 1000);
      final point = randomPoint(random, 0, 1000);
      final result = cadPointLineMeasurement2D(first, second, point)!;
      final unit = (second - first) / (second - first).distance;
      final left = Offset(-unit.dy, unit.dx);
      final rebuilt =
          first + unit * result.station + left * result.signedOffset;
      expect((rebuilt - point).distance, lessThan(1e-9));
      expect(
        (result.foot - (first + unit * result.station)).distance,
        lessThan(1e-9),
      );
    }
  });

  test('segment clearance matches a brute-force minimum', () {
    final random = math.Random(7);
    CadLineSegment2D segment(Offset start, Offset end) => CadLineSegment2D(
      start: start,
      end: end,
      segmentIndex: 0,
      length: (end - start).distance,
      directionDegrees:
          math.atan2(end.dy - start.dy, end.dx - start.dx) * 180 / math.pi,
    );
    double pointToSegment(Offset p, Offset a, Offset b) {
      final d = b - a;
      final t = (((p - a).dx * d.dx + (p - a).dy * d.dy) / d.distanceSquared)
          .clamp(0.0, 1.0);
      return (p - (a + d * t)).distance;
    }

    bool crosses(Offset a, Offset b, Offset c, Offset d) {
      double orient(Offset p, Offset q, Offset r) =>
          (q.dx - p.dx) * (r.dy - p.dy) - (q.dy - p.dy) * (r.dx - p.dx);
      return orient(a, b, c) * orient(a, b, d) < 0 &&
          orient(c, d, a) * orient(c, d, b) < 0;
    }

    for (var index = 0; index < _cases; index++) {
      final a = randomPoint(random, 0, 100), b = randomPoint(random, 0, 100);
      final c = randomPoint(random, 0, 100), d = randomPoint(random, 0, 100);
      final result = cadSegmentClearanceMeasurement2D(
        segment(a, b),
        segment(c, d),
      )!;
      final expected = crosses(a, b, c, d)
          ? 0.0
          : [
              pointToSegment(a, c, d),
              pointToSegment(b, c, d),
              pointToSegment(c, a, b),
              pointToSegment(d, a, b),
            ].reduce(math.min);
      expect(result.clearance, closeTo(expected, 1e-9));
      expect(
        (result.firstClosestPoint - result.secondClosestPoint).distance,
        closeTo(result.clearance, 1e-9),
      );
    }
  });

  test('Bowditch adjustment closes exactly and distributes by length', () {
    final random = math.Random(8);
    for (var index = 0; index < _cases ~/ 4; index++) {
      final points = [
        for (var i = 0; i < 2 + random.nextInt(8); i++)
          randomPoint(random, 1e4, 500),
      ];
      final traverse = cadOpenTraverse2D(points)!;
      final known =
          points.last + Offset(random.nextDouble(), random.nextDouble());
      final adjustment = cadBowditchAdjustment2D(traverse, known)!;
      expect(adjustment.points.last.adjusted, known);
      expect(adjustment.points.first.adjusted, points.first);
      final correction = known - points.last;
      for (final point in adjustment.points) {
        final fraction = point.cumulativeLength / traverse.totalLength;
        expect(
          (point.correction - correction * fraction).distance,
          lessThan(1e-9),
        );
      }
    }
  });

  test('simple circular curve tangent geometry is consistent', () {
    final random = math.Random(9);
    for (var index = 0; index < _cases; index++) {
      final center = randomPoint(random, 2e4, 1000);
      final radius = 1 + random.nextDouble() * 500;
      final startAngle = random.nextDouble() * 2 * math.pi;
      final sweep = 0.05 + random.nextDouble() * (math.pi - 0.1);
      final ccw = random.nextBool();
      final endAngle = startAngle + (ccw ? sweep : -sweep);
      final start =
          center + Offset(math.cos(startAngle), math.sin(startAngle)) * radius;
      final end =
          center + Offset(math.cos(endAngle), math.sin(endAngle)) * radius;
      final curve = cadSimpleCircularCurve2D(
        center: center,
        start: start,
        end: end,
        radius: radius,
        sweepRadians: sweep,
        counterClockwise: ccw,
      )!;
      final pi = curve.tangentIntersection;
      final tolerance = radius * 1e-7;
      expect((pi - start).distance, closeTo(curve.tangentLength, tolerance));
      expect((pi - end).distance, closeTo(curve.tangentLength, tolerance));
      expect(
        (pi - center).distance - radius,
        closeTo(curve.externalDistance, tolerance),
      );
      final chordMidpoint = (start + end) / 2;
      expect(
        radius - (chordMidpoint - center).distance,
        closeTo(curve.middleOrdinate, tolerance),
      );
    }
  });

  test('length and area unit conversions round trip', () {
    final random = math.Random(10);
    for (var index = 0; index < _cases; index++) {
      final source =
          cadEngineeringUnits[random.nextInt(cadEngineeringUnits.length)];
      final display =
          cadEngineeringUnits[random.nextInt(cadEngineeringUnits.length)];
      final value = (random.nextDouble() - 0.5) * 1e4;
      final shown = cadDrawingLengthToDisplayUnits(
        value,
        source: source,
        display: display,
      )!;
      expect(
        relative(shown, value * source.metersPerUnit / display.metersPerUnit),
        lessThan(1e-12),
      );
      final back = cadDisplayLengthToDrawingUnits(
        shown,
        source: source,
        display: display,
      )!;
      expect(relative(back, value), lessThan(1e-12));
      final scale = source.metersPerUnit / display.metersPerUnit;
      final area = value.abs();
      expect(
        relative(
          cadDisplayAreaToDrawingUnits(
            area * scale * scale,
            source: source,
            display: display,
          )!,
          area,
        ),
        lessThan(1e-12),
      );
    }
  });
}
