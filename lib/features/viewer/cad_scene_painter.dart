import 'dart:math' as math;
import 'dart:collection';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/cad_engine.dart';
import '../../core/cad_fonts.dart';
import '../../core/cad_font_metrics.dart';
import 'cad_document_model.dart';
import 'cad_entity_metrics.dart';

const _cadFontFallback = <String>[
  ...cadFontFallback,
  'Noto Sans CJK SC',
  'Noto Sans CJK TC',
  'Noto Sans CJK JP',
  'Noto Sans CJK KR',
  'Noto Sans SC',
  'Noto Sans JP',
  'Noto Sans KR',
  'Noto Sans',
  'PingFang SC',
  'PingFang TC',
  'Hiragino Sans',
  'Hiragino Sans GB',
  'Yu Gothic',
  'Apple SD Gothic Neo',
  'Roboto',
  'Arial Unicode MS',
  'sans-serif',
];

// Shape once in camera-independent em units. Canvas transforms preserve CAD
// size at any zoom, while wrapping and native index envelopes stay identical.
// A larger fixed shaping size reduces font hinting quantization when the
// paragraph is transformed back to CAD cap-height, without tying wrap to zoom.
const _cadTextShapeSize = 128.0;

/// Background-aware monochrome display color. Preserve the source ARGB in the
/// scene/properties, but don't hide black or near-black neutral CAD ink against
/// this viewer's dark canvas. Chromatic colors and opacity remain unchanged.
Color cadCanvasColor(int argb) {
  final red = (argb >> 16) & 0xff;
  final green = (argb >> 8) & 0xff;
  final blue = argb & 0xff;
  final maximum = math.max(red, math.max(green, blue));
  final minimum = math.min(red, math.min(green, blue));
  if (maximum <= 48 && maximum - minimum <= 8) {
    final tone = 235 - ((red + green + blue) ~/ 3);
    return Color((argb & 0xff000000) | (tone << 16) | (tone << 8) | tone);
  }
  return Color(argb);
}

class _CadWorldPathBatch {
  const _CadWorldPathBatch({
    required this.colorArgb,
    required this.strokeWidth,
    required this.filled,
    required this.path,
    this.dashedPath,
    this.dashPeriod = 0,
  });

  final int colorArgb;
  final double strokeWidth;
  final bool filled;

  /// Continuous geometry; also drawn for linetypes too dense to resolve.
  final Path path;

  /// The same geometry broken into linetype dashes (world units).
  final Path? dashedPath;
  final double dashPeriod;
}

/// Linetype periods below this many screen pixels draw continuous, as CAD
/// viewers do when a pattern is too small to see.
const double _cadMinimumDashPeriodPixels = 3;

/// Breaks [source] into [pattern] (positive dash, negative gap, zero dot) in
/// the path's own units. Each contour starts with the pattern; contours that
/// would need more than 20,000 dashes stay continuous.
Path cadDashPath(Path source, List<double> pattern) {
  final period = pattern.fold<double>(0, (sum, value) => sum + value.abs());
  final output = Path();
  if (!(period > 0) || !pattern.any((value) => value < 0)) {
    output.addPath(source, Offset.zero);
    return output;
  }
  for (final metric in source.computeMetrics()) {
    final length = metric.length;
    if (length / period > 20000) {
      output.addPath(metric.extractPath(0, length), Offset.zero);
      continue;
    }
    var distance = 0.0;
    var index = 0;
    while (distance < length) {
      final element = pattern[index % pattern.length];
      index++;
      if (element >= 0) {
        // A zero-length dot keeps a tiny extent so the round cap draws it.
        final end = distance + (element == 0 ? period * 1e-3 : element);
        output.addPath(
          metric.extractPath(distance, math.min(end, length)),
          Offset.zero,
        );
      }
      distance += element.abs();
    }
  }
  return output;
}

class _CadWorldPathSet {
  const _CadWorldPathSet({required this.origin, required this.batches});

  final Offset origin;
  final List<_CadWorldPathBatch> batches;
}

class _CadPaintPart {
  const _CadPaintPart(this.paths, this.entities);
  final _CadWorldPathSet paths;
  final List<Map<String, dynamic>> entities;
}

class CadViewTransform {
  const CadViewTransform({
    required this.worldCenter,
    required this.screenCenter,
    required this.scale,
  });

  factory CadViewTransform.forScene(
    CadDocumentModel document,
    Size size,
    double zoom,
    Offset pan,
  ) {
    final bounds = document.bounds2D ?? const Rect.fromLTWH(-50, -50, 100, 100);
    final width = math.max(bounds.width.abs(), 1e-6);
    final height = math.max(bounds.height.abs(), 1e-6);
    final fitScale = math.min(size.width / width, size.height / height) * 0.88;
    return CadViewTransform(
      worldCenter: bounds.center,
      screenCenter: size.center(Offset.zero) + pan,
      scale: fitScale * zoom,
    );
  }

  static Offset panForAnchor(
    CadDocumentModel document,
    Size size,
    double zoom,
    Offset worldAnchor,
    Offset screenAnchor,
  ) {
    final transform = CadViewTransform.forScene(
      document,
      size,
      zoom,
      Offset.zero,
    );
    return screenAnchor - transform.worldToScreen(worldAnchor);
  }

  final Offset worldCenter;
  final Offset screenCenter;
  final double scale;

  Offset worldToScreen(Offset world) => Offset(
    screenCenter.dx + (world.dx - worldCenter.dx) * scale,
    screenCenter.dy - (world.dy - worldCenter.dy) * scale,
  );

  Offset screenToWorld(Offset screen) => Offset(
    worldCenter.dx + (screen.dx - screenCenter.dx) / scale,
    worldCenter.dy - (screen.dy - screenCenter.dy) / scale,
  );
}

class CadLocalCoordinateFrame2D {
  const CadLocalCoordinateFrame2D._({
    required this.origin,
    required this.xAxis,
    required this.yAxis,
  });

  static CadLocalCoordinateFrame2D? axisAligned(Offset origin) {
    if (!_finiteOffset2D(origin)) return null;
    return CadLocalCoordinateFrame2D._(
      origin: origin,
      xAxis: const Offset(1, 0),
      yAxis: const Offset(0, 1),
    );
  }

  static CadLocalCoordinateFrame2D? fromOriginAndXAxis(
    Offset origin,
    Offset xAxisPoint,
  ) {
    if (!_finiteOffset2D(origin) || !_finiteOffset2D(xAxisPoint)) return null;
    final delta = xAxisPoint - origin;
    if (!_finiteOffset2D(delta)) return null;
    final scale = math.max(delta.dx.abs(), delta.dy.abs());
    if (scale == 0 || !scale.isFinite) return null;
    final scaledX = delta.dx / scale;
    final scaledY = delta.dy / scale;
    final length = math.sqrt(scaledX * scaledX + scaledY * scaledY);
    if (!length.isFinite || length == 0) return null;
    final xAxis = Offset(scaledX / length, scaledY / length);
    final yAxis = Offset(-xAxis.dy, xAxis.dx);
    return CadLocalCoordinateFrame2D._(
      origin: origin,
      xAxis: xAxis,
      yAxis: yAxis,
    );
  }

  final Offset origin;
  final Offset xAxis;
  final Offset yAxis;

  double get directionDegrees {
    var value = math.atan2(xAxis.dy, xAxis.dx) * 180 / math.pi;
    if (value < 0) value += 360;
    return value;
  }

  Offset? worldToLocal(Offset world) {
    if (!_finiteOffset2D(world)) return null;
    final delta = world - origin;
    if (!_finiteOffset2D(delta)) return null;
    final local = Offset(
      delta.dx * xAxis.dx + delta.dy * xAxis.dy,
      delta.dx * yAxis.dx + delta.dy * yAxis.dy,
    );
    return _finiteOffset2D(local) ? local : null;
  }

  Offset? localToWorld(Offset local) {
    if (!_finiteOffset2D(local)) return null;
    final world = Offset(
      origin.dx + local.dx * xAxis.dx + local.dy * yAxis.dx,
      origin.dy + local.dx * xAxis.dy + local.dy * yAxis.dy,
    );
    return _finiteOffset2D(world) ? world : null;
  }
}

bool _finiteOffset2D(Offset point) => point.dx.isFinite && point.dy.isFinite;

class CadPoint3 {
  const CadPoint3(this.x, this.y, this.z);

  factory CadPoint3.fromJson(dynamic value) {
    final point = value as Map<String, dynamic>;
    return CadPoint3(
      (point['x'] as num).toDouble(),
      (point['y'] as num).toDouble(),
      (point['z'] as num).toDouble(),
    );
  }

  final double x;
  final double y;
  final double z;

  CadPoint3 operator +(CadPoint3 other) =>
      CadPoint3(x + other.x, y + other.y, z + other.z);
  CadPoint3 operator -(CadPoint3 other) =>
      CadPoint3(x - other.x, y - other.y, z - other.z);
  CadPoint3 operator *(double value) =>
      CadPoint3(x * value, y * value, z * value);
  double dot(CadPoint3 other) => x * other.x + y * other.y + z * other.z;
  CadPoint3 cross(CadPoint3 other) => CadPoint3(
    y * other.z - z * other.y,
    z * other.x - x * other.z,
    x * other.y - y * other.x,
  );
  double get length => math.sqrt(dot(this));
  CadPoint3 get normalized =>
      length < 1e-12 ? const CadPoint3(0, 0, 0) : this * (1 / length);
}

CadPoint3 cadMidpoint3D(CadPoint3 first, CadPoint3 second) => CadPoint3(
  cadStableMidpoint(first.x, second.x),
  cadStableMidpoint(first.y, second.y),
  cadStableMidpoint(first.z, second.z),
);

enum CadStandardView { isometric, front, top, right }

class CadCameraOrientation {
  const CadCameraOrientation({required this.yaw, required this.pitch});

  final double yaw;
  final double pitch;
}

CadCameraOrientation cadStandardViewOrientation(CadStandardView view) =>
    switch (view) {
      CadStandardView.isometric => const CadCameraOrientation(
        yaw: -0.75,
        pitch: 0.55,
      ),
      // Front: camera at -Y, +X points right and +Z points up.
      CadStandardView.front => const CadCameraOrientation(
        yaw: -math.pi / 2,
        pitch: 0,
      ),
      // Top: camera at +Z; the transform's pole fallback keeps +X right,
      // +Y up and therefore avoids an arbitrary roll at the pole.
      CadStandardView.top => const CadCameraOrientation(
        yaw: 0,
        pitch: math.pi / 2,
      ),
      // Right: camera at +X, +Y points right and +Z points up.
      CadStandardView.right => const CadCameraOrientation(yaw: 0, pitch: 0),
    };

class CadGrade3D {
  const CadGrade3D({
    required this.horizontalDistance,
    required this.deltaZ,
    required this.percent,
    required this.ratio,
    required this.slopeAngleDegrees,
    required this.horizontalDirection,
  });

  final double horizontalDistance;
  final double deltaZ;
  final double? percent;

  /// Horizontal-to-vertical magnitude for the conventional 1:n slope ratio.
  /// Level runs use infinity, vertical runs use zero and coincident or invalid
  /// points use null.
  final double? ratio;

  /// Signed inclination from the horizontal plane in [-90, 90] degrees.
  final double? slopeAngleDegrees;

  /// Survey direction of the XY projection. It is undefined for a vertical or
  /// coincident measurement.
  final CadSurveyDirection2D? horizontalDirection;
}

CadGrade3D cadGrade3D(CadPoint3 start, CadPoint3 end) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final deltaZ = end.z - start.z;
  if (!dx.isFinite || !dy.isFinite || !deltaZ.isFinite) {
    return const CadGrade3D(
      horizontalDistance: double.nan,
      deltaZ: double.nan,
      percent: null,
      ratio: null,
      slopeAngleDegrees: null,
      horizontalDirection: null,
    );
  }
  final horizontalScale = math.max(dx.abs(), dy.abs());
  final horizontal = horizontalScale == 0
      ? 0.0
      : horizontalScale *
            math.sqrt(
              (dx / horizontalScale) * (dx / horizontalScale) +
                  (dy / horizontalScale) * (dy / horizontalScale),
            );
  if (!horizontal.isFinite) {
    return CadGrade3D(
      horizontalDistance: horizontal,
      deltaZ: deltaZ,
      percent: null,
      ratio: null,
      slopeAngleDegrees: null,
      horizontalDirection: null,
    );
  }
  final coincident = horizontal == 0 && deltaZ == 0;
  final vertical = horizontal == 0 && deltaZ != 0;
  final level = horizontal != 0 && deltaZ == 0;
  return CadGrade3D(
    horizontalDistance: horizontal,
    deltaZ: deltaZ,
    percent: horizontal == 0 ? null : deltaZ / horizontal * 100,
    ratio: coincident
        ? null
        : vertical
        ? 0
        : level
        ? double.infinity
        : horizontal / deltaZ.abs(),
    slopeAngleDegrees: coincident
        ? null
        : math.atan2(deltaZ, horizontal) * 180 / math.pi,
    horizontalDirection: horizontal == 0
        ? null
        : cadSurveyDirection2D(Offset(start.x, start.y), Offset(end.x, end.y)),
  );
}

/// Returns the smaller spatial angle at [vertex] in degrees.
///
/// Vectors are scaled before taking their lengths so large engineering
/// coordinates do not overflow while computing the dot product.
double? angleDegrees3D(
  CadPoint3 vertex,
  CadPoint3 firstRayPoint,
  CadPoint3 secondRayPoint,
) {
  final first = firstRayPoint - vertex;
  final second = secondRayPoint - vertex;
  final firstScale = math.max(
    first.x.abs(),
    math.max(first.y.abs(), first.z.abs()),
  );
  final secondScale = math.max(
    second.x.abs(),
    math.max(second.y.abs(), second.z.abs()),
  );
  if (!firstScale.isFinite ||
      !secondScale.isFinite ||
      firstScale == 0 ||
      secondScale == 0) {
    return null;
  }
  final normalizedFirst = first * (1 / firstScale);
  final normalizedSecond = second * (1 / secondScale);
  final denominator = normalizedFirst.length * normalizedSecond.length;
  if (!denominator.isFinite || denominator <= 1e-12) return null;
  final cosine = (normalizedFirst.dot(normalizedSecond) / denominator).clamp(
    -1.0,
    1.0,
  );
  return math.acos(cosine) * 180 / math.pi;
}

final Expando<List<CadPoint3>> _meshPositionCache = Expando<List<CadPoint3>>();
final Expando<List<int>> _meshIndexCache = Expando<List<int>>();

class CadMeshTriangleMetrics3D {
  const CadMeshTriangleMetrics3D({
    required this.firstEdgeLength,
    required this.secondEdgeLength,
    required this.thirdEdgeLength,
    required this.perimeter,
    required this.area,
    required this.centroid,
    required this.normal,
    required this.slope,
  });

  final double firstEdgeLength;
  final double secondEdgeLength;
  final double thirdEdgeLength;
  final double perimeter;
  final double area;
  final CadPoint3 centroid;
  final CadPoint3? normal;
  final CadMeshFaceSlope3D? slope;
}

class CadMeshFaceSlope3D {
  const CadMeshFaceSlope3D({
    required this.inclinationDegrees,
    required this.gradePercent,
    required this.downslopeAzimuthDegrees,
  });

  /// Acute angle from the horizontal plane, in the range 0° to 90°.
  final double inclinationDegrees;

  /// Rise/run percentage. A vertical face has no finite grade.
  final double? gradePercent;

  /// Direction of steepest descent, clockwise from drawing +Y. Horizontal and
  /// vertical faces do not have a unique finite downslope direction.
  final double? downslopeAzimuthDegrees;
}

/// Converts a face normal into winding-independent engineering slope values.
/// The normal does not have to be normalized. Numerically horizontal or
/// vertical faces deliberately omit the direction values that are undefined.
CadMeshFaceSlope3D? cadMeshFaceSlope3D(CadPoint3 normal) {
  final unit = _normalizedCadVector3(normal);
  if (unit == null) return null;
  var x = unit.x;
  var y = unit.y;
  var z = unit.z;

  // Choose the upward normal so reversing triangle winding cannot reverse the
  // reported downslope direction.
  if (z < 0) {
    x = -x;
    y = -y;
    z = -z;
  }
  final horizontal = math.sqrt(x * x + y * y);
  final vertical = z.abs();
  if (!horizontal.isFinite || !vertical.isFinite) return null;
  final inclination = math.atan2(horizontal, vertical) * 180 / math.pi;
  if (!inclination.isFinite) return null;

  const axisTolerance = 1e-12;
  final grade = vertical <= axisTolerance
      ? null
      : (horizontal / vertical) * 100;
  double? azimuth;
  if (horizontal > axisTolerance && vertical > axisTolerance) {
    azimuth = math.atan2(x, y) * 180 / math.pi;
    if (azimuth < 0) azimuth += 360;
    if (!azimuth.isFinite) return null;
  }
  return CadMeshFaceSlope3D(
    inclinationDegrees: inclination,
    gradePercent: grade?.isFinite == true ? grade : null,
    downslopeAzimuthDegrees: azimuth,
  );
}

/// Returns the smaller unoriented angle between two planes. Absolute dot
/// product makes the result independent of triangle winding and constrains it
/// to the engineering plane-angle range 0° to 90°.
double? cadMeshFaceAngleDegrees3D(
  CadPoint3 firstNormal,
  CadPoint3 secondNormal,
) {
  final first = _normalizedCadVector3(firstNormal);
  final second = _normalizedCadVector3(secondNormal);
  if (first == null || second == null) return null;
  final cosine = first.dot(second).abs().clamp(0.0, 1.0);
  final angle = math.acos(cosine) * 180 / math.pi;
  return angle.isFinite ? angle : null;
}

class CadMeshFaceRelation3D {
  const CadMeshFaceRelation3D({
    required this.angleDegrees,
    required this.parallelSeparation,
  });

  final double angleDegrees;

  /// Perpendicular distance between the two infinite planes. Null means the
  /// planes are not parallel enough for a unique spacing, or the spacing
  /// cannot be represented as a finite double.
  final double? parallelSeparation;
}

/// Measures the unoriented relation between two picked triangle planes. The
/// picked points may lie anywhere on their respective planes. Separation is
/// reported only under a strict scale-independent parallel test, so the
/// distance between arbitrary tap positions is never mislabeled as thickness.
CadMeshFaceRelation3D? cadMeshFaceRelation3D(
  CadPoint3 firstPoint,
  CadPoint3 firstNormal,
  CadPoint3 secondPoint,
  CadPoint3 secondNormal,
) {
  if (!_finiteCadPoint3(firstPoint) || !_finiteCadPoint3(secondPoint)) {
    return null;
  }
  final first = _normalizedCadVector3(firstNormal);
  final second = _normalizedCadVector3(secondNormal);
  if (first == null || second == null) return null;
  final angle = cadMeshFaceAngleDegrees3D(first, second);
  if (angle == null) return null;
  final sine = _stableCadVectorLength3(first.cross(second));
  if (sine == null) return null;

  double? separation;
  // Keep this close to double-precision numerical noise. A visibly or even
  // slightly converging pair of planes has no unique separation and must not
  // be presented as a thickness measurement.
  const parallelSineTolerance = 1e-12;
  if (sine <= parallelSineTolerance) {
    final delta = secondPoint - firstPoint;
    if (_finiteCadPoint3(delta)) {
      final projected = _compensatedFiniteDot3(delta, first);
      if (projected != null) separation = projected.abs();
    }
  }
  return CadMeshFaceRelation3D(
    angleDegrees: angle,
    parallelSeparation: separation,
  );
}

CadPoint3? _normalizedCadVector3(CadPoint3 vector) {
  if (!_finiteCadPoint3(vector)) return null;
  final scale = math.max(
    vector.x.abs(),
    math.max(vector.y.abs(), vector.z.abs()),
  );
  if (scale == 0) return null;
  final scaled = vector * (1 / scale);
  final length = math.sqrt(scaled.dot(scaled));
  if (!length.isFinite || length == 0) return null;
  final unit = scaled * (1 / length);
  return _finiteCadPoint3(unit) ? unit : null;
}

/// Computes engineering values only for the selected indexed triangle. Bad
/// indices and non-finite coordinates reject the result instead of exposing a
/// partial property sheet. Degenerate faces retain zero area and no normal.
CadMeshTriangleMetrics3D? cadMeshTriangleMetrics3D(
  Map<String, dynamic> mesh,
  int triangleIndex,
) {
  if (triangleIndex < 0) return null;
  final positions = mesh['positions'];
  final indices = mesh['indices'];
  if (positions is! List || indices is! List) return null;
  final firstIndex = triangleIndex * 3;
  if (firstIndex < 0 || firstIndex + 2 >= indices.length) return null;
  final rawIndices = indices.sublist(firstIndex, firstIndex + 3);
  if (rawIndices.any((value) => value is! int)) return null;
  final triangleIndices = rawIndices.cast<int>();
  if (triangleIndices.any((index) => index < 0 || index >= positions.length)) {
    return null;
  }
  final first = _strictCadPoint3(positions[triangleIndices[0]]);
  final second = _strictCadPoint3(positions[triangleIndices[1]]);
  final third = _strictCadPoint3(positions[triangleIndices[2]]);
  if (first == null || second == null || third == null) return null;
  final firstEdge = second - first;
  final secondEdge = third - second;
  final thirdEdge = first - third;
  final firstEdgeLength = _stableCadVectorLength3(firstEdge);
  final secondEdgeLength = _stableCadVectorLength3(secondEdge);
  final thirdEdgeLength = _stableCadVectorLength3(thirdEdge);
  if (firstEdgeLength == null ||
      secondEdgeLength == null ||
      thirdEdgeLength == null) {
    return null;
  }
  final originToThird = third - first;
  final originToThirdLength = _stableCadVectorLength3(originToThird);
  if (originToThirdLength == null) return null;
  var area = 0.0;
  CadPoint3? normal;
  if (firstEdgeLength > 0 && originToThirdLength > 0) {
    final firstUnit = firstEdge * (1 / firstEdgeLength);
    final thirdUnit = originToThird * (1 / originToThirdLength);
    final cross = firstUnit.cross(thirdUnit);
    final sine = _stableCadVectorLength3(cross);
    if (sine == null) return null;
    area =
        (math.max(firstEdgeLength, originToThirdLength) * (sine * 0.5)) *
        math.min(firstEdgeLength, originToThirdLength);
    if (!area.isFinite || area < 0) return null;
    // A nearly collinear triangle has an ill-conditioned normal even if its
    // tiny floating-point cross product is non-zero.
    if (sine > 1e-12) normal = cross * (1 / sine);
  }
  final perimeter = _compensatedFiniteSum3(
    firstEdgeLength,
    secondEdgeLength,
    thirdEdgeLength,
  );
  final centroid =
      first + (second - first) * (1 / 3) + (third - first) * (1 / 3);
  if (perimeter == null ||
      !_finiteCadPoint3(centroid) ||
      (normal != null && !_finiteCadPoint3(normal))) {
    return null;
  }
  return CadMeshTriangleMetrics3D(
    firstEdgeLength: firstEdgeLength,
    secondEdgeLength: secondEdgeLength,
    thirdEdgeLength: thirdEdgeLength,
    perimeter: perimeter,
    area: area,
    centroid: centroid,
    normal: normal,
    slope: normal == null ? null : cadMeshFaceSlope3D(normal),
  );
}

CadPoint3? _strictCadPoint3(dynamic value) {
  if (value is! Map<String, dynamic>) return null;
  final x = (value['x'] as num?)?.toDouble();
  final y = (value['y'] as num?)?.toDouble();
  final z = (value['z'] as num?)?.toDouble();
  if (x == null || y == null || z == null) return null;
  final point = CadPoint3(x, y, z);
  return _finiteCadPoint3(point) ? point : null;
}

bool _finiteCadPoint3(CadPoint3 point) =>
    point.x.isFinite && point.y.isFinite && point.z.isFinite;

double? _stableCadVectorLength3(CadPoint3 vector) {
  if (!_finiteCadPoint3(vector)) return null;
  final scale = math.max(
    vector.x.abs(),
    math.max(vector.y.abs(), vector.z.abs()),
  );
  if (scale == 0) return 0;
  final x = vector.x / scale;
  final y = vector.y / scale;
  final z = vector.z / scale;
  final length = scale * math.sqrt(x * x + y * y + z * z);
  return length.isFinite ? length : null;
}

double? _compensatedFiniteSum3(double first, double second, double third) {
  var total = 0.0;
  var compensation = 0.0;
  for (final value in [first, second, third]) {
    final corrected = value - compensation;
    final updated = total + corrected;
    if (!updated.isFinite) return null;
    compensation = (updated - total) - corrected;
    total = updated;
  }
  return total;
}

double? _compensatedFiniteDot3(CadPoint3 first, CadPoint3 second) {
  final x = first.x * second.x;
  final y = first.y * second.y;
  final z = first.z * second.z;
  if (!x.isFinite || !y.isFinite || !z.isFinite) return null;
  return _compensatedFiniteSum3(x, y, z);
}

List<CadPoint3> _meshPositions(Map<String, dynamic> mesh) =>
    _meshPositionCache[mesh] ??= (mesh['positions'] as List<dynamic>)
        .map(CadPoint3.fromJson)
        .toList(growable: false);

List<int> _meshIndices(Map<String, dynamic> mesh) => _meshIndexCache[mesh] ??=
    (mesh['indices'] as List<dynamic>).cast<int>().toList(growable: false);

class CadRay3 {
  const CadRay3(this.origin, this.direction);

  final CadPoint3 origin;
  final CadPoint3 direction;
}

class CadMeshHit {
  const CadMeshHit({
    required this.meshId,
    required this.triangleIndex,
    required this.position,
    required this.distance,
  });

  final BigInt meshId;
  final int triangleIndex;
  final CadPoint3 position;
  final double distance;
}

class Cad3DViewTransform {
  const Cad3DViewTransform({
    required this.center,
    required this.right,
    required this.up,
    required this.cameraAxis,
    required this.screenCenter,
    required this.scale,
    required this.radius,
  });

  factory Cad3DViewTransform.forScene(
    CadDocumentModel document,
    Size size,
    double zoom,
    Offset pan,
    double yaw,
    double pitch,
  ) {
    final bounds = document.scene['bounds'] as Map<String, dynamic>?;
    final min = bounds?['min'] as Map<String, dynamic>?;
    final max = bounds?['max'] as Map<String, dynamic>?;
    var minX = (min?['x'] as num?)?.toDouble() ?? -1;
    var minY = (min?['y'] as num?)?.toDouble() ?? -1;
    var minZ = (min?['z'] as num?)?.toDouble() ?? -1;
    var maxX = (max?['x'] as num?)?.toDouble() ?? 1;
    var maxY = (max?['y'] as num?)?.toDouble() ?? 1;
    var maxZ = (max?['z'] as num?)?.toDouble() ?? 1;
    final center = CadPoint3(
      (minX + maxX) / 2,
      (minY + maxY) / 2,
      (minZ + maxZ) / 2,
    );
    final diagonal = CadPoint3(maxX - minX, maxY - minY, maxZ - minZ).length;
    final radius = math.max(diagonal / 2, 1e-6);
    final cameraAxis = CadPoint3(
      math.cos(pitch) * math.cos(yaw),
      math.cos(pitch) * math.sin(yaw),
      math.sin(pitch),
    ).normalized;
    var right = const CadPoint3(0, 0, 1).cross(cameraAxis).normalized;
    if (right.length < 1e-8) right = const CadPoint3(1, 0, 0);
    final up = cameraAxis.cross(right).normalized;
    return Cad3DViewTransform(
      center: center,
      right: right,
      up: up,
      cameraAxis: cameraAxis,
      screenCenter: size.center(Offset.zero) + pan,
      scale: math.min(size.width, size.height) * 0.72 / (radius * 2) * zoom,
      radius: radius,
    );
  }

  static Offset panForAnchor(
    CadDocumentModel document,
    Size size,
    double zoom,
    double yaw,
    double pitch,
    CadPoint3 worldAnchor,
    Offset screenAnchor,
  ) {
    final transform = Cad3DViewTransform.forScene(
      document,
      size,
      zoom,
      Offset.zero,
      yaw,
      pitch,
    );
    return screenAnchor - transform.project(worldAnchor);
  }

  final CadPoint3 center;
  final CadPoint3 right;
  final CadPoint3 up;
  final CadPoint3 cameraAxis;
  final Offset screenCenter;
  final double scale;
  final double radius;

  Offset project(CadPoint3 point) {
    final relative = point - center;
    return Offset(
      screenCenter.dx + relative.dot(right) * scale,
      screenCenter.dy - relative.dot(up) * scale,
    );
  }

  CadRay3 screenRay(Offset screen) {
    final horizontal = (screen.dx - screenCenter.dx) / scale;
    final vertical = (screenCenter.dy - screen.dy) / scale;
    final planePoint = center + right * horizontal + up * vertical;
    return CadRay3(planePoint + cameraAxis * (radius * 4), cameraAxis * -1);
  }

  CadPoint3 screenPlanePoint(Offset screen) {
    final ray = screenRay(screen);
    return ray.origin + ray.direction * (radius * 4);
  }

  CadMeshHit? hitTest(CadDocumentModel document, Offset screen) {
    final ray = screenRay(screen);
    CadMeshHit? nearest;
    final visibleIds = document.visibleMeshIds;
    for (final mesh in document.meshes) {
      final meshId = mesh['id'] as int;
      if (!visibleIds.contains(meshId)) continue;
      final positions = _meshPositions(mesh);
      final indices = _meshIndices(mesh);
      for (var index = 0; index + 2 < indices.length; index += 3) {
        final distance = _rayTriangleDistance(
          ray,
          positions[indices[index]],
          positions[indices[index + 1]],
          positions[indices[index + 2]],
        );
        if (distance == null ||
            (nearest != null && distance >= nearest.distance)) {
          continue;
        }
        nearest = CadMeshHit(
          meshId: BigInt.from(meshId),
          triangleIndex: index ~/ 3,
          position: ray.origin + ray.direction * distance,
          distance: distance,
        );
      }
    }
    return nearest;
  }

  static double? _rayTriangleDistance(
    CadRay3 ray,
    CadPoint3 a,
    CadPoint3 b,
    CadPoint3 c,
  ) {
    const epsilon = 1e-9;
    final edge1 = b - a;
    final edge2 = c - a;
    final h = ray.direction.cross(edge2);
    final determinant = edge1.dot(h);
    if (determinant.abs() < epsilon) return null;
    final inverse = 1 / determinant;
    final s = ray.origin - a;
    final u = inverse * s.dot(h);
    if (u < 0 || u > 1) return null;
    final q = s.cross(edge1);
    final v = inverse * ray.direction.dot(q);
    if (v < 0 || u + v > 1) return null;
    final distance = inverse * edge2.dot(q);
    return distance > epsilon ? distance : null;
  }
}

class CadScenePainter extends CustomPainter {
  CadScenePainter({
    required this.document,
    required this.zoom,
    required this.pan,
    this.annotations = const [],
    this.selectedEntityId,
    this.selectedEntityIds = const {},
    this.subtractedEntityIds = const {},
    this.measurementPoints = const [],
    this.measurementIntersectionPoints = const [],
    this.indexedMeasurementPoints = const [],
    this.measurementCentroid,
    this.measurementClosed = false,
    this.measurementRectangle = false,
    this.measurementOrientedRectangle = false,
    this.measurementCircle3Point = false,
    this.measurementArc3Point = false,
    this.measurementPointLineOffset = false,
    this.measurementLineIntersection = false,
    this.measurementParallelLineSpacing = false,
    this.measurementSegmentClearance = false,
    this.measurementMidpoint = false,
    this.measurementAngle = false,
    this.yaw = -0.75,
    this.pitch = 0.55,
    this.selectedMeshId,
    this.measurement3DPoints = const [],
    this.measurement3DFaces = const [],
    this.measurement3DAngle = false,
    this.coordinateOrigin2D,
    this.coordinateXAxis2D,
    this.coordinateOrigin3D,
    this.showGrid = true,
  });

  final CadDocumentModel document;

  /// The faint screen grid; sheet exports leave it out like a plot.
  final bool showGrid;
  final double zoom;
  final Offset pan;
  final List<CadTextAnnotation> annotations;
  final BigInt? selectedEntityId;
  final Set<BigInt> selectedEntityIds;
  final Set<BigInt> subtractedEntityIds;
  final List<Offset> measurementPoints;
  final List<Offset> measurementIntersectionPoints;
  final List<Offset> indexedMeasurementPoints;
  final Offset? measurementCentroid;
  final bool measurementClosed;
  final bool measurementRectangle;
  final bool measurementOrientedRectangle;
  final bool measurementCircle3Point;
  final bool measurementArc3Point;
  final bool measurementPointLineOffset;
  final bool measurementLineIntersection;
  final bool measurementParallelLineSpacing;
  final bool measurementSegmentClearance;
  final bool measurementMidpoint;
  final bool measurementAngle;
  final double yaw;
  final double pitch;
  final BigInt? selectedMeshId;
  final List<CadPoint3> measurement3DPoints;
  final List<CadMeshHit> measurement3DFaces;
  final bool measurement3DAngle;
  final Offset? coordinateOrigin2D;
  final Offset? coordinateXAxis2D;
  final CadPoint3? coordinateOrigin3D;

  static final Expando<Rect> _polylineBounds = Expando<Rect>();
  static final Expando<List<_CadPaintPart>> _worldPathCache =
      Expando<List<_CadPaintPart>>();
  static final LinkedHashMap<
    (
      int,
      int,
      String,
      String,
      double?,
      String,
      bool,
      int,
      String,
      bool,
      String,
      bool,
    ),
    _CadTextBlockLayout
  >
  _textLayouts = LinkedHashMap();
  static int _cachedTextParagraphs = 0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff071017),
    );
    if (showGrid) _paintGrid(canvas, size);
    switch (document.sceneKind) {
      case 'two_d':
        _paint2D(canvas, size);
      case 'three_d':
        _paint3D(canvas, size);
      case 'paged':
        _paintPaged(canvas, size);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.035)
      ..strokeWidth = 1;
    const spacing = 32.0;
    final dx = pan.dx % spacing;
    final dy = pan.dy % spacing;
    for (double x = dx; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = dy; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _paint2D(Canvas canvas, Size size) {
    final transform = CadViewTransform.forScene(document, size, zoom, pan);
    final visibleLayers = {
      for (final layer in document.layers) layer.id.toInt(): layer.visible,
    };
    final parts = _worldPathCache[document] ??= _buildPaintParts(
      document,
      visibleLayers,
    );
    for (final part in parts) {
      final pathSet = part.paths;
      canvas.save();
      final pathOrigin = transform.worldToScreen(pathSet.origin);
      canvas.translate(pathOrigin.dx, pathOrigin.dy);
      canvas.scale(transform.scale, -transform.scale);
      final inverseScale = 1 / transform.scale;
      for (final batch in pathSet.batches) {
        final worldStrokeWidth = batch.strokeWidth > 0
            ? batch.strokeWidth
            : 1.15 * inverseScale;
        final dashed =
            batch.dashedPath != null &&
            batch.dashPeriod * transform.scale >= _cadMinimumDashPeriodPixels;
        canvas.drawPath(
          dashed ? batch.dashedPath! : batch.path,
          Paint()
            ..color = cadCanvasColor(batch.colorArgb)
            ..style = batch.filled ? PaintingStyle.fill : PaintingStyle.stroke
            ..strokeWidth = worldStrokeWidth
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      canvas.restore();

      for (final entity in part.entities) {
        if (!(visibleLayers[entity['layer_id'] as int] ?? true)) continue;
        final geometry = entity['geometry'] as Map<String, dynamic>;
        final kind = geometry['kind'];
        if (kind != 'point' &&
            kind != 'text' &&
            selectedEntityId == null &&
            selectedEntityIds.isEmpty) {
          continue;
        }
        final entityId = BigInt.from(entity['id'] as int);
        final selected =
            entityId == selectedEntityId ||
            selectedEntityIds.contains(entityId);
        final subtracted = subtractedEntityIds.contains(entityId);
        if (kind != 'point' && kind != 'text' && !selected) continue;
        if (!_geometryVisible(geometry, transform, size)) continue;
        if (selected && geometry['kind'] != 'text') {
          _paintSelected2D(
            canvas,
            geometry,
            transform,
            color: subtracted
                ? const Color(0xffff6b6b)
                : const Color(0xffffd666),
          );
        }
        switch (geometry['kind']) {
          case 'point':
            final point = transform.worldToScreen(_point(geometry['position']));
            canvas.drawCircle(
              point,
              selected ? 5 : 2.5,
              Paint()
                ..color = cadCanvasColor(
                  selected ? 0xffffd666 : entity['color_argb'] as int,
                )
                ..style = PaintingStyle.stroke
                ..strokeWidth = selected ? 2.5 : 1.15,
            );
          case 'text':
            final origin = transform.worldToScreen(_point(geometry['origin']));
            final value = geometry['value'] as String;
            final screenHeight =
                (geometry['height'] as num).toDouble().abs() * transform.scale;
            const fontSize = _cadTextShapeSize;
            final shxOptions = cadShxTextOptions(geometry);
            final fontFamily = shxOptions.family;
            final background = geometry['background'] as Map<String, dynamic>?;
            final sourceArgb = entity['color_argb'] as int;
            final ink = selected
                ? const Color(0xffffd666)
                : background?['layout_supported'] != false &&
                      background?['fill'] == true &&
                      background?['color_mode'] != 'canvas'
                ? Color(sourceArgb)
                : cadCanvasColor(sourceArgb);
            final text = _textLayout(
              value,
              ink,
              fontSize,
              fontFamily,
              maxWidth: _cadTextWrapWidth(geometry, fontSize),
              runs: geometry['text_runs'] as List<dynamic>?,
              heightIsCapHeight: geometry['height_reference'] != 'em',
              lineSpacing: geometry['line_spacing'] as Map<String, dynamic>?,
              columns: _cadTextColumns(geometry, fontSize),
              cjkEmIsHeight: shxOptions.cjkEmIsHeight,
            );
            final (horizontalScale, verticalScale) = _cadTextScales(
              geometry,
              text,
              screenHeight,
              transform.scale,
              fontSize,
            );
            final horizontalAlignment =
                geometry['horizontal_alignment'] as String? ?? 'left';
            final verticalAlignment =
                geometry['vertical_alignment'] as String? ?? 'baseline';
            final offsetX = switch (horizontalAlignment) {
              'center' => -text.width / 2,
              'right' => -text.width,
              _ => 0.0,
            };
            final offsetY = switch (verticalAlignment) {
              'top' => 0.0,
              'middle' => -text.height / 2,
              'bottom' => -text.height,
              _ => -text.computeDistanceToActualBaseline(
                TextBaseline.alphabetic,
              ),
            };
            final obliqueAngle =
                (geometry['oblique_angle'] as num?)?.toDouble() ?? 0.0;
            canvas.save();
            canvas.translate(origin.dx, origin.dy);
            final plane = geometry['plane'] as Map<String, dynamic>?;
            if (plane != null) {
              canvas.transform(
                Float64List.fromList([
                  (plane['xx'] as num).toDouble(),
                  -(plane['yx'] as num).toDouble(),
                  0,
                  0,
                  -(plane['xy'] as num).toDouble(),
                  (plane['yy'] as num).toDouble(),
                  0,
                  0,
                  0,
                  0,
                  1,
                  0,
                  0,
                  0,
                  0,
                  1,
                ]),
              );
            }
            canvas.rotate(-(geometry['rotation'] as num).toDouble());
            if (obliqueAngle.isFinite && obliqueAngle.abs() > 1e-9) {
              canvas.skew(-math.tan(obliqueAngle), 0);
            }
            canvas.scale(horizontalScale, verticalScale);
            if (background != null && background['layout_supported'] != false) {
              // Paint every column mask before any glyphs. Glyph overhang is
              // never clipped, nor erased by a neighbouring column's mask.
              for (final box in text.boxes) {
                final rect = cadTextBackgroundRect(
                  geometry,
                  box.shift(Offset(offsetX, offsetY)),
                );
                if (background['fill'] == true) {
                  canvas.drawRect(
                    rect,
                    Paint()
                      ..color = background['color_mode'] == 'canvas'
                          ? const Color(0xff071017)
                          : Color(background['color_argb'] as int),
                  );
                }
                if (background['frame'] == true) {
                  final planeScale = plane == null
                      ? 1.0
                      : math.max(
                          math.sqrt(
                            math.pow((plane['xx'] as num).toDouble(), 2) +
                                math.pow((plane['yx'] as num).toDouble(), 2),
                          ),
                          math.sqrt(
                            math.pow((plane['xy'] as num).toDouble(), 2) +
                                math.pow((plane['yy'] as num).toDouble(), 2),
                          ),
                        );
                  canvas.drawRect(
                    rect,
                    Paint()
                      ..color = ink
                      ..style = PaintingStyle.stroke
                      ..strokeWidth =
                          1 /
                          math.max(
                            1e-9,
                            math.max(
                                  horizontalScale.abs(),
                                  verticalScale.abs(),
                                ) *
                                planeScale,
                          ),
                  );
                }
              }
            }
            text.paint(canvas, Offset(offsetX, offsetY));
            canvas.restore();
        }
      }
    }

    for (final annotation in annotations.where((item) => !item.is3D)) {
      final point = transform.worldToScreen(Offset(annotation.x, annotation.y));
      final markerPaint = Paint()..color = const Color(0xffffcc00);
      canvas.drawCircle(point, 5, markerPaint);
      canvas.drawLine(
        point,
        point + const Offset(0, -15),
        markerPaint..strokeWidth = 2,
      );
      final label = TextPainter(
        text: TextSpan(
          text: annotation.value,
          style: const TextStyle(
            color: Color(0xffffe58f),
            fontSize: 12,
            backgroundColor: Color(0xdd2b2410),
            fontFamily: cadDefaultFontFamily,
            fontFamilyFallback: _cadFontFallback,
          ),
        ),
        maxLines: 2,
        ellipsis: '…',
        textDirection: _textDirection(annotation.value),
      )..layout(maxWidth: 180);
      label.paint(canvas, point + const Offset(8, -28));
    }

    if (coordinateOrigin2D != null) {
      final origin = transform.worldToScreen(coordinateOrigin2D!);
      _paintCoordinateOrigin(canvas, origin);
      if (coordinateXAxis2D != null) {
        _paintCoordinateXAxis(canvas, origin, coordinateXAxis2D!);
      }
    }
    final measurementPaint = Paint()
      ..color = const Color(0xff53d4ff)
      ..strokeWidth = 2;
    final screenPoints = measurementPoints
        .map(transform.worldToScreen)
        .toList(growable: false);
    for (final point in screenPoints) {
      canvas.drawCircle(point, 5, measurementPaint);
    }
    final intersectionPaint = Paint()
      ..color = const Color(0xffffc53d)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final worldPoint in measurementIntersectionPoints) {
      final point = transform.worldToScreen(worldPoint);
      canvas.drawCircle(point, 7, intersectionPaint);
      canvas.drawLine(
        point - const Offset(4, 4),
        point + const Offset(4, 4),
        intersectionPaint,
      );
      canvas.drawLine(
        point + const Offset(4, -4),
        point + const Offset(-4, 4),
        intersectionPaint,
      );
    }
    for (var index = 0; index < indexedMeasurementPoints.length; index++) {
      final point = transform.worldToScreen(indexedMeasurementPoints[index]);
      if (point.dx < -16 ||
          point.dy < -16 ||
          point.dx > size.width + 16 ||
          point.dy > size.height + 16) {
        continue;
      }
      final value = '${index + 1}';
      final radius = value.length >= 3 ? 11.0 : 9.0;
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = const Color(0xee0e1720)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = const Color(0xff53d4ff)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
      final label = TextPainter(
        text: TextSpan(
          text: value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            fontFamily: cadDefaultFontFamily,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, point - Offset(label.width / 2, label.height / 2));
    }
    if (screenPoints.length >= 2) {
      if ((measurementParallelLineSpacing || measurementSegmentClearance) &&
          measurementPoints.length == 6) {
        final sourcePaint = Paint()
          ..color = const Color(0xff53d4ff)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke;
        for (final pair in const [(0, 1), (2, 3)]) {
          canvas.drawLine(
            screenPoints[pair.$1],
            screenPoints[pair.$2],
            sourcePaint,
          );
        }
        final spacingPaint = Paint()
          ..color = const Color(0xffffc53d)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
        final firstFoot = screenPoints[4];
        final secondFoot = screenPoints[5];
        canvas.drawLine(firstFoot, secondFoot, spacingPaint);
        canvas.drawCircle(firstFoot, 4, spacingPaint);
        canvas.drawCircle(secondFoot, 4, spacingPaint);
      } else if (measurementLineIntersection && measurementPoints.length == 5) {
        final guidePaint = Paint()
          ..color = const Color(0xff53d4ff).withValues(alpha: 0.42)
          ..strokeWidth = 1.25
          ..style = PaintingStyle.stroke;
        final sourcePaint = Paint()
          ..color = const Color(0xff53d4ff)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke;
        final extent = size.longestSide * 2;
        for (final pair in const [(0, 1), (2, 3)]) {
          final vector = screenPoints[pair.$2] - screenPoints[pair.$1];
          final length = vector.distance;
          if (length <= 1e-12) continue;
          final unit = vector / length;
          canvas.drawLine(
            screenPoints[pair.$1] - unit * extent,
            screenPoints[pair.$1] + unit * extent,
            guidePaint,
          );
          canvas.drawLine(
            screenPoints[pair.$1],
            screenPoints[pair.$2],
            sourcePaint,
          );
        }
        final intersection = screenPoints[4];
        final markerPaint = Paint()
          ..color = const Color(0xffffc53d)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(intersection, 7, markerPaint);
        canvas.drawLine(
          intersection - const Offset(5, 5),
          intersection + const Offset(5, 5),
          markerPaint,
        );
        canvas.drawLine(
          intersection + const Offset(5, -5),
          intersection + const Offset(-5, 5),
          markerPaint,
        );
      } else if (measurementPointLineOffset && measurementPoints.length == 3) {
        final offset = cadPointLineMeasurement2D(
          measurementPoints[0],
          measurementPoints[1],
          measurementPoints[2],
        );
        if (offset != null) {
          final foot = transform.worldToScreen(offset.foot);
          final baselineVector = screenPoints[1] - screenPoints[0];
          final baselineUnit = baselineVector / baselineVector.distance;
          final baselineExtent = size.longestSide * 2;
          canvas.drawLine(
            screenPoints[0] - baselineUnit * baselineExtent,
            screenPoints[0] + baselineUnit * baselineExtent,
            measurementPaint,
          );
          canvas.drawLine(screenPoints[2], foot, measurementPaint);
          canvas.drawCircle(
            foot,
            4,
            measurementPaint..style = PaintingStyle.stroke,
          );
        }
      } else if (measurementArc3Point && measurementPoints.length == 3) {
        final arc = cadThreePointArcMeasurement2D(
          measurementPoints[0],
          measurementPoints[1],
          measurementPoints[2],
        );
        if (arc != null) {
          final center = transform.worldToScreen(arc.center);
          final radius = arc.radius * transform.scale;
          final startAngle = -math.atan2(
            measurementPoints[0].dy - arc.center.dy,
            measurementPoints[0].dx - arc.center.dx,
          );
          final screenSweep = arc.counterClockwise
              ? -arc.sweepRadians
              : arc.sweepRadians;
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            startAngle,
            screenSweep,
            false,
            Paint()
              ..color = const Color(0xff53d4ff)
              ..strokeWidth = 2
              ..style = PaintingStyle.stroke,
          );
          final guidePaint = Paint()
            ..color = const Color(0xff53d4ff).withValues(alpha: 0.45)
            ..strokeWidth = 1.25
            ..style = PaintingStyle.stroke;
          canvas.drawLine(center, screenPoints.first, guidePaint);
          canvas.drawLine(center, screenPoints.last, guidePaint);
          canvas.drawCircle(center, 4, guidePaint);
        }
      } else if (measurementCircle3Point && measurementPoints.length == 3) {
        final circle = cadThreePointCircleMeasurement2D(
          measurementPoints[0],
          measurementPoints[1],
          measurementPoints[2],
        );
        if (circle != null) {
          canvas.drawCircle(
            transform.worldToScreen(circle.center),
            circle.radius * transform.scale,
            measurementPaint..style = PaintingStyle.stroke,
          );
        }
      } else if (measurementOrientedRectangle &&
          measurementPoints.length == 3) {
        final rectangle = cadOrientedRectangleMeasurement2D(
          measurementPoints[0],
          measurementPoints[1],
          measurementPoints[2],
        );
        if (rectangle != null) {
          final corners = rectangle.corners
              .map(transform.worldToScreen)
              .toList(growable: false);
          final path = Path()..moveTo(corners.first.dx, corners.first.dy);
          for (final corner in corners.skip(1)) {
            path.lineTo(corner.dx, corner.dy);
          }
          canvas.drawPath(
            path..close(),
            measurementPaint..style = PaintingStyle.stroke,
          );
        }
      } else if (measurementRectangle) {
        canvas.drawRect(
          Rect.fromPoints(screenPoints[0], screenPoints[1]),
          measurementPaint..style = PaintingStyle.stroke,
        );
      } else if (measurementAngle) {
        for (final point in screenPoints.skip(1)) {
          canvas.drawLine(screenPoints.first, point, measurementPaint);
        }
        if (screenPoints.length == 3) {
          canvas.drawLine(
            screenPoints[1],
            screenPoints[2],
            Paint()
              ..color = const Color(0xff53d4ff).withValues(alpha: 0.55)
              ..strokeWidth = 1.25
              ..style = PaintingStyle.stroke,
          );
        }
      } else {
        final path = Path()
          ..moveTo(screenPoints.first.dx, screenPoints.first.dy);
        for (final point in screenPoints.skip(1)) {
          path.lineTo(point.dx, point.dy);
        }
        if (measurementClosed && screenPoints.length >= 3) path.close();
        canvas.drawPath(path, measurementPaint..style = PaintingStyle.stroke);
      }
    }
    if (measurementMidpoint && screenPoints.length == 2) {
      _paintMidpointMarker(
        canvas,
        transform.worldToScreen(
          cadMidpoint2D(measurementPoints[0], measurementPoints[1]),
        ),
      );
    }
    if (measurementCentroid != null) {
      _paintCentroidMarker(
        canvas,
        transform.worldToScreen(measurementCentroid!),
      );
    }
  }

  List<_CadPaintPart> _buildPaintParts(
    CadDocumentModel source,
    Map<int, bool> visibleLayers,
  ) {
    // Keep the fast globally batched path for undecorated drawings. A mask is
    // an ordering barrier: later geometry must not be hidden merely because
    // all text was previously painted in a final foreground pass. Cache the
    // segments once, not new paths or paragraphs on every camera change.
    final entities = source.entities;
    final decorated = entities.any(
      (entity) =>
          (visibleLayers[entity['layer_id'] as int] ?? true) &&
          (entity['geometry'] as Map)['background'] != null,
    );
    if (!decorated) {
      return [
        _CadPaintPart(
          _buildWorldPathSet(source, visibleLayers, entities),
          entities,
        ),
      ];
    }
    final parts = <_CadPaintPart>[];
    var start = 0;
    var hasLabels = false;
    for (var i = 0; i < entities.length; i++) {
      final entity = entities[i];
      if (!(visibleLayers[entity['layer_id'] as int] ?? true)) continue;
      final kind = (entity['geometry'] as Map)['kind'];
      final label = kind == 'text' || kind == 'point';
      if (!label && hasLabels) {
        final section = entities.sublist(start, i);
        parts.add(
          _CadPaintPart(
            _buildWorldPathSet(source, visibleLayers, section),
            section,
          ),
        );
        start = i;
        hasLabels = false;
      }
      hasLabels = hasLabels || label;
    }
    if (start < entities.length) {
      final section = entities.sublist(start);
      parts.add(
        _CadPaintPart(
          _buildWorldPathSet(source, visibleLayers, section),
          section,
        ),
      );
    }
    return parts;
  }

  _CadWorldPathSet _buildWorldPathSet(
    CadDocumentModel source,
    Map<int, bool> visibleLayers,
    List<Map<String, dynamic>> entities,
  ) {
    final origin = source.bounds2D?.center ?? Offset.zero;
    final paths = <(int, double, bool, String), Path>{};
    final dashedPaths = <(int, double, bool, String), Path>{};
    final dashPeriods = <(int, double, bool, String), double>{};
    Offset localPoint(dynamic value) => _point(value) - origin;

    for (final entity in entities) {
      if (!(visibleLayers[entity['layer_id'] as int] ?? true)) continue;
      final geometry = entity['geometry'] as Map<String, dynamic>;
      if (geometry['kind'] == 'text' || geometry['kind'] == 'point') continue;
      final colorArgb = entity['color_argb'] as int;
      final strokeWidth =
          (entity['stroke_width'] as num?)?.toDouble().abs() ?? 0.0;
      final filled = entity['filled'] as bool? ?? false;
      final pattern = filled
          ? const <double>[]
          : ((entity['dash'] as List<dynamic>?) ?? const [])
                .map((value) => (value as num).toDouble())
                .toList(growable: false);
      final key = (colorArgb, strokeWidth, filled, pattern.join(','));
      final batchPath = paths.putIfAbsent(key, Path.new);
      // Dashed entities are shaped on their own so each starts its pattern.
      final path = pattern.isEmpty ? batchPath : Path();
      switch (geometry['kind']) {
        case 'line':
          final start = localPoint(geometry['start']);
          final end = localPoint(geometry['end']);
          path.moveTo(start.dx, start.dy);
          path.lineTo(end.dx, end.dy);
        case 'polyline':
          final points = geometry['points'] as List<dynamic>;
          if (points.isEmpty) continue;
          final first = localPoint(points.first);
          path.moveTo(first.dx, first.dy);
          for (final value in points.skip(1)) {
            final next = localPoint(value);
            path.lineTo(next.dx, next.dy);
          }
          if (geometry['closed'] as bool) path.close();
        case 'circle':
          final center = localPoint(geometry['center']);
          path.addOval(
            Rect.fromCircle(
              center: center,
              radius: (geometry['radius'] as num).toDouble(),
            ),
          );
        case 'arc':
          final center = localPoint(geometry['center']);
          final start = (geometry['start_angle'] as num).toDouble();
          var sweep = (geometry['end_angle'] as num).toDouble() - start;
          if (sweep <= 0) sweep += math.pi * 2;
          path.addArc(
            Rect.fromCircle(
              center: center,
              radius: (geometry['radius'] as num).toDouble(),
            ),
            start,
            sweep,
          );
      }
      if (pattern.isNotEmpty) {
        batchPath.addPath(path, Offset.zero);
        dashedPaths
            .putIfAbsent(key, Path.new)
            .addPath(cadDashPath(path, pattern), Offset.zero);
        dashPeriods[key] = pattern.fold<double>(
          0,
          (sum, value) => sum + value.abs(),
        );
      }
    }
    return _CadWorldPathSet(
      origin: origin,
      batches: paths.entries
          .map(
            (entry) => _CadWorldPathBatch(
              colorArgb: entry.key.$1,
              strokeWidth: entry.key.$2,
              filled: entry.key.$3,
              path: entry.value,
              dashedPath: dashedPaths[entry.key],
              dashPeriod: dashPeriods[entry.key] ?? 0,
            ),
          )
          .toList(growable: false),
    );
  }

  void _paintSelected2D(
    Canvas canvas,
    Map<String, dynamic> geometry,
    CadViewTransform transform, {
    required Color color,
  }) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (geometry['kind']) {
      case 'line':
        canvas.drawLine(
          transform.worldToScreen(_point(geometry['start'])),
          transform.worldToScreen(_point(geometry['end'])),
          paint,
        );
      case 'polyline':
        final points = geometry['points'] as List<dynamic>;
        if (points.isEmpty) return;
        final first = transform.worldToScreen(_point(points.first));
        final path = Path()..moveTo(first.dx, first.dy);
        for (final value in points.skip(1)) {
          final next = transform.worldToScreen(_point(value));
          path.lineTo(next.dx, next.dy);
        }
        if (geometry['closed'] as bool) path.close();
        canvas.drawPath(path, paint);
      case 'circle':
        canvas.drawCircle(
          transform.worldToScreen(_point(geometry['center'])),
          (geometry['radius'] as num).toDouble() * transform.scale,
          paint,
        );
      case 'arc':
        final center = transform.worldToScreen(_point(geometry['center']));
        final start = (geometry['start_angle'] as num).toDouble();
        var sweep = (geometry['end_angle'] as num).toDouble() - start;
        if (sweep <= 0) sweep += math.pi * 2;
        canvas.drawArc(
          Rect.fromCircle(
            center: center,
            radius: (geometry['radius'] as num).toDouble() * transform.scale,
          ),
          -start,
          -sweep,
          false,
          paint,
        );
    }
  }

  void _paint3D(Canvas canvas, Size size) {
    final visibleIds = document.visibleMeshIds;
    final visibleMeshes = document.meshes
        .where((mesh) => visibleIds.contains(mesh['id'] as int))
        .toList(growable: false);
    if (visibleMeshes.isEmpty) return;
    final transform = Cad3DViewTransform.forScene(
      document,
      size,
      zoom,
      pan,
      yaw,
      pitch,
    );
    for (final mesh in visibleMeshes) {
      final positions = _meshPositions(mesh);
      final indices = _meshIndices(mesh);
      final meshId = BigInt.from(mesh['id'] as int);
      final selected = meshId == selectedMeshId;
      final measuredFaceOrder = <int, int>{
        for (var order = 0; order < measurement3DFaces.length; order++)
          if (measurement3DFaces[order].meshId == meshId)
            measurement3DFaces[order].triangleIndex: order,
      };
      final paint = Paint()
        ..color = selected
            ? const Color(0xffffd666)
            : const Color(0xff73dfff).withValues(alpha: 0.72)
        ..strokeWidth = selected ? 1.8 : 0.8
        ..style = PaintingStyle.stroke;
      // Rendering may be stopped when the view is idle, but visible topology
      // must never be stride-sampled: dropping arbitrary triangles changes the
      // apparent model and makes selection/measurement visually misleading.
      for (var index = 0; index + 2 < indices.length; index += 3) {
        final measuredOrder = measuredFaceOrder[index ~/ 3];
        final trianglePaint = measuredOrder == null
            ? paint
            : (Paint()
                ..color = measuredOrder == 0
                    ? const Color(0xffffd666)
                    : const Color(0xff69f0ae)
                ..strokeWidth = 3
                ..style = PaintingStyle.stroke);
        final a = transform.project(positions[indices[index]]);
        final b = transform.project(positions[indices[index + 1]]);
        final c = transform.project(positions[indices[index + 2]]);
        canvas.drawLine(a, b, trianglePaint);
        canvas.drawLine(b, c, trianglePaint);
        canvas.drawLine(c, a, trianglePaint);
      }
    }

    for (final annotation in annotations.where((item) => item.is3D)) {
      final point = transform.project(
        CadPoint3(annotation.x, annotation.y, annotation.z!),
      );
      _paintAnnotation(canvas, point, annotation.value);
    }
    if (coordinateOrigin3D != null) {
      _paintCoordinateOrigin(canvas, transform.project(coordinateOrigin3D!));
    }
    final measurementPaint = Paint()
      ..color = const Color(0xff53d4ff)
      ..strokeWidth = 2;
    final screenPoints = measurement3DPoints
        .map(transform.project)
        .toList(growable: false);
    for (final point in screenPoints) {
      canvas.drawCircle(point, 5, measurementPaint);
    }
    if (measurement3DFaces.isNotEmpty) {
      for (var index = 0; index < screenPoints.length; index++) {
        canvas.drawCircle(
          screenPoints[index],
          8,
          Paint()
            ..color = index == 0
                ? const Color(0xffffd666)
                : const Color(0xff69f0ae)
            ..strokeWidth = 2
            ..style = PaintingStyle.stroke,
        );
      }
    } else if (measurement3DAngle && screenPoints.length >= 2) {
      canvas.drawLine(screenPoints[0], screenPoints[1], measurementPaint);
      if (screenPoints.length >= 3) {
        canvas.drawLine(screenPoints[0], screenPoints[2], measurementPaint);
      }
    } else if (screenPoints.length == 2) {
      canvas.drawLine(screenPoints[0], screenPoints[1], measurementPaint);
    }
    if (measurementMidpoint && screenPoints.length == 2) {
      _paintMidpointMarker(
        canvas,
        transform.project(
          cadMidpoint3D(measurement3DPoints[0], measurement3DPoints[1]),
        ),
      );
    }
  }

  void _paintAnnotation(Canvas canvas, Offset point, String value) {
    final markerPaint = Paint()
      ..color = const Color(0xffffcc00)
      ..strokeWidth = 2;
    canvas.drawCircle(point, 5, markerPaint);
    canvas.drawLine(point, point + const Offset(0, -15), markerPaint);
    final label = TextPainter(
      text: TextSpan(
        text: value,
        style: const TextStyle(
          color: Color(0xffffe58f),
          fontSize: 12,
          backgroundColor: Color(0xdd2b2410),
          fontFamily: cadDefaultFontFamily,
          fontFamilyFallback: _cadFontFallback,
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: _textDirection(value),
    )..layout(maxWidth: 180);
    label.paint(canvas, point + const Offset(8, -28));
  }

  void _paintCoordinateOrigin(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = const Color(0xffffb84d)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(point, 6, paint);
    canvas.drawLine(
      point - const Offset(12, 0),
      point + const Offset(12, 0),
      paint,
    );
    canvas.drawLine(
      point - const Offset(0, 12),
      point + const Offset(0, 12),
      paint,
    );
  }

  void _paintCoordinateXAxis(Canvas canvas, Offset origin, Offset worldAxis) {
    final screenAxis = Offset(worldAxis.dx, -worldAxis.dy);
    final length = screenAxis.distance;
    if (!length.isFinite || length == 0) return;
    final unit = screenAxis / length;
    final end = origin + unit * 34;
    final side = Offset(-unit.dy, unit.dx);
    final paint = Paint()
      ..color = const Color(0xff53d4ff)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(origin, end, paint);
    canvas.drawLine(end, end - unit * 8 + side * 4, paint);
    canvas.drawLine(end, end - unit * 8 - side * 4, paint);
    final label = TextPainter(
      text: const TextSpan(
        text: 'X',
        style: TextStyle(
          color: Color(0xff53d4ff),
          fontSize: 11,
          fontFamily: cadDefaultFontFamily,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, end + side * 4 + const Offset(2, -6));
  }

  void _paintMidpointMarker(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = const Color(0xffffd666)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(point.dx, point.dy - 6)
      ..lineTo(point.dx + 6, point.dy)
      ..lineTo(point.dx, point.dy + 6)
      ..lineTo(point.dx - 6, point.dy)
      ..close();
    canvas.drawPath(path, paint);
  }

  void _paintCentroidMarker(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = const Color(0xff73d13d)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(point, 6, paint);
    canvas.drawLine(
      point - const Offset(9, 0),
      point + const Offset(9, 0),
      paint,
    );
    canvas.drawLine(
      point - const Offset(0, 9),
      point + const Offset(0, 9),
      paint,
    );
  }

  void _paintPaged(Canvas canvas, Size size) {
    final page = Rect.fromCenter(
      center: size.center(Offset.zero) + pan,
      width: math.min(size.width * 0.72, 520) * zoom,
      height: math.min(size.height * 0.78, 680) * zoom,
    );
    canvas.drawRect(page, Paint()..color = const Color(0xfff5f5f5));
  }

  Offset _point(dynamic value) {
    final point = value as Map<String, dynamic>;
    return Offset(
      (point['x'] as num).toDouble(),
      (point['y'] as num).toDouble(),
    );
  }

  bool _geometryVisible(
    Map<String, dynamic> geometry,
    CadViewTransform transform,
    Size size,
  ) {
    final viewport = (Offset.zero & size).inflate(40);
    switch (geometry['kind']) {
      case 'point':
        return viewport.contains(
          transform.worldToScreen(_point(geometry['position'])),
        );
      case 'line':
        final first = transform.worldToScreen(_point(geometry['start']));
        final second = transform.worldToScreen(_point(geometry['end']));
        return viewport.overlaps(Rect.fromPoints(first, second).inflate(2));
      case 'polyline':
        final points = geometry['points'] as List<dynamic>;
        if (points.isEmpty) return false;
        final worldBounds = _polylineBounds[geometry] ??= _worldBoundsForPoints(
          points,
        );
        final first = transform.worldToScreen(worldBounds.topLeft);
        final second = transform.worldToScreen(worldBounds.bottomRight);
        return viewport.overlaps(Rect.fromPoints(first, second));
      case 'circle':
      case 'arc':
        final center = transform.worldToScreen(_point(geometry['center']));
        final radius = (geometry['radius'] as num).toDouble() * transform.scale;
        return viewport.overlaps(
          Rect.fromCircle(center: center, radius: radius),
        );
      case 'text':
        return viewport.overlaps(
          cadTextScreenBounds(geometry, transform).inflate(2),
        );
      default:
        return true;
    }
  }

  TextDirection _textDirection(String value) {
    return cadTextDirection(value);
  }

  Rect _worldBoundsForPoints(List<dynamic> points) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final value in points) {
      final point = _point(value);
      minX = math.min(minX, point.dx);
      minY = math.min(minY, point.dy);
      maxX = math.max(maxX, point.dx);
      maxY = math.max(maxY, point.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static _CadTextBlockLayout _textLayout(
    String value,
    Color color,
    double fontSize,
    String? fontFamily, {
    double? maxWidth,
    List<dynamic>? runs,
    bool heightIsCapHeight = true,
    Map<String, dynamic>? lineSpacing,
    bool naturalLineHeight = false,
    _CadColumnSpec? columns,
    bool cjkEmIsHeight = false,
  }) {
    final sizeBucket = (fontSize * 2).round();
    final primaryFamily = cadPrimaryFontFamily(fontFamily);
    final spacing = lineSpacing == null
        ? null
        : {
            'factor': _cadMTextSpacingFactor(lineSpacing),
            'style': lineSpacing['style'] == 'exact' ? 'exact' : 'at_least',
          };
    final key = (
      sizeBucket,
      color.toARGB32(),
      value,
      primaryFamily,
      maxWidth,
      jsonEncode(runs ?? const []),
      heightIsCapHeight,
      cadFontMetricsRevision,
      jsonEncode(spacing ?? const {}),
      naturalLineHeight,
      columns?.cacheKey ?? '',
      cjkEmIsHeight,
    );
    final existing = _textLayouts.remove(key);
    if (existing != null) {
      _textLayouts[key] = existing;
      return existing;
    }
    TextPainter shape(
      String content,
      List<dynamic>? styles, {
      bool natural = false,
    }) => TextPainter(
      text: cadTextSpan(
        content,
        color: color,
        fontSize: sizeBucket / 2,
        fontFamily: primaryFamily,
        runs: styles,
        heightIsCapHeight: heightIsCapHeight,
        naturalLineHeight: natural || naturalLineHeight,
        cjkEmIsHeight: cjkEmIsHeight,
      ),
      strutStyle: !natural && heightIsCapHeight && spacing != null
          ? cadMTextStrut(sizeBucket / 2, primaryFamily, spacing)
          : null,
      textDirection: cadTextDirection(value),
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: false,
        applyHeightToLastDescent: false,
      ),
    )..layout(maxWidth: columns?.width ?? maxWidth ?? double.infinity);
    final layout = _CadTextBlockLayout.build(
      value,
      runs,
      columns,
      shape,
      exact: heightIsCapHeight && spacing?['style'] == 'exact',
    );
    _textLayouts[key] = layout;
    _cachedTextParagraphs += layout.columns.length;
    while (_textLayouts.length > 1 &&
        (_textLayouts.length > 512 || _cachedTextParagraphs > 2048)) {
      final removed = _textLayouts.remove(_textLayouts.keys.first)!;
      _cachedTextParagraphs -= removed.columns.length;
      removed.dispose();
    }
    return layout;
  }

  @override
  bool shouldRepaint(covariant CadScenePainter oldDelegate) =>
      oldDelegate.document != document ||
      oldDelegate.showGrid != showGrid ||
      oldDelegate.zoom != zoom ||
      oldDelegate.pan != pan ||
      !listEquals(oldDelegate.annotations, annotations) ||
      oldDelegate.selectedEntityId != selectedEntityId ||
      !setEquals(oldDelegate.selectedEntityIds, selectedEntityIds) ||
      !setEquals(oldDelegate.subtractedEntityIds, subtractedEntityIds) ||
      !listEquals(oldDelegate.measurementPoints, measurementPoints) ||
      !listEquals(
        oldDelegate.measurementIntersectionPoints,
        measurementIntersectionPoints,
      ) ||
      !listEquals(
        oldDelegate.indexedMeasurementPoints,
        indexedMeasurementPoints,
      ) ||
      oldDelegate.measurementCentroid != measurementCentroid ||
      oldDelegate.measurementClosed != measurementClosed ||
      oldDelegate.measurementRectangle != measurementRectangle ||
      oldDelegate.measurementOrientedRectangle !=
          measurementOrientedRectangle ||
      oldDelegate.measurementCircle3Point != measurementCircle3Point ||
      oldDelegate.measurementArc3Point != measurementArc3Point ||
      oldDelegate.measurementPointLineOffset != measurementPointLineOffset ||
      oldDelegate.measurementLineIntersection != measurementLineIntersection ||
      oldDelegate.measurementParallelLineSpacing !=
          measurementParallelLineSpacing ||
      oldDelegate.measurementSegmentClearance != measurementSegmentClearance ||
      oldDelegate.measurementMidpoint != measurementMidpoint ||
      oldDelegate.measurementAngle != measurementAngle ||
      oldDelegate.yaw != yaw ||
      oldDelegate.pitch != pitch ||
      oldDelegate.selectedMeshId != selectedMeshId ||
      !listEquals(oldDelegate.measurement3DPoints, measurement3DPoints) ||
      !listEquals(oldDelegate.measurement3DFaces, measurement3DFaces) ||
      oldDelegate.measurement3DAngle != measurement3DAngle ||
      oldDelegate.coordinateOrigin2D != coordinateOrigin2D ||
      oldDelegate.coordinateXAxis2D != coordinateXAxis2D ||
      oldDelegate.coordinateOrigin3D != coordinateOrigin3D;
}

// The block owns its paragraphs. Keeping children in the same LRU as other
// documents would allow eviction/disposal of a column before it is painted.
typedef _CadParagraphFactory = TextPainter Function(
  String value,
  List<dynamic>? runs, {
  bool natural,
});

class _CadColumnSpec {
  const _CadColumnSpec(
    this.count,
    this.width,
    this.gutter,
    this.heights,
    this.reversed,
    this.breaks,
  );
  final int count;
  final double width;
  final double gutter;
  final List<double> heights;
  final bool reversed;
  final List<int> breaks;
  String get cacheKey =>
      jsonEncode([count, width, gutter, heights, reversed, breaks]);
}

_CadColumnSpec? _cadTextColumns(
  Map<String, dynamic> geometry,
  double fontSize,
) {
  final raw = geometry['columns'];
  final height = (geometry['height'] as num).toDouble().abs();
  if (raw is! Map || !height.isFinite || height <= 0) return null;
  final count = raw['count'];
  final width = raw['width'];
  final gutter = raw['gutter'];
  final defined = raw['defined_height'];
  final heights = raw['heights'];
  final breaks = raw['manual_breaks'];
  if (count is! int ||
      count < 1 ||
      count > 4096 ||
      width is! num ||
      !width.isFinite ||
      width <= 0 ||
      gutter is! num ||
      !gutter.isFinite ||
      gutter < 0 ||
      defined is! num ||
      !defined.isFinite ||
      defined < 0 ||
      heights is! List ||
      breaks is! List ||
      breaks.length >= count ||
      (heights.isNotEmpty && heights.length != count)) {
    return null;
  }
  final vertical = ((fontSize * 2).round() / 2) / height;
  final horizontal = vertical / _cadTextWidthFactor(geometry);
  final columnHeights = <double>[];
  for (var i = 0; i < count; i++) {
    final h = heights.isEmpty ? defined : heights[i];
    if (h is! num ||
        !h.isFinite ||
        h < 0 ||
        (h == 0 && (heights.isEmpty || i + 1 != count))) {
      return null;
    }
    final shaped = h * vertical;
    if (!shaped.isFinite) return null;
    columnHeights.add(shaped);
  }
  final value = geometry['value'] as String? ?? '';
  final manualBreaks = <int>[];
  for (final index in breaks) {
    if (index is! int ||
        index < 0 ||
        index >= value.length ||
        value.codeUnitAt(index) != 10 ||
        (manualBreaks.isNotEmpty && index <= manualBreaks.last)) {
      return null;
    }
    manualBreaks.add(index);
  }
  final shapedWidth = width * horizontal;
  final shapedGutter = gutter * horizontal;
  if (!shapedWidth.isFinite ||
      shapedWidth <= 0 ||
      !shapedGutter.isFinite ||
      !(shapedWidth * count + shapedGutter * (count - 1)).isFinite) {
    return null;
  }
  return _CadColumnSpec(
    count,
    shapedWidth,
    shapedGutter,
    columnHeights,
    raw['flow_reversed'] == true,
    manualBreaks,
  );
}

class _CadTextColumn {
  const _CadTextColumn(
    this.paragraph,
    this.offset,
    this.box,
    this.start,
    this.end,
    this.runs,
  );
  final TextPainter paragraph;
  final Offset offset;
  final Rect box;
  final int start;
  final int end;
  final List<dynamic>? runs;
}

class _CadFlowLine {
  const _CadFlowLine(this.start, this.end, this.metric, this.breakAfter);
  final int start;
  final int end;
  final ui.LineMetrics metric;
  final bool breakAfter;
}

List<dynamic>? _cadSliceTextRuns(List<dynamic>? runs, int start, int end) {
  if (runs == null) return null;
  final result = <dynamic>[];
  for (final raw in runs) {
    if (raw is! Map ||
        raw['start'] is! int ||
        raw['end'] is! int ||
        raw['style'] is! Map) {
      return null;
    }
    final a = math.max(start, raw['start'] as int);
    final b = math.min(end, raw['end'] as int);
    if (b > a) {
      result.add({'start': a - start, 'end': b - start, 'style': raw['style']});
    }
  }
  return result;
}

class _CadTextBlockLayout {
  _CadTextBlockLayout(this.columns, this.width, this.height, this.glyphBounds);
  final List<_CadTextColumn> columns;
  final double width;
  final double height;
  final Rect glyphBounds;
  Iterable<Rect> get boxes => columns.map((column) => column.box);

  static _CadTextBlockLayout build(
    String value,
    List<dynamic>? runs,
    _CadColumnSpec? spec,
    _CadParagraphFactory shape, {
    required bool exact,
  }) {
    final parts = <_CadTextColumn>[];
    if (spec == null) {
      final paragraph = shape(value, runs);
      parts.add(
        _CadTextColumn(
          paragraph,
          Offset.zero,
          Rect.fromLTWH(0, 0, paragraph.width, paragraph.height),
          0,
          value.length,
          runs,
        ),
      );
    } else {
      // Shape each explicit-break segment exactly once, then walk the shaper's
      // UTF-16 line boundaries. Never estimate wrapping from scalar counts.
      final lines = <_CadFlowLine>[];
      var segmentStart = 0;
      for (final segmentEnd in [...spec.breaks, value.length]) {
        final content = value.substring(segmentStart, segmentEnd);
        final paragraph = shape(
          content,
          _cadSliceTextRuns(runs, segmentStart, segmentEnd),
        );
        try {
          final metrics = paragraph.computeLineMetrics();
          var cursor = 0;
          for (var i = 0; i < metrics.length; i++) {
            final boundary = paragraph.getLineBoundary(
              TextPosition(offset: cursor, affinity: TextAffinity.downstream),
            );
            final end = boundary.end.clamp(cursor, content.length);
            lines.add(
              _CadFlowLine(
                segmentStart + cursor,
                segmentStart + end,
                metrics[i],
                i + 1 == metrics.length && segmentEnd < value.length,
              ),
            );
            cursor = end < content.length && content.codeUnitAt(end) == 10
                ? end + 1
                : end;
          }
        } finally {
          paragraph.dispose();
        }
        segmentStart = segmentEnd + 1;
      }
      var row = 0;
      for (var column = 0; column < spec.count; column++) {
        final first = row;
        final capacity = spec.heights[column];
        final lastColumn = column + 1 == spec.count;
        while (row < lines.length) {
          final line = lines[row];
          final firstLine = lines[first];
          final bottom =
              line.metric.baseline +
              line.metric.descent -
              (firstLine.metric.baseline - firstLine.metric.ascent);
          // Keep at least one row even when a tall run exceeds the declared
          // height. The last column retains overflow; no label is discarded.
          if (!lastColumn &&
              capacity > 0 &&
              row > first &&
              bottom > capacity + 1e-6) {
            break;
          }
          row++;
          if (line.breakAfter && !lastColumn) break;
        }
        final start = first < lines.length ? lines[first].start : value.length;
        final end = row > first ? lines[row - 1].end : start;
        final styles = _cadSliceTextRuns(runs, start, end);
        final paragraph = shape(value.substring(start, end), styles);
        final position = spec.reversed ? spec.count - 1 - column : column;
        final offset = Offset(position * (spec.width + spec.gutter), 0);
        parts.add(
          _CadTextColumn(
            paragraph,
            offset,
            Rect.fromLTWH(
              offset.dx,
              0,
              spec.width,
              math.max(capacity, paragraph.height),
            ),
            start,
            end,
            styles,
          ),
        );
      }
    }
    final width = spec == null
        ? parts.first.paragraph.width
        : spec.width * spec.count + spec.gutter * (spec.count - 1);
    final height = parts.fold(
      0.0,
      (maximum, part) => math.max(maximum, part.box.height),
    );
    var bounds = Rect.fromLTWH(0, 0, width, height);
    for (final part in parts) {
      bounds = bounds.expandToInclude(
        Rect.fromLTWH(
          part.offset.dx,
          part.offset.dy,
          part.paragraph.width,
          part.paragraph.height,
        ),
      );
      if (!exact) continue;
      // Compute tall-run ink envelopes on these SAME source ranges. Relaying
      // out a whole natural-height block could repartition it into other columns.
      final natural = shape(
        value.substring(part.start, part.end),
        part.runs,
        natural: true,
      );
      try {
        final forced = part.paragraph.computeLineMetrics();
        final ink = natural.computeLineMetrics();
        for (var i = 0; i < math.min(forced.length, ink.length); i++) {
          bounds = bounds.expandToInclude(
            Rect.fromLTRB(
              part.offset.dx,
              forced[i].baseline - ink[i].ascent,
              part.offset.dx + math.max(part.paragraph.width, ink[i].width),
              forced[i].baseline + ink[i].descent,
            ),
          );
        }
      } finally {
        natural.dispose();
      }
    }
    return _CadTextBlockLayout(parts, width, height, bounds);
  }

  void paint(Canvas canvas, Offset offset) {
    for (final column in columns) {
      column.paragraph.paint(canvas, offset + column.offset);
    }
  }

  double computeDistanceToActualBaseline(TextBaseline baseline) =>
      columns.first.paragraph.computeDistanceToActualBaseline(baseline);
  List<ui.LineMetrics> computeLineMetrics() => columns
      .expand((column) => column.paragraph.computeLineMetrics())
      .toList();
  void dispose() {
    for (final column in columns) {
      column.paragraph.dispose();
    }
  }
}

/// Source ranges and local boxes from the very same cached layout as paint.
/// Boxes use drawing units in the text's unrotated, unmirrored local frame.
@visibleForTesting
List<({String text, int start, int end, Rect box, List<dynamic>? runs})>
cadTextColumnLayout(Map<String, dynamic> geometry) {
  final value = geometry['value'] as String;
  final layout = CadScenePainter._textLayout(
    value,
    Colors.white,
    _cadTextShapeSize,
    cadShxTextOptions(geometry).family,
    maxWidth: _cadTextWrapWidth(geometry, _cadTextShapeSize),
    runs: geometry['text_runs'] as List<dynamic>?,
    heightIsCapHeight: geometry['height_reference'] != 'em',
    lineSpacing: geometry['line_spacing'] as Map<String, dynamic>?,
    columns: _cadTextColumns(geometry, _cadTextShapeSize),
    cjkEmIsHeight: cadShxTextOptions(geometry).cjkEmIsHeight,
  );
  final scale =
      (geometry['height'] as num).toDouble().abs() / _cadTextShapeSize;
  final widthScale = scale * _cadTextWidthFactor(geometry);
  return layout.columns
      .map(
        (column) => (
          text: value.substring(column.start, column.end),
          start: column.start,
          end: column.end,
          box: Rect.fromLTRB(
            column.box.left * widthScale,
            column.box.top * scale,
            column.box.right * widthScale,
            column.box.bottom * scale,
          ),
          runs: column.runs,
        ),
      )
      .toList();
}

double _cadTextWidthFactor(Map<String, dynamic> geometry) {
  final factor = (geometry['width_factor'] as num?)?.toDouble().abs() ?? 1;
  return factor.isFinite && factor > 0 ? factor : 1;
}

double? _cadTextWrapWidth(Map<String, dynamic> geometry, double fontSize) {
  final width = (geometry['wrap_width'] as num?)?.toDouble();
  final height = (geometry['height'] as num).toDouble().abs();
  if (width == null ||
      !width.isFinite ||
      width <= 0 ||
      !height.isFinite ||
      height <= 0) {
    return null;
  }
  // Shape at a bounded font size, then scale the result back to exact CAD
  // dimensions. Width is quantized with the font bucket, not with the camera.
  return width /
      height *
      ((fontSize * 2).round() / 2) /
      _cadTextWidthFactor(geometry);
}

(double, double) _cadTextScales(
  Map<String, dynamic> geometry,
  _CadTextBlockLayout layout,
  double screenHeight,
  double cameraScale,
  double fontSize,
) {
  final widthFactor = _cadTextWidthFactor(geometry);
  final shapeSize = (fontSize * 2).round() / 2;
  var vertical = screenHeight / shapeSize;
  var horizontal = widthFactor * vertical;
  final target = (geometry['target_width'] as num?)?.toDouble();
  if (target != null && target.isFinite && target > 0 && layout.width > 0) {
    horizontal = target * cameraScale / layout.width;
    if (geometry['uniform_fit'] == true) vertical = horizontal / widthFactor;
  }
  return (
    horizontal * (geometry['mirrored_x'] == true ? -1 : 1),
    vertical * (geometry['mirrored_y'] == true ? -1 : 1),
  );
}

/// Build a shaped paragraph without losing scoped MTEXT font/decorations.
/// UTF-16 offsets are validated before slicing so supplementary glyphs cannot
/// be broken by an invalid style packet.
@visibleForTesting
TextSpan cadTextSpan(
  String value, {
  required Color color,
  required double fontSize,
  String? fontFamily,
  List<dynamic>? runs,
  bool heightIsCapHeight = true,
  bool naturalLineHeight = false,
  bool cjkEmIsHeight = false,
}) {
  double emSize(String? family, double factor) =>
      fontSize * factor / (heightIsCapHeight ? cadFontCapRatio(family) : 1);
  final splitCjk = cjkEmIsHeight && heightIsCapHeight;
  // SHX big fonts draw CJK in a square cell whose height is the text height:
  // the CJK em is the height itself, not derived from the Latin cap height.
  List<InlineSpan> segments(String text, double factor) {
    if (!splitCjk) return [TextSpan(text: text)];
    final output = <InlineSpan>[];
    final buffer = StringBuffer();
    bool? cjk;
    void flush() {
      if (buffer.isEmpty) return;
      output.add(
        TextSpan(
          text: buffer.toString(),
          style: cjk == true ? TextStyle(fontSize: fontSize * factor) : null,
        ),
      );
      buffer.clear();
    }

    for (final rune in text.runes) {
      final isCjk = _cadIsCjkRune(rune);
      if (cjk != null && isCjk != cjk) flush();
      cjk = isCjk;
      buffer.writeCharCode(rune);
    }
    flush();
    return output;
  }

  final baseStyle = TextStyle(
    color: color,
    fontFamily: cadPrimaryFontFamily(fontFamily),
    fontFamilyFallback: _cadFontFallback,
    fontSize: emSize(fontFamily, 1),
    height: naturalLineHeight ? null : 1,
  );
  TextSpan plain() => splitCjk
      ? TextSpan(style: baseStyle, children: segments(value, 1))
      : TextSpan(text: value, style: baseStyle);
  if (runs == null || runs.isEmpty) return plain();
  bool boundary(int index) =>
      index <= 0 ||
      index >= value.length ||
      !(value.codeUnitAt(index) >= 0xdc00 &&
          value.codeUnitAt(index) <= 0xdfff &&
          value.codeUnitAt(index - 1) >= 0xd800 &&
          value.codeUnitAt(index - 1) <= 0xdbff);
  final children = <InlineSpan>[];
  var cursor = 0;
  for (final raw in runs) {
    if (raw is! Map) return plain();
    final start = raw['start'];
    final end = raw['end'];
    final style = raw['style'];
    if (start is! int ||
        end is! int ||
        style is! Map ||
        start < cursor ||
        end <= start ||
        end > value.length ||
        !boundary(start) ||
        !boundary(end)) {
      return plain();
    }
    final factor = style['height_factor'] as num? ?? 1;
    if (!factor.isFinite || factor <= 0 || factor > 1024) return plain();
    if (start > cursor) {
      children.addAll(segments(value.substring(cursor, start), 1));
    }
    final decorations = <TextDecoration>[
      if (style['underline'] == true) TextDecoration.underline,
      if (style['overline'] == true) TextDecoration.overline,
      if (style['strike_through'] == true) TextDecoration.lineThrough,
    ];
    children.add(
      TextSpan(
        text: splitCjk ? null : value.substring(start, end),
        children: splitCjk
            ? segments(value.substring(start, end), factor.toDouble())
            : null,
        style: TextStyle(
          fontFamily: cadPrimaryFontFamily(
            style['font_family'] as String? ?? fontFamily,
          ),
          // The engine replaces its font-family list when an inline family is
          // pushed; the root's fallback list is not automatically retained.
          // Keep every run offline, including scripts absent from that family.
          fontFamilyFallback: _cadFontFallback,
          fontSize: emSize(
            style['font_family'] as String? ?? fontFamily,
            factor.toDouble(),
          ),
          fontWeight: style['bold'] == true
              ? FontWeight.bold
              : FontWeight.normal,
          fontStyle: style['italic'] == true
              ? FontStyle.italic
              : FontStyle.normal,
          decoration: decorations.isEmpty
              ? TextDecoration.none
              : TextDecoration.combine(decorations),
        ),
      ),
    );
    cursor = end;
  }
  if (cursor < value.length) {
    children.addAll(segments(value.substring(cursor), 1));
  }
  return TextSpan(style: baseStyle, children: children);
}

/// CJK ideographs, kana, Hangul and full-width forms, which SHX big fonts
/// (not the primary font) draw.
bool _cadIsCjkRune(int rune) =>
    (rune >= 0x1100 && rune <= 0x11ff) ||
    (rune >= 0x2e80 && rune <= 0x9fff) ||
    (rune >= 0xa960 && rune <= 0xa97f) ||
    (rune >= 0xac00 && rune <= 0xd7af) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0xfe30 && rune <= 0xfe4f) ||
    (rune >= 0xff00 && rune <= 0xffef) ||
    (rune >= 0x20000 && rune <= 0x3ffff);

double _cadMTextSpacingFactor(Map<String, dynamic> spacing) {
  final raw = spacing['factor'];
  return raw is num && raw.isFinite && raw >= 0.25 && raw <= 4
      ? raw.toDouble()
      : 1.0;
}

/// CAD's nominal baseline spacing is 5/3 of capital height, not em height.
/// AtLeast retains taller line metrics; Exact deliberately locks the grid.
@visibleForTesting
StrutStyle cadMTextStrut(
  double capHeight,
  String? family,
  Map<String, dynamic> spacing,
) {
  final factor = _cadMTextSpacingFactor(spacing);
  final ratio = cadFontCapRatio(family);
  return StrutStyle(
    fontFamily: cadPrimaryFontFamily(family),
    fontFamilyFallback: _cadFontFallback,
    fontSize: capHeight / ratio,
    height: (5 / 3) * ratio * factor,
    leading: 0,
    forceStrutHeight: spacing['style'] == 'exact',
  );
}

@visibleForTesting
List<double> cadTextLineBaselines(Map<String, dynamic> geometry) {
  final layout = CadScenePainter._textLayout(
    geometry['value'] as String,
    Colors.white,
    _cadTextShapeSize,
    cadShxTextOptions(geometry).family,
    maxWidth: _cadTextWrapWidth(geometry, _cadTextShapeSize),
    runs: geometry['text_runs'] as List<dynamic>?,
    heightIsCapHeight: geometry['height_reference'] != 'em',
    lineSpacing: geometry['line_spacing'] as Map<String, dynamic>?,
    columns: _cadTextColumns(geometry, _cadTextShapeSize),
    cjkEmIsHeight: cadShxTextOptions(geometry).cjkEmIsHeight,
  );
  final (_, vertical) = _cadTextScales(
    geometry,
    layout,
    (geometry['height'] as num).toDouble().abs(),
    1,
    _cadTextShapeSize,
  );
  return layout
      .computeLineMetrics()
      .map((line) => line.baseline * vertical.abs())
      .toList();
}

/// Conservative screen bounds for CAD text. Visibility must be based on the
/// rendered rectangle, not only on the insertion point: centered/right-aligned
/// labels can remain visibly on-screen after their origin has moved outside.
@visibleForTesting
Rect cadTextBackgroundRect(Map<String, dynamic> geometry, Rect content) {
  final background = geometry['background'] as Map?;
  if (background == null || background['layout_supported'] == false) {
    return content;
  }
  final factor = (background['scale'] as num?)?.toDouble() ?? 1.5;
  final scale = factor.isFinite && factor >= 1 && factor <= 5 ? factor : 1.5;
  final margin = _cadTextShapeSize * (scale - 1);
  // Global width scaling belongs to glyphs. The source border margin is based
  // on nominal height and must not shrink with a condensed font style.
  final horizontalMargin = margin / _cadTextWidthFactor(geometry);
  return Rect.fromLTRB(
    content.left - horizontalMargin,
    content.top - margin,
    content.right + horizontalMargin,
    content.bottom + margin,
  );
}

@visibleForTesting
Rect cadTextScreenBounds(
  Map<String, dynamic> geometry,
  CadViewTransform transform,
) {
  final originMap = geometry['origin'] as Map<String, dynamic>;
  final worldOrigin = Offset(
    (originMap['x'] as num).toDouble(),
    (originMap['y'] as num).toDouble(),
  );
  final height = (geometry['height'] as num).toDouble().abs();
  final value = geometry['value'] as String? ?? '';
  const fontSize = _cadTextShapeSize;
  final layout = CadScenePainter._textLayout(
    value,
    Colors.white,
    fontSize,
    cadShxTextOptions(geometry).family,
    maxWidth: _cadTextWrapWidth(geometry, fontSize),
    runs: geometry['text_runs'] as List<dynamic>?,
    heightIsCapHeight: geometry['height_reference'] != 'em',
    lineSpacing: geometry['line_spacing'] as Map<String, dynamic>?,
    columns: _cadTextColumns(geometry, fontSize),
    cjkEmIsHeight: cadShxTextOptions(geometry).cjkEmIsHeight,
  );
  final (horizontalScale, verticalScale) = _cadTextScales(
    geometry,
    layout,
    height * transform.scale,
    transform.scale,
    fontSize,
  );
  final horizontal = geometry['horizontal_alignment'] as String? ?? 'left';
  final vertical = geometry['vertical_alignment'] as String? ?? 'baseline';
  final left = switch (horizontal) {
    'center' => -layout.width * 0.5,
    'right' => -layout.width,
    _ => 0.0,
  };
  final top = switch (vertical) {
    'middle' => -layout.height * 0.5,
    'top' => 0.0,
    'bottom' => -layout.height,
    _ => -layout.computeDistanceToActualBaseline(TextBaseline.alphabetic),
  };
  // Paragraph layout is shared with painting. Include glyph overhang and
  // combining accents, rather than estimating a single line from rune count.
  final runs = geometry['text_runs'] as List<dynamic>? ?? const [];
  final capHeight = geometry['height_reference'] != 'em';
  var largestHeight = capHeight
      ? 1 / cadFontCapRatio(geometry['font_family'] as String?)
      : 1.0;
  for (final run in runs) {
    final factor = ((run as Map)['style'] as Map)['height_factor'] as num?;
    if (factor != null && factor.isFinite && factor > 0) {
      final family =
          (run['style'] as Map)['font_family'] as String? ??
          geometry['font_family'] as String?;
      largestHeight = math.max(
        largestHeight,
        factor.toDouble() / (capHeight ? cadFontCapRatio(family) : 1),
      );
    }
  }
  final padding = fontSize * largestHeight * 0.5;
  var rect = layout.glyphBounds.shift(Offset(left, top));
  if (geometry['background'] != null) {
    for (final box in layout.boxes) {
      rect = rect.expandToInclude(
        cadTextBackgroundRect(geometry, box.shift(Offset(left, top))),
      );
    }
  }
  rect = rect.inflate(padding);
  final oblique = (geometry['oblique_angle'] as num?)?.toDouble() ?? 0.0;
  final skew = oblique.isFinite ? -math.tan(oblique) : 0.0;
  final rotation = (geometry['rotation'] as num?)?.toDouble() ?? 0.0;
  final sin = math.sin(rotation);
  final cos = math.cos(rotation);
  final origin = transform.worldToScreen(worldOrigin);
  final corners =
      <Offset>[rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]
          .map((local) {
            final y = local.dy * verticalScale;
            final x = local.dx * horizontalScale + skew * y;
            final rotatedX = x * cos + y * sin;
            final rotatedY = -x * sin + y * cos;
            final plane = geometry['plane'] as Map<String, dynamic>?;
            return Offset(
              origin.dx +
                  (plane == null
                      ? rotatedX
                      : (plane['xx'] as num).toDouble() * rotatedX -
                            (plane['xy'] as num).toDouble() * rotatedY),
              origin.dy +
                  (plane == null
                      ? rotatedY
                      : -(plane['yx'] as num).toDouble() * rotatedX +
                            (plane['yy'] as num).toDouble() * rotatedY),
            );
          })
          .toList(growable: false);
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final corner in corners) {
    minX = math.min(minX, corner.dx);
    minY = math.min(minY, corner.dy);
    maxX = math.max(maxX, corner.dx);
    maxY = math.max(maxY, corner.dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// The same shaped envelope used for painting, expressed in drawing units.
/// Rust consumes this once per text entity before building the final R-tree.
Rect cadTextWorldBounds(Map<String, dynamic> geometry) {
  final screen = cadTextScreenBounds(
    geometry,
    const CadViewTransform(
      worldCenter: Offset.zero,
      screenCenter: Offset.zero,
      scale: 1,
    ),
  );
  return Rect.fromLTRB(screen.left, -screen.bottom, screen.right, -screen.top);
}
