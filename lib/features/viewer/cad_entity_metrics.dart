import 'dart:math' as math;
import 'dart:ui';

import '../../core/cad_engine.dart';

double cadStableMidpoint(double first, double second) {
  if (!first.isFinite || !second.isFinite) return double.nan;
  final sameSign = (first >= 0) == (second >= 0);
  return sameSign ? first + (second - first) / 2 : first / 2 + second / 2;
}

Offset cadMidpoint2D(Offset first, Offset second) => Offset(
  cadStableMidpoint(first.dx, second.dx),
  cadStableMidpoint(first.dy, second.dy),
);

class CadEntityMetrics2D {
  const CadEntityMetrics2D({
    required this.kind,
    this.start,
    this.end,
    this.center,
    this.position,
    this.length,
    this.radius,
    this.diameter,
    this.circumference,
    this.area,
    this.sweepDegrees,
    this.arcLength,
    this.chordLength,
    this.sagitta,
    this.sectorArea,
    this.segmentArea,
    this.vertexCount,
    this.closed,
    this.content,
    this.textHeight,
    this.bounds,
  });

  final String kind;
  final Offset? start;
  final Offset? end;
  final Offset? center;
  final Offset? position;
  final double? length;
  final double? radius;
  final double? diameter;
  final double? circumference;
  final double? area;
  final double? sweepDegrees;
  final double? arcLength;
  final double? chordLength;
  final double? sagitta;
  final double? sectorArea;
  final double? segmentArea;
  final int? vertexCount;
  final bool? closed;
  final String? content;
  final double? textHeight;
  final Rect? bounds;
}

class CadAreaMeasurement2D {
  const CadAreaMeasurement2D({
    required this.area,
    required this.perimeter,
    required this.centroid,
  });

  final double area;
  final double perimeter;
  final Offset centroid;
}

class CadPlanarShapeMetrics2D {
  const CadPlanarShapeMetrics2D({
    required this.equivalentCircleDiameter,
    required this.hydraulicRadius,
    required this.hydraulicDiameter,
    required this.compactness,
  });

  /// Diameter of a circle with the same area.
  final double equivalentCircleDiameter;

  /// A/P, commonly used as the hydraulic radius of a fully wetted section.
  final double hydraulicRadius;

  /// 4A/P, the hydraulic diameter of the same fully wetted section.
  final double hydraulicDiameter;

  /// Isoperimetric compactness 4πA/P² in (0, 1].
  final double compactness;
}

/// Derives scale-independent shape checks and useful equivalent dimensions
/// from one validated planar area and perimeter. The compactness expression is
/// evaluated as 4π(A/P)/P to avoid overflowing P² for large CAD drawings.
CadPlanarShapeMetrics2D? cadPlanarShapeMetrics2D(
  double area,
  double perimeter,
) {
  if (!area.isFinite || !perimeter.isFinite || area <= 0 || perimeter <= 0) {
    return null;
  }
  final hydraulicRadius = area / perimeter;
  final hydraulicDiameter = hydraulicRadius * 4;
  final equivalentCircleDiameter = 2 * math.sqrt(area / math.pi);
  var compactness = 4 * math.pi * hydraulicRadius / perimeter;
  if (compactness > 1 && compactness <= 1 + 1e-10) compactness = 1;
  if (!hydraulicRadius.isFinite ||
      !hydraulicDiameter.isFinite ||
      !equivalentCircleDiameter.isFinite ||
      !compactness.isFinite ||
      hydraulicRadius <= 0 ||
      hydraulicDiameter <= 0 ||
      equivalentCircleDiameter <= 0 ||
      compactness <= 0 ||
      compactness > 1) {
    return null;
  }
  return CadPlanarShapeMetrics2D(
    equivalentCircleDiameter: equivalentCircleDiameter,
    hydraulicRadius: hydraulicRadius,
    hydraulicDiameter: hydraulicDiameter,
    compactness: compactness,
  );
}

class CadSectionProperties2D {
  const CadSectionProperties2D({
    required this.area,
    required this.centroid,
    required this.centroidalMomentX,
    required this.centroidalMomentY,
    required this.centroidalProductXY,
    required this.polarMoment,
    required this.radiusOfGyrationX,
    required this.radiusOfGyrationY,
    required this.principalMomentMaximum,
    required this.principalMomentMinimum,
    required this.principalAxisMaximumDegrees,
    required this.sectionModulusXPositiveY,
    required this.sectionModulusXNegativeY,
    required this.sectionModulusYPositiveX,
    required this.sectionModulusYNegativeX,
  });

  final double area;
  final Offset centroid;

  /// Ix = integral(y^2 dA), about the centroidal X axis.
  final double centroidalMomentX;

  /// Iy = integral(x^2 dA), about the centroidal Y axis.
  final double centroidalMomentY;

  /// Ixy = integral(x*y dA), about the centroidal axes.
  final double centroidalProductXY;
  final double polarMoment;
  final double radiusOfGyrationX;
  final double radiusOfGyrationY;

  /// Larger centroidal principal second moment of area.
  final double principalMomentMaximum;

  /// Smaller centroidal principal second moment of area.
  final double principalMomentMinimum;

  /// Undirected Imax-axis direction, counter-clockwise from active +X.
  /// Null when every centroidal axis is principal (for example a circle).
  final double? principalAxisMaximumDegrees;

  /// Elastic section modulus Ix / c(+Y).
  final double sectionModulusXPositiveY;

  /// Elastic section modulus Ix / c(-Y).
  final double sectionModulusXNegativeY;

  /// Elastic section modulus Iy / c(+X).
  final double sectionModulusYPositiveX;

  /// Elastic section modulus Iy / c(-X).
  final double sectionModulusYNegativeX;
}

/// Computes centroidal section properties for a finite simple polygon.
///
/// The validated boundary is translated to its centroid before the fourth-
/// power sums are accumulated. This avoids subtracting large origin moments
/// for ordinary sections located at large CAD coordinates. Clockwise and
/// counter-clockwise boundaries produce identical physical properties.
CadSectionProperties2D? cadPolygonSectionProperties2D(
  List<Offset> source, {
  int maxValidationVertices = 4096,
}) {
  final area = simplePolygonArea2D(
    source,
    maxValidationVertices: maxValidationVertices,
  );
  final centroid = area == null ? null : _validatedPolygonCentroid2D(source);
  if (area == null || centroid == null || area <= 0 || !area.isFinite) {
    return null;
  }
  final points = List<Offset>.of(source);
  final tolerance = _centroidTolerance(points);
  if ((points.last - points.first).distanceSquared <= tolerance * tolerance) {
    points.removeLast();
  }
  if (points.length < 3) return null;

  final twiceArea = _CompensatedSum();
  final momentX = _CompensatedSum();
  final momentY = _CompensatedSum();
  final productXY = _CompensatedSum();
  for (var index = 0; index < points.length; index++) {
    final current = points[index] - centroid;
    final next = points[(index + 1) % points.length] - centroid;
    final cross = current.dx * next.dy - next.dx * current.dy;
    if (!cross.isFinite) return null;
    twiceArea.add(cross);
    momentX.add(
      (current.dy * current.dy + current.dy * next.dy + next.dy * next.dy) *
          cross,
    );
    momentY.add(
      (current.dx * current.dx + current.dx * next.dx + next.dx * next.dx) *
          cross,
    );
    productXY.add(
      (2 * current.dx * current.dy +
              current.dx * next.dy +
              next.dx * current.dy +
              2 * next.dx * next.dy) *
          cross,
    );
  }
  final orientation = twiceArea.value.sign;
  if (orientation == 0 || !orientation.isFinite) return null;
  var ix = orientation * momentX.value / 12;
  var iy = orientation * momentY.value / 12;
  final ixy = orientation * productXY.value / 24;
  if (![ix, iy, ixy].every((value) => value.isFinite)) return null;
  final momentScale = math.max(math.max(ix.abs(), iy.abs()), ixy.abs());
  final momentTolerance = momentScale * 1e-12;
  if (ix < 0 && ix.abs() <= momentTolerance) ix = 0;
  if (iy < 0 && iy.abs() <= momentTolerance) iy = 0;
  final normalizedIxy = ixy.abs() <= momentTolerance ? 0.0 : ixy;
  final polar = ix + iy;
  final radiusX = math.sqrt(ix / area);
  final radiusY = math.sqrt(iy / area);
  final principal = _principalSectionProperties2D(
    ix,
    iy,
    normalizedIxy,
    momentTolerance,
  );
  final sectionModuli = _axisSectionModuli2D(points, centroid, ix, iy);
  if (![
        ix,
        iy,
        normalizedIxy,
        polar,
        radiusX,
        radiusY,
      ].every((value) => value.isFinite) ||
      ix <= 0 ||
      iy <= 0 ||
      polar <= 0 ||
      principal == null ||
      sectionModuli == null) {
    return null;
  }
  return CadSectionProperties2D(
    area: area,
    centroid: centroid,
    centroidalMomentX: ix,
    centroidalMomentY: iy,
    centroidalProductXY: normalizedIxy,
    polarMoment: polar,
    radiusOfGyrationX: radiusX,
    radiusOfGyrationY: radiusY,
    principalMomentMaximum: principal.maximum,
    principalMomentMinimum: principal.minimum,
    principalAxisMaximumDegrees: principal.maximumAxisDegrees,
    sectionModulusXPositiveY: sectionModuli.xPositiveY,
    sectionModulusXNegativeY: sectionModuli.xNegativeY,
    sectionModulusYPositiveX: sectionModuli.yPositiveX,
    sectionModulusYNegativeX: sectionModuli.yNegativeX,
  );
}

CadSectionProperties2D? cadCircleSectionProperties2D(
  Offset center,
  double radius,
) {
  if (!_finitePoint(center) || !radius.isFinite || radius <= 0) return null;
  final radiusSquared = radius * radius;
  final area = math.pi * radiusSquared;
  final moment = math.pi * radiusSquared * radiusSquared / 4;
  final polar = moment * 2;
  final radiusOfGyration = radius / 2;
  final sectionModulus = moment / radius;
  if (![
    area,
    moment,
    polar,
    radiusOfGyration,
    sectionModulus,
  ].every((value) => value.isFinite && value > 0)) {
    return null;
  }
  return CadSectionProperties2D(
    area: area,
    centroid: center,
    centroidalMomentX: moment,
    centroidalMomentY: moment,
    centroidalProductXY: 0,
    polarMoment: polar,
    radiusOfGyrationX: radiusOfGyration,
    radiusOfGyrationY: radiusOfGyration,
    principalMomentMaximum: moment,
    principalMomentMinimum: moment,
    principalAxisMaximumDegrees: null,
    sectionModulusXPositiveY: sectionModulus,
    sectionModulusXNegativeY: sectionModulus,
    sectionModulusYPositiveX: sectionModulus,
    sectionModulusYNegativeX: sectionModulus,
  );
}

({double xPositiveY, double xNegativeY, double yPositiveX, double yNegativeX})?
_axisSectionModuli2D(
  List<Offset> points,
  Offset centroid,
  double ix,
  double iy,
) {
  var positiveX = 0.0;
  var negativeX = 0.0;
  var positiveY = 0.0;
  var negativeY = 0.0;
  for (final point in points) {
    final delta = point - centroid;
    if (!_finitePoint(delta)) return null;
    positiveX = math.max(positiveX, delta.dx);
    negativeX = math.max(negativeX, -delta.dx);
    positiveY = math.max(positiveY, delta.dy);
    negativeY = math.max(negativeY, -delta.dy);
  }
  if ([
    positiveX,
    negativeX,
    positiveY,
    negativeY,
  ].any((value) => !value.isFinite || value <= 0)) {
    return null;
  }
  final xPositiveY = ix / positiveY;
  final xNegativeY = ix / negativeY;
  final yPositiveX = iy / positiveX;
  final yNegativeX = iy / negativeX;
  if ([
    xPositiveY,
    xNegativeY,
    yPositiveX,
    yNegativeX,
  ].any((value) => !value.isFinite || value <= 0)) {
    return null;
  }
  return (
    xPositiveY: xPositiveY,
    xNegativeY: xNegativeY,
    yPositiveX: yPositiveX,
    yNegativeX: yNegativeX,
  );
}

({double maximum, double minimum, double? maximumAxisDegrees})?
_principalSectionProperties2D(
  double ix,
  double iy,
  double ixy,
  double tolerance,
) {
  final average = ix / 2 + iy / 2;
  final halfDifference = (ix - iy) / 2;
  final radius = _stableHypot(halfDifference, ixy);
  var maximum = average + radius;
  var minimum = average - radius;
  if (minimum < 0 && minimum.abs() <= tolerance) minimum = 0;
  if (![maximum, minimum, radius].every((value) => value.isFinite) ||
      maximum <= 0 ||
      minimum <= 0) {
    return null;
  }
  if ((maximum - (ix + iy - minimum)).abs() <= tolerance) {
    // Preserve the trace exactly enough for copied engineering values.
    maximum = ix + iy - minimum;
  }
  double? direction;
  if (radius > tolerance) {
    direction = math.atan2(-ixy, halfDifference) * 90 / math.pi % 180;
    if (direction < 0) direction += 180;
    if ((180 - direction).abs() <= 1e-10) direction = 0;
  }
  return (maximum: maximum, minimum: minimum, maximumAxisDegrees: direction);
}

double _stableHypot(double first, double second) {
  final largest = math.max(first.abs(), second.abs());
  if (largest == 0) return 0;
  final normalizedFirst = first / largest;
  final normalizedSecond = second / largest;
  return largest *
      math.sqrt(
        normalizedFirst * normalizedFirst + normalizedSecond * normalizedSecond,
      );
}

class CadPrismaticVolumeMeasurement2D {
  const CadPrismaticVolumeMeasurement2D({
    required this.area,
    required this.depth,
    required this.volume,
  });

  final double area;
  final double depth;
  final double volume;
}

class CadAverageEndAreaVolumeMeasurement2D {
  const CadAverageEndAreaVolumeMeasurement2D({
    required this.firstArea,
    required this.secondArea,
    required this.intervalLength,
    required this.meanArea,
    required this.volume,
  });

  final double firstArea;
  final double secondArea;
  final double intervalLength;
  final double meanArea;
  final double volume;
}

class CadPrismoidalVolumeMeasurement2D {
  const CadPrismoidalVolumeMeasurement2D({
    required this.firstArea,
    required this.midpointArea,
    required this.secondArea,
    required this.intervalLength,
    required this.weightedMeanArea,
    required this.volume,
  });

  final double firstArea;
  final double midpointArea;
  final double secondArea;
  final double intervalLength;
  final double weightedMeanArea;
  final double volume;
}

class CadExtrudedPerimeterAreaMeasurement2D {
  const CadExtrudedPerimeterAreaMeasurement2D({
    required this.perimeter,
    required this.height,
    required this.lateralArea,
  });

  final double perimeter;
  final double height;
  final double lateralArea;
}

const int cadMaximumCoverageUnits = 1000000000;

class CadCoverageQuantityMeasurement2D {
  const CadCoverageQuantityMeasurement2D({
    required this.area,
    required this.coveragePerUnit,
    required this.wastePercent,
    required this.adjustedArea,
    required this.exactUnits,
    required this.wholeUnits,
    required this.procuredCoverageArea,
    required this.surplusArea,
  });

  final double area;
  final double coveragePerUnit;
  final double wastePercent;
  final double adjustedArea;
  final double exactUnits;
  final int wholeUnits;
  final double procuredCoverageArea;
  final double surplusArea;
}

class CadLinearQuantityMeasurement2D {
  const CadLinearQuantityMeasurement2D({
    required this.length,
    required this.lengthPerUnit,
    required this.wastePercent,
    required this.adjustedLength,
    required this.exactUnits,
    required this.wholeUnits,
    required this.procuredLength,
    required this.surplusLength,
  });

  final double length;
  final double lengthPerUnit;
  final double wastePercent;
  final double adjustedLength;
  final double exactUnits;
  final int wholeUnits;
  final double procuredLength;
  final double surplusLength;
}

class CadPlanSlopeMeasurement2D {
  const CadPlanSlopeMeasurement2D({
    required this.horizontalRun,
    required this.verticalRise,
    required this.slopeLength,
    required this.gradePercent,
    required this.slopeRatio,
    required this.slopeAngleDegrees,
  });

  /// Horizontal plan distance. This is deliberately not inferred from an
  /// already measured sloping 3D segment.
  final double horizontalRun;

  /// Non-negative vertical difference magnitude. No uphill/downhill direction
  /// is inferred from a 2D drawing.
  final double verticalRise;
  final double slopeLength;
  final double gradePercent;

  /// Horizontal distance per one unit of vertical rise. A level run is
  /// represented by positive infinity and displayed as 1:infinity.
  final double slopeRatio;
  final double slopeAngleDegrees;
}

({
  double adjustedValue,
  double exactUnits,
  int wholeUnits,
  double procuredValue,
  double surplusValue,
})?
_cadDiscreteQuantity(
  double sourceValue,
  double valuePerUnit,
  double wastePercent,
) {
  if (!sourceValue.isFinite ||
      !valuePerUnit.isFinite ||
      !wastePercent.isFinite ||
      sourceValue <= 0 ||
      valuePerUnit <= 0 ||
      wastePercent < 0 ||
      wastePercent > 100) {
    return null;
  }
  final multiplier = 1 + wastePercent / 100;
  final adjustedValue = sourceValue * multiplier;
  final exactUnits = adjustedValue / valuePerUnit;
  if (!multiplier.isFinite ||
      !adjustedValue.isFinite ||
      !exactUnits.isFinite ||
      adjustedValue <= 0 ||
      exactUnits <= 0 ||
      exactUnits > cadMaximumCoverageUnits) {
    return null;
  }
  final nearest = exactUnits.round();
  final integerTolerance = math.max(1.0, exactUnits) * 1e-12;
  final wholeUnits =
      nearest >= 1 && (exactUnits - nearest).abs() <= integerTolerance
      ? nearest
      : exactUnits.ceil();
  if (wholeUnits <= 0 || wholeUnits > cadMaximumCoverageUnits) return null;
  final procuredValue = valuePerUnit * wholeUnits;
  var surplusValue = procuredValue - adjustedValue;
  final valueTolerance =
      math.max(procuredValue.abs(), adjustedValue.abs()) * 1e-12;
  if (surplusValue.abs() <= valueTolerance) surplusValue = 0;
  if (!procuredValue.isFinite ||
      !surplusValue.isFinite ||
      procuredValue <= 0 ||
      surplusValue < 0) {
    return null;
  }
  return (
    adjustedValue: adjustedValue,
    exactUnits: exactUnits,
    wholeUnits: wholeUnits,
    procuredValue: procuredValue,
    surplusValue: surplusValue,
  );
}

/// Estimates discrete material units from a validated area.
///
/// [area] and [coveragePerUnit] must use the same square unit. A tiny floating
/// error around an exact integer is normalized before rounding up, so values
/// such as 0.3 / 0.1 do not incorrectly require a fourth unit. The whole-unit
/// limit keeps malformed inputs from producing an impractical arbitrary-size
/// integer in the mobile result view.
CadCoverageQuantityMeasurement2D? cadCoverageQuantityMeasurement2D(
  double area,
  double coveragePerUnit,
  double wastePercent,
) {
  final result = _cadDiscreteQuantity(area, coveragePerUnit, wastePercent);
  if (result == null) return null;
  return CadCoverageQuantityMeasurement2D(
    area: area,
    coveragePerUnit: coveragePerUnit,
    wastePercent: wastePercent,
    adjustedArea: result.adjustedValue,
    exactUnits: result.exactUnits,
    wholeUnits: result.wholeUnits,
    procuredCoverageArea: result.procuredValue,
    surplusArea: result.surplusValue,
  );
}

/// Estimates whole linear-material units from one validated measured length.
/// The same bounded and floating-integer-safe procurement rule used for area
/// coverage is applied, with all length values kept in one common unit.
CadLinearQuantityMeasurement2D? cadLinearQuantityMeasurement2D(
  double length,
  double lengthPerUnit,
  double wastePercent,
) {
  final result = _cadDiscreteQuantity(length, lengthPerUnit, wastePercent);
  if (result == null) return null;
  return CadLinearQuantityMeasurement2D(
    length: length,
    lengthPerUnit: lengthPerUnit,
    wastePercent: wastePercent,
    adjustedLength: result.adjustedValue,
    exactUnits: result.exactUnits,
    wholeUnits: result.wholeUnits,
    procuredLength: result.procuredValue,
    surplusLength: result.surplusValue,
  );
}

/// Derives a right-triangle slope from a measured horizontal plan distance and
/// an explicitly entered non-negative vertical difference.
///
/// The scaled hypotenuse avoids intermediate squaring overflow/underflow. The
/// function intentionally rejects a zero horizontal run and negative rises so
/// the mobile result cannot silently invent direction or treat a vertical line
/// as a plan slope.
CadPlanSlopeMeasurement2D? cadPlanSlopeMeasurement2D(
  double horizontalRun,
  double verticalRise,
) {
  if (!horizontalRun.isFinite ||
      !verticalRise.isFinite ||
      horizontalRun <= 0 ||
      verticalRise < 0) {
    return null;
  }
  final slopeLength = _stableHypot(horizontalRun, verticalRise);
  final gradePercent = verticalRise / horizontalRun * 100;
  final slopeRatio = verticalRise == 0
      ? double.infinity
      : horizontalRun / verticalRise;
  final slopeAngleDegrees =
      math.atan2(verticalRise, horizontalRun) * 180 / math.pi;
  if (!slopeLength.isFinite ||
      !gradePercent.isFinite ||
      (!slopeRatio.isFinite && slopeRatio != double.infinity) ||
      !slopeAngleDegrees.isFinite ||
      slopeLength <= 0 ||
      gradePercent < 0 ||
      slopeRatio <= 0 ||
      slopeAngleDegrees < 0 ||
      slopeAngleDegrees >= 90) {
    return null;
  }
  return CadPlanSlopeMeasurement2D(
    horizontalRun: horizontalRun,
    verticalRise: verticalRise,
    slopeLength: slopeLength,
    gradePercent: gradePercent,
    slopeRatio: slopeRatio,
    slopeAngleDegrees: slopeAngleDegrees,
  );
}

enum CadDensityUnit {
  kilogramsPerCubicMeter,
  tonnesPerCubicMeter,
  poundsPerCubicFoot,
}

class CadMaterialMassMeasurement {
  const CadMaterialMassMeasurement({
    required this.volumeCubicMeters,
    required this.densityKilogramsPerCubicMeter,
    required this.massKilograms,
    required this.massTonnes,
    required this.massPounds,
  });

  final double volumeCubicMeters;
  final double densityKilogramsPerCubicMeter;
  final double massKilograms;
  final double massTonnes;
  final double massPounds;
}

const double _cadKilogramsPerPound = 0.45359237;
const double _cadCubicMetersPerCubicFoot = 0.028316846592;

double? cadDensityKilogramsPerCubicMeter(double value, CadDensityUnit unit) {
  if (!value.isFinite || value <= 0) return null;
  final converted = switch (unit) {
    CadDensityUnit.kilogramsPerCubicMeter => value,
    CadDensityUnit.tonnesPerCubicMeter => value * 1000,
    CadDensityUnit.poundsPerCubicFoot =>
      value * _cadKilogramsPerPound / _cadCubicMetersPerCubicFoot,
  };
  return converted.isFinite && converted > 0 ? converted : null;
}

CadMaterialMassMeasurement? cadMaterialMassMeasurement(
  double volumeCubicMeters,
  double densityValue,
  CadDensityUnit densityUnit,
) {
  if (!volumeCubicMeters.isFinite || volumeCubicMeters <= 0) return null;
  final density = cadDensityKilogramsPerCubicMeter(densityValue, densityUnit);
  if (density == null) return null;
  final kilograms = volumeCubicMeters * density;
  final tonnes = kilograms / 1000;
  final pounds = kilograms / _cadKilogramsPerPound;
  if (!kilograms.isFinite ||
      !tonnes.isFinite ||
      !pounds.isFinite ||
      kilograms <= 0) {
    return null;
  }
  return CadMaterialMassMeasurement(
    volumeCubicMeters: volumeCubicMeters,
    densityKilogramsPerCubicMeter: density,
    massKilograms: kilograms,
    massTonnes: tonnes,
    massPounds: pounds,
  );
}

/// Computes a constant-depth prismatic quantity from a validated plan area.
/// Both inputs must be strictly positive; a negative net takeoff is not
/// silently converted into a plausible volume.
CadPrismaticVolumeMeasurement2D? cadPrismaticVolumeMeasurement2D(
  double area,
  double depth,
) {
  if (!area.isFinite || !depth.isFinite || area <= 0 || depth <= 0) {
    return null;
  }
  final volume = area * depth;
  if (!volume.isFinite || volume <= 0) return null;
  return CadPrismaticVolumeMeasurement2D(
    area: area,
    depth: depth,
    volume: volume,
  );
}

/// Computes volume between two end sections using the average-end-area rule:
/// V = L * (A1 + A2) / 2.
///
/// A zero end area is valid (for example at a daylight point), but negative
/// areas and non-positive section intervals are rejected. The mean is formed
/// as two half-areas so two individually finite large inputs do not overflow
/// before their average is evaluated.
CadAverageEndAreaVolumeMeasurement2D? cadAverageEndAreaVolumeMeasurement2D(
  double firstArea,
  double secondArea,
  double intervalLength,
) {
  if (!firstArea.isFinite ||
      !secondArea.isFinite ||
      !intervalLength.isFinite ||
      firstArea < 0 ||
      secondArea < 0 ||
      (firstArea == 0 && secondArea == 0) ||
      intervalLength <= 0) {
    return null;
  }
  final meanArea = firstArea / 2 + secondArea / 2;
  final volume = meanArea * intervalLength;
  if (!meanArea.isFinite || !volume.isFinite || meanArea <= 0 || volume <= 0) {
    return null;
  }
  return CadAverageEndAreaVolumeMeasurement2D(
    firstArea: firstArea,
    secondArea: secondArea,
    intervalLength: intervalLength,
    meanArea: meanArea,
    volume: volume,
  );
}

/// Computes volume between two end sections with a cross-section measured at
/// the exact midpoint of the interval:
/// V = L * (A1 + 4Am + A2) / 6.
///
/// Each section area may be zero, but not all three. The weighted mean is
/// formed from divided terms so multiplying a large finite midpoint area by
/// four cannot overflow before the final representable result is evaluated.
CadPrismoidalVolumeMeasurement2D? cadPrismoidalVolumeMeasurement2D(
  double firstArea,
  double midpointArea,
  double secondArea,
  double intervalLength,
) {
  if (!firstArea.isFinite ||
      !midpointArea.isFinite ||
      !secondArea.isFinite ||
      !intervalLength.isFinite ||
      firstArea < 0 ||
      midpointArea < 0 ||
      secondArea < 0 ||
      (firstArea == 0 && midpointArea == 0 && secondArea == 0) ||
      intervalLength <= 0) {
    return null;
  }
  final weightedMeanArea =
      firstArea / 6 + midpointArea / 3 * 2 + secondArea / 6;
  final volume = weightedMeanArea * intervalLength;
  if (!weightedMeanArea.isFinite ||
      !volume.isFinite ||
      weightedMeanArea <= 0 ||
      volume <= 0) {
    return null;
  }
  return CadPrismoidalVolumeMeasurement2D(
    firstArea: firstArea,
    midpointArea: midpointArea,
    secondArea: secondArea,
    intervalLength: intervalLength,
    weightedMeanArea: weightedMeanArea,
    volume: volume,
  );
}

/// Computes constant-height lateral area from a validated plan perimeter.
/// End caps and top/bottom faces are intentionally excluded.
CadExtrudedPerimeterAreaMeasurement2D? cadExtrudedPerimeterAreaMeasurement2D(
  double perimeter,
  double height,
) {
  if (!perimeter.isFinite ||
      !height.isFinite ||
      perimeter <= 0 ||
      height <= 0) {
    return null;
  }
  final lateralArea = perimeter * height;
  if (!lateralArea.isFinite || lateralArea <= 0) return null;
  return CadExtrudedPerimeterAreaMeasurement2D(
    perimeter: perimeter,
    height: height,
    lateralArea: lateralArea,
  );
}

const int cadMaximumBoundaryReportVertices = 200;

enum CadBoundaryVertexKind { convex, concave, straight }

class CadBoundaryEdge2D {
  const CadBoundaryEdge2D({
    required this.index,
    required this.start,
    required this.end,
    required this.length,
    required this.direction,
    required this.interiorAngleDegrees,
    required this.deflectionAngleDegrees,
    required this.vertexKind,
  });

  final int index;
  final Offset start;
  final Offset end;
  final double length;
  final CadSurveyDirection2D direction;

  /// Interior angle at [start], independent of polygon winding, in (0, 360).
  final double interiorAngleDegrees;

  /// Winding-normalized boundary deflection at [start]. Positive is convex,
  /// negative is concave and zero is a straight continuation.
  final double deflectionAngleDegrees;
  final CadBoundaryVertexKind vertexKind;
}

class CadTraverseLeg2D {
  const CadTraverseLeg2D({
    required this.index,
    required this.start,
    required this.end,
    required this.length,
    required this.direction,
  });

  final int index;
  final Offset start;
  final Offset end;
  final double length;
  final CadSurveyDirection2D direction;
}

class CadOpenTraverse2D {
  const CadOpenTraverse2D({
    required this.legs,
    required this.totalLength,
    required this.displacement,
    required this.displacementDirection,
  });

  final List<CadTraverseLeg2D> legs;
  final double totalLength;

  /// Straight-line distance from the first collected point to the last.
  /// This is deliberately not called a closure error: no known closing point
  /// is available in a plain coordinate collection.
  final double displacement;
  final CadSurveyDirection2D? displacementDirection;

  Offset get start => legs.first.start;
  Offset get end => legs.last.end;
}

class CadTraverseClosure2D {
  const CadTraverseClosure2D({
    required this.observedEndpoint,
    required this.knownEndpoint,
    required this.correction,
    required this.linearMisclosure,
    required this.relativePrecision,
    required this.correctionDirection,
  });

  final Offset observedEndpoint;
  final Offset knownEndpoint;

  /// Vector that must be applied to the observed endpoint to reach the known
  /// endpoint. Its components therefore preserve engineering signs.
  final Offset correction;
  final double linearMisclosure;

  /// Traverse length divided by linear misclosure. Exact closure is infinity.
  final double relativePrecision;
  final CadSurveyDirection2D? correctionDirection;
}

class CadBowditchPoint2D {
  const CadBowditchPoint2D({
    required this.index,
    required this.observed,
    required this.correction,
    required this.adjusted,
    required this.cumulativeLength,
  });

  final int index;
  final Offset observed;
  final Offset correction;
  final Offset adjusted;
  final double cumulativeLength;
}

class CadBowditchAdjustment2D {
  const CadBowditchAdjustment2D({required this.closure, required this.points});

  final CadTraverseClosure2D closure;
  final List<CadBowditchPoint2D> points;
}

/// Builds an ordered open-traverse report from independently collected points.
///
/// Every consecutive pair must define a finite, non-zero leg. The computation
/// does not silently add a last-to-first segment and does not claim survey
/// closure precision without an explicitly known closing coordinate.
CadOpenTraverse2D? cadOpenTraverse2D(
  List<Offset> points, {
  int maxPoints = 200,
}) {
  if (maxPoints < 2 || points.length < 2 || points.length > maxPoints) {
    return null;
  }
  if (points.any((point) => !_finitePoint(point))) return null;
  final legs = <CadTraverseLeg2D>[];
  final total = _CompensatedSum();
  for (var index = 0; index < points.length - 1; index++) {
    final start = points[index];
    final end = points[index + 1];
    final length = _stableOffsetLength(end - start);
    final direction = cadSurveyDirection2D(start, end);
    if (!length.isFinite || length <= 0 || direction == null) {
      return null;
    }
    total.add(length);
    legs.add(
      CadTraverseLeg2D(
        index: index,
        start: start,
        end: end,
        length: length,
        direction: direction,
      ),
    );
  }
  final totalLength = total.value;
  final displacement = _stableOffsetLength(points.last - points.first);
  if (!totalLength.isFinite || totalLength <= 0 || !displacement.isFinite) {
    return null;
  }
  return CadOpenTraverse2D(
    legs: List.unmodifiable(legs),
    totalLength: totalLength,
    displacement: displacement,
    displacementDirection: cadSurveyDirection2D(points.first, points.last),
  );
}

/// Checks a measured traverse against an explicitly supplied known endpoint.
///
/// This supports both a closed traverse (known endpoint equals the known start)
/// and a link traverse (a different known endpoint). It intentionally accepts
/// the expected coordinate as a separate input so an open point list is never
/// misrepresented as a closure observation.
CadTraverseClosure2D? cadTraverseClosure2D(
  CadOpenTraverse2D traverse,
  Offset knownEndpoint,
) {
  if (!_finitePoint(knownEndpoint) || traverse.legs.isEmpty) return null;
  final observed = traverse.end;
  final correction = knownEndpoint - observed;
  final linearMisclosure = _stableOffsetLength(correction);
  if (!linearMisclosure.isFinite || linearMisclosure < 0) return null;
  final relativePrecision = linearMisclosure == 0
      ? double.infinity
      : traverse.totalLength / linearMisclosure;
  if (relativePrecision.isNaN || relativePrecision <= 0) return null;
  return CadTraverseClosure2D(
    observedEndpoint: observed,
    knownEndpoint: knownEndpoint,
    correction: correction,
    linearMisclosure: linearMisclosure,
    relativePrecision: relativePrecision,
    correctionDirection: cadSurveyDirection2D(observed, knownEndpoint),
  );
}

/// Distributes a known-endpoint coordinate correction using the Bowditch
/// (compass-rule) method: each intermediate point receives the fraction of
/// ΔX/ΔY corresponding to its cumulative observed length.
///
/// The first point remains fixed and the final adjusted point is set exactly
/// to [knownEndpoint]. This function only returns a report; it never mutates
/// the source traverse or drawing geometry.
CadBowditchAdjustment2D? cadBowditchAdjustment2D(
  CadOpenTraverse2D traverse,
  Offset knownEndpoint,
) {
  final closure = cadTraverseClosure2D(traverse, knownEndpoint);
  if (closure == null || traverse.totalLength <= 0) return null;
  final points = <CadBowditchPoint2D>[
    CadBowditchPoint2D(
      index: 0,
      observed: traverse.start,
      correction: Offset.zero,
      adjusted: traverse.start,
      cumulativeLength: 0,
    ),
  ];
  final cumulative = _CompensatedSum();
  for (var index = 0; index < traverse.legs.length; index++) {
    final leg = traverse.legs[index];
    cumulative.add(leg.length);
    final isLast = index == traverse.legs.length - 1;
    final fraction = isLast ? 1.0 : cumulative.value / traverse.totalLength;
    if (!fraction.isFinite || fraction < 0 || fraction > 1) return null;
    final correction = isLast
        ? closure.correction
        : closure.correction * fraction;
    final adjusted = isLast ? knownEndpoint : leg.end + correction;
    if (!_finitePoint(correction) || !_finitePoint(adjusted)) return null;
    points.add(
      CadBowditchPoint2D(
        index: index + 1,
        observed: leg.end,
        correction: correction,
        adjusted: adjusted,
        cumulativeLength: isLast ? traverse.totalLength : cumulative.value,
      ),
    );
  }
  return CadBowditchAdjustment2D(
    closure: closure,
    points: List.unmodifiable(points),
  );
}

/// Builds a directed edge table for a valid simple closed boundary.
///
/// A repeated closing vertex is normalized away. Validation shares the area
/// tool's self-intersection and degeneracy rules, while stable translated
/// lengths preserve useful precision for small sites at large CAD origins.
List<CadBoundaryEdge2D>? cadClosedBoundaryEdges2D(
  List<Offset> source, {
  int maxVertices = cadMaximumBoundaryReportVertices,
}) {
  if (maxVertices < 3 ||
      source.length < 3 ||
      source.length > maxVertices + 1 ||
      simplePolygonArea2D(source, maxValidationVertices: maxVertices) == null) {
    return null;
  }
  final points = List<Offset>.of(source);
  final tolerance = _centroidTolerance(points);
  if ((points.last - points.first).distanceSquared <= tolerance * tolerance) {
    points.removeLast();
  }
  if (points.length < 3 || points.length > maxVertices) return null;
  final signedArea = _CompensatedSum();
  final origin = points.first;
  for (var index = 0; index < points.length; index++) {
    final current = points[index] - origin;
    final next = points[(index + 1) % points.length] - origin;
    final cross = current.dx * next.dy - current.dy * next.dx;
    if (!cross.isFinite) return null;
    signedArea.add(cross);
  }
  final orientation = signedArea.value.sign;
  if (orientation == 0 || !orientation.isFinite) return null;
  final result = <CadBoundaryEdge2D>[];
  for (var index = 0; index < points.length; index++) {
    final previous = points[(index - 1 + points.length) % points.length];
    final start = points[index];
    final end = points[(index + 1) % points.length];
    final length = _stableOffsetLength(end - start);
    final direction = cadSurveyDirection2D(start, end);
    if (!length.isFinite || length <= tolerance || direction == null) {
      return null;
    }
    final incoming = start - previous;
    final incomingLength = _stableOffsetLength(incoming);
    if (!incomingLength.isFinite || incomingLength <= tolerance) return null;
    final incomingUnit = incoming / incomingLength;
    final outgoingUnit = (end - start) / length;
    final cross =
        incomingUnit.dx * outgoingUnit.dy - incomingUnit.dy * outgoingUnit.dx;
    final dot =
        incomingUnit.dx * outgoingUnit.dx + incomingUnit.dy * outgoingUnit.dy;
    final traversalTurn = math.atan2(cross, dot) * 180 / math.pi;
    var deflection = orientation * traversalTurn;
    if (deflection.abs() <= 1e-10) deflection = 0;
    var interior = 180 - deflection;
    if (interior < 0 && interior >= -1e-10) interior = 0;
    if (interior > 360 && interior <= 360 + 1e-10) interior = 360;
    if (!deflection.isFinite ||
        !interior.isFinite ||
        interior <= 0 ||
        interior >= 360) {
      return null;
    }
    final vertexKind = deflection == 0
        ? CadBoundaryVertexKind.straight
        : deflection > 0
        ? CadBoundaryVertexKind.convex
        : CadBoundaryVertexKind.concave;
    result.add(
      CadBoundaryEdge2D(
        index: index,
        start: start,
        end: end,
        length: length,
        direction: direction,
        interiorAngleDegrees: interior,
        deflectionAngleDegrees: deflection,
        vertexKind: vertexKind,
      ),
    );
  }
  return List.unmodifiable(result);
}

class CadRectangleMeasurement2D {
  const CadRectangleMeasurement2D({
    required this.width,
    required this.height,
    required this.diagonal,
    required this.center,
    required this.area,
    required this.perimeter,
  });

  final double width;
  final double height;
  final double diagonal;
  final Offset center;
  final double area;
  final double perimeter;
}

class CadOrientedRectangleMeasurement2D {
  const CadOrientedRectangleMeasurement2D({
    required this.corners,
    required this.width,
    required this.height,
    required this.diagonal,
    required this.center,
    required this.area,
    required this.perimeter,
    required this.directionDegrees,
  });

  final List<Offset> corners;
  final double width;
  final double height;
  final double diagonal;
  final Offset center;
  final double area;
  final double perimeter;
  final double directionDegrees;
}

class CadThreePointCircleMeasurement2D {
  const CadThreePointCircleMeasurement2D({
    required this.center,
    required this.radius,
    required this.diameter,
    required this.circumference,
    required this.area,
  });

  final Offset center;
  final double radius;
  final double diameter;
  final double circumference;
  final double area;
}

class CadThreePointArcMeasurement2D {
  const CadThreePointArcMeasurement2D({
    required this.center,
    required this.radius,
    required this.diameter,
    required this.sweepRadians,
    required this.sweepDegrees,
    required this.arcLength,
    required this.chordLength,
    required this.sagitta,
    required this.sectorArea,
    required this.segmentArea,
    required this.counterClockwise,
  });

  final Offset center;
  final double radius;
  final double diameter;
  final double sweepRadians;
  final double sweepDegrees;
  final double arcLength;
  final double chordLength;
  final double sagitta;
  final double sectorArea;
  final double segmentArea;
  final bool counterClockwise;
}

class CadSimpleCircularCurve2D {
  const CadSimpleCircularCurve2D({
    required this.tangentIntersection,
    required this.tangentLength,
    required this.externalDistance,
    required this.middleOrdinate,
    required this.startTangentDirectionDegrees,
    required this.endTangentDirectionDegrees,
  });

  /// Intersection of the start and end tangent lines (PI).
  final Offset tangentIntersection;

  /// Distance PC→PI and PI→PT.
  final double tangentLength;

  /// Radial distance from the arc midpoint to PI beyond the curve.
  final double externalDistance;

  /// Mid-ordinate from the long chord to the arc midpoint.
  final double middleOrdinate;

  /// Directed travel tangent at the curve start, counter-clockwise from +X.
  final double startTangentDirectionDegrees;

  /// Directed travel tangent at the curve end, counter-clockwise from +X.
  final double endTangentDirectionDegrees;
}

class CadRadialMeasurement2D {
  const CadRadialMeasurement2D({
    required this.kind,
    required this.center,
    required this.radius,
    required this.diameter,
    this.circumference,
    this.area,
    this.sweepDegrees,
    this.arcLength,
    this.chordLength,
    this.sagitta,
    this.chordStart,
    this.chordEnd,
    this.sectorArea,
    this.segmentArea,
  });

  final String kind;
  final Offset center;
  final double radius;
  final double diameter;
  final double? circumference;
  final double? area;
  final double? sweepDegrees;
  final double? arcLength;
  final double? chordLength;
  final double? sagitta;
  final Offset? chordStart;
  final Offset? chordEnd;
  final double? sectorArea;
  final double? segmentArea;
}

enum CadRadialClearanceRelation2D { separate, tangent, overlap }

class CadRadialClearanceMeasurement2D {
  const CadRadialClearanceMeasurement2D({
    required this.first,
    required this.second,
    required this.centerDistance,
    required this.signedClearance,
    required this.directionDegrees,
    required this.relation,
  });

  final CadRadialMeasurement2D first;
  final CadRadialMeasurement2D second;
  final double centerDistance;

  /// Center distance minus the two radii. Negative values indicate that the
  /// two supporting disks overlap; zero indicates external tangency.
  final double signedClearance;

  /// Direction from the first center to the second, or null when concentric.
  final double? directionDegrees;
  final CadRadialClearanceRelation2D relation;
}

/// Measures center distance and signed edge clearance of two supporting
/// circles. Translating to the first center before taking the hypotenuse keeps
/// the result stable for drawings with very large world coordinates.
CadRadialClearanceMeasurement2D? cadRadialClearanceMeasurement2D(
  CadRadialMeasurement2D first,
  CadRadialMeasurement2D second,
) {
  if (!_finitePoint(first.center) ||
      !_finitePoint(second.center) ||
      !first.radius.isFinite ||
      !second.radius.isFinite ||
      first.radius <= 0 ||
      second.radius <= 0) {
    return null;
  }
  final delta = second.center - first.center;
  final centerDistance = _stableOffsetLength(delta);
  final radiusSum = first.radius + second.radius;
  if (!centerDistance.isFinite || !radiusSum.isFinite) return null;
  var signedClearance = centerDistance - radiusSum;
  if (!signedClearance.isFinite) return null;
  final tolerance = math.max(1.0, math.max(centerDistance, radiusSum)) * 1e-12;
  final relation = signedClearance.abs() <= tolerance
      ? CadRadialClearanceRelation2D.tangent
      : signedClearance > 0
      ? CadRadialClearanceRelation2D.separate
      : CadRadialClearanceRelation2D.overlap;
  if (relation == CadRadialClearanceRelation2D.tangent) {
    signedClearance = 0;
  }
  double? direction;
  if (centerDistance > tolerance) {
    direction = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
    if (direction < 0) direction += 360;
    if (!direction.isFinite) return null;
  }
  return CadRadialClearanceMeasurement2D(
    first: first,
    second: second,
    centerDistance: centerDistance,
    signedClearance: signedClearance,
    directionDegrees: direction,
    relation: relation,
  );
}

/// Returns complete, validated one-tap measurements for a circle or arc.
/// Incomplete geometry is rejected instead of presenting plausible but wrong
/// engineering values for a missing center or angular range.
CadRadialMeasurement2D? cadRadialEntityMeasurement2D(
  Map<String, dynamic> geometry,
) {
  final kind = geometry['kind'];
  if (kind != 'circle' && kind != 'arc') return null;
  final center = _strictPoint(geometry['center']);
  final radius = _finiteRadius(geometry['radius']);
  if (center == null || radius == null || radius <= 0) return null;
  final diameter = radius * 2;
  if (!diameter.isFinite) return null;

  if (kind == 'circle') {
    final circumference = math.pi * diameter;
    final area = math.pi * radius * radius;
    if (!circumference.isFinite || !area.isFinite) return null;
    return CadRadialMeasurement2D(
      kind: kind as String,
      center: center,
      radius: radius,
      diameter: diameter,
      circumference: circumference,
      area: area,
    );
  }

  final start = (geometry['start_angle'] as num?)?.toDouble();
  final end = (geometry['end_angle'] as num?)?.toDouble();
  if (start == null || end == null || !start.isFinite || !end.isFinite) {
    return null;
  }
  final sweep = cadArcSweepRadians(start, end);
  final sweepDegrees = sweep * 180 / math.pi;
  final arcLength = radius * sweep;
  final rawChordLength = 2 * radius * math.sin(sweep / 2).abs();
  final chordLength = rawChordLength <= radius * 1e-12 ? 0.0 : rawChordLength;
  final fullCircle = sweep == 2 * math.pi;
  final sagitta = cadArcSagitta2D(radius, sweep);
  Offset? chordStart;
  Offset? chordEnd;
  if (!fullCircle) {
    final candidateStart =
        center + Offset(math.cos(start), math.sin(start)) * radius;
    final candidateEnd = center + Offset(math.cos(end), math.sin(end)) * radius;
    if (_finitePoint(candidateStart) && _finitePoint(candidateEnd)) {
      chordStart = candidateStart;
      chordEnd = candidateEnd;
    }
  }
  final areas = _circularArcAreas2D(radius, sweep);
  if (!sweep.isFinite ||
      !sweepDegrees.isFinite ||
      !arcLength.isFinite ||
      !chordLength.isFinite ||
      (!fullCircle && sagitta == null) ||
      areas == null) {
    return null;
  }
  return CadRadialMeasurement2D(
    kind: kind as String,
    center: center,
    radius: radius,
    diameter: diameter,
    sweepDegrees: sweepDegrees,
    arcLength: arcLength,
    chordLength: chordLength,
    sagitta: sagitta,
    chordStart: chordStart,
    chordEnd: chordEnd,
    sectorArea: areas.sectorArea,
    segmentArea: areas.segmentArea,
  );
}

/// Exact source-geometry length used by entity takeoff. Only supported,
/// complete and non-zero entities are accepted.
double? cadMeasurableEntityLength2D(Map<String, dynamic> geometry) {
  final kind = geometry['kind'];
  double? length;
  switch (kind) {
    case 'line':
      final start = _strictPoint(geometry['start']);
      final end = _strictPoint(geometry['end']);
      if (start == null || end == null) return null;
      length = (end - start).distance;
    case 'polyline':
      final values = geometry['points'];
      if (values is! List || values.length < 2) return null;
      final points = <Offset>[];
      for (final value in values) {
        final point = _strictPoint(value);
        if (point == null) return null;
        points.add(point);
      }
      length = polylineLength2D(
        points,
        closed: geometry['closed'] as bool? ?? false,
      );
    case 'circle':
      length = cadRadialEntityMeasurement2D(geometry)?.circumference;
    case 'arc':
      length = cadRadialEntityMeasurement2D(geometry)?.arcLength;
    default:
      return null;
  }
  return length != null && length.isFinite && length > 0 ? length : null;
}

class CadPointLineMeasurement2D {
  const CadPointLineMeasurement2D({
    required this.foot,
    required this.perpendicularDistance,
    required this.signedOffset,
    required this.station,
    required this.directionDegrees,
  });

  final Offset foot;
  final double perpendicularDistance;
  final double signedOffset;
  final double station;
  final double directionDegrees;
}

sealed class CadStationBaseline2D {
  const CadStationBaseline2D();

  bool get closed;
}

class CadPolylineBaseline2D extends CadStationBaseline2D {
  const CadPolylineBaseline2D({required this.points, required this.closed});

  final List<Offset> points;
  @override
  final bool closed;
}

class CadArcStationBaseline2D extends CadStationBaseline2D {
  const CadArcStationBaseline2D({
    required this.center,
    required this.radius,
    required this.startAngle,
    required this.sweepRadians,
  });

  final Offset center;
  final double radius;
  final double startAngle;
  final double sweepRadians;

  @override
  bool get closed => sweepRadians == 2 * math.pi;
}

enum CadStationElementKind2D { segment, arc }

class CadPolylineStationMeasurement2D {
  const CadPolylineStationMeasurement2D({
    required this.point,
    required this.foot,
    required this.perpendicularDistance,
    required this.signedOffset,
    required this.station,
    required this.totalLength,
    required this.remainingLength,
    required this.segmentIndex,
    required this.directionDegrees,
    this.elementKind = CadStationElementKind2D.segment,
  });

  final Offset point;
  final Offset foot;
  final double perpendicularDistance;
  final double signedOffset;
  final double station;
  final double totalLength;
  final double remainingLength;
  final int segmentIndex;
  final double directionDegrees;
  final CadStationElementKind2D elementKind;
}

class CadPolylineStakeoutMeasurement2D {
  const CadPolylineStakeoutMeasurement2D({
    required this.basePoint,
    required this.targetPoint,
    required this.station,
    required this.signedOffset,
    required this.totalLength,
    required this.remainingLength,
    required this.segmentIndex,
    required this.directionDegrees,
    this.elementKind = CadStationElementKind2D.segment,
  });

  final Offset basePoint;
  final Offset targetPoint;
  final double station;
  final double signedOffset;
  final double totalLength;
  final double remainingLength;
  final int segmentIndex;
  final double directionDegrees;
  final CadStationElementKind2D elementKind;
}

const int cadMaximumPolylineDivisions = 200;

class CadPolylineDivisionMeasurement2D {
  const CadPolylineDivisionMeasurement2D({
    required this.divisions,
    required this.totalLength,
    required this.intervalLength,
    required this.divisionPoints,
  });

  final int divisions;
  final double totalLength;
  final double intervalLength;

  /// Open baselines include both endpoints (divisions + 1 points). Closed
  /// baselines include the origin once (divisions points).
  final List<Offset> divisionPoints;
}

class CadDivisionStakeoutPoint2D {
  const CadDivisionStakeoutPoint2D({
    required this.index,
    required this.station,
    required this.point,
    required this.tangentDirectionDegrees,
    required this.segmentIndex,
    required this.elementKind,
    this.cumulativeDeflectionDegrees,
    this.longChordFromStart,
  });

  final int index;
  final double station;
  final Offset point;

  /// Directed tangent, counter-clockwise from drawing +X.
  final double tangentDirectionDegrees;
  final int segmentIndex;
  final CadStationElementKind2D elementKind;

  /// Simple circular-curve deflection from the start tangent to the long chord.
  final double? cumulativeDeflectionDegrees;

  /// Straight chord from the circular-curve start to this point.
  final double? longChordFromStart;
}

class CadDivisionStakeoutReport2D {
  const CadDivisionStakeoutReport2D({
    required this.divisions,
    required this.totalLength,
    required this.intervalLength,
    required this.closed,
    required this.points,
  });

  final int divisions;
  final double totalLength;
  final double intervalLength;
  final bool closed;
  final List<CadDivisionStakeoutPoint2D> points;

  bool get hasSimpleCircularCurveValues =>
      points.isNotEmpty &&
      points.every(
        (point) =>
            point.cumulativeDeflectionDegrees != null &&
            point.longChordFromStart != null,
      );
}

class CadLineSegment2D {
  const CadLineSegment2D({
    required this.start,
    required this.end,
    required this.segmentIndex,
    required this.length,
    required this.directionDegrees,
  });

  final Offset start;
  final Offset end;
  final int segmentIndex;
  final double length;
  final double directionDegrees;
}

class CadLineIntersectionMeasurement2D {
  const CadLineIntersectionMeasurement2D({
    required this.first,
    required this.second,
    required this.intersection,
    required this.includedAngleDegrees,
    required this.firstExtensionLength,
    required this.secondExtensionLength,
  });

  final CadLineSegment2D first;
  final CadLineSegment2D second;
  final Offset intersection;
  final double includedAngleDegrees;
  final double firstExtensionLength;
  final double secondExtensionLength;

  bool get liesOnBothSegments =>
      firstExtensionLength == 0 && secondExtensionLength == 0;
}

class CadParallelLineSpacingMeasurement2D {
  const CadParallelLineSpacingMeasurement2D({
    required this.first,
    required this.second,
    required this.firstFoot,
    required this.secondFoot,
    required this.spacing,
    required this.directionDegrees,
  });

  final CadLineSegment2D first;
  final CadLineSegment2D second;
  final Offset firstFoot;
  final Offset secondFoot;
  final double spacing;

  /// Undirected baseline direction in the range [0, 180).
  final double directionDegrees;
}

class CadSegmentClearanceMeasurement2D {
  const CadSegmentClearanceMeasurement2D({
    required this.first,
    required this.second,
    required this.firstClosestPoint,
    required this.secondClosestPoint,
    required this.clearance,
  });

  final CadLineSegment2D first;
  final CadLineSegment2D second;
  final Offset firstClosestPoint;
  final Offset secondClosestPoint;
  final double clearance;

  bool get intersects => clearance == 0;
}

CadPolylineBaseline2D? cadPolylineBaselineFromGeometry(
  Map<String, dynamic> geometry,
) {
  final kind = geometry['kind'];
  final points = <Offset>[];
  var closed = false;
  if (kind == 'line') {
    final start = _strictPoint(geometry['start']);
    final end = _strictPoint(geometry['end']);
    if (start == null || end == null) return null;
    points.addAll([start, end]);
  } else if (kind == 'polyline') {
    final values = geometry['points'];
    if (values is! List || values.length < 2) return null;
    for (final value in values) {
      final point = _strictPoint(value);
      if (point == null) return null;
      points.add(point);
    }
    closed = geometry['closed'] as bool? ?? false;
  } else {
    return null;
  }
  if (cadMeasurableEntityLength2D(geometry) == null) return null;
  return CadPolylineBaseline2D(
    points: List.unmodifiable(points),
    closed: closed,
  );
}

CadArcStationBaseline2D? cadArcStationBaselineFromGeometry(
  Map<String, dynamic> geometry,
) {
  if (geometry['kind'] != 'arc') return null;
  final center = _strictPoint(geometry['center']);
  final radius = _finiteRadius(geometry['radius']);
  final start = (geometry['start_angle'] as num?)?.toDouble();
  final end = (geometry['end_angle'] as num?)?.toDouble();
  if (center == null ||
      radius == null ||
      radius <= 0 ||
      start == null ||
      end == null ||
      !start.isFinite ||
      !end.isFinite) {
    return null;
  }
  final sweep = cadArcSweepRadians(start, end);
  final totalLength = radius * sweep;
  if (!sweep.isFinite ||
      sweep <= 0 ||
      sweep > 2 * math.pi ||
      !totalLength.isFinite ||
      totalLength <= 1e-12) {
    return null;
  }
  return CadArcStationBaseline2D(
    center: center,
    radius: radius,
    startAngle: start,
    sweepRadians: sweep,
  );
}

CadStationBaseline2D? cadStationBaselineFromGeometry(
  Map<String, dynamic> geometry,
) =>
    cadPolylineBaselineFromGeometry(geometry) ??
    cadArcStationBaselineFromGeometry(geometry);

/// Projects [point] onto the nearest finite segment and reports cumulative
/// station from the first vertex. Signed offset is left-positive relative to
/// the selected segment direction. Equal-distance vertex projections choose
/// the smaller station, making corner behavior deterministic.
CadPolylineStationMeasurement2D? cadPolylineStationMeasurement2D(
  List<Offset> points,
  Offset point, {
  bool closed = false,
}) {
  if (points.length < 2 || !_finitePoint(point)) return null;
  if (points.any((item) => !_finitePoint(item))) return null;
  final segmentCount = closed ? points.length : points.length - 1;
  var accumulated = 0.0;
  double? bestDistance;
  double? bestOffset;
  double? bestStation;
  Offset? bestFoot;
  int? bestSegment;
  double? bestDirection;

  for (var index = 0; index < segmentCount; index++) {
    final start = points[index];
    final end = points[(index + 1) % points.length];
    final vector = end - start;
    final length = _stableOffsetLength(vector);
    if (!length.isFinite) return null;
    if (length <= 1e-12) continue;
    final unit = vector / length;
    final relative = point - start;
    final unclamped = relative.dx * unit.dx + relative.dy * unit.dy;
    final along = unclamped.clamp(0.0, length).toDouble();
    final foot = start + unit * along;
    final footToPoint = point - foot;
    final signedOffset = unit.dx * footToPoint.dy - unit.dy * footToPoint.dx;
    final distance = _stableOffsetLength(footToPoint);
    final station = accumulated + along;
    var direction = math.atan2(vector.dy, vector.dx) * 180 / math.pi;
    if (direction < 0) direction += 360;
    if (!_finitePoint(foot) ||
        !signedOffset.isFinite ||
        !distance.isFinite ||
        !station.isFinite ||
        !direction.isFinite) {
      return null;
    }
    final tolerance =
        math.max(1.0, math.max(distance, bestDistance ?? 0)) * 1e-12;
    if (bestDistance == null ||
        distance < bestDistance - tolerance ||
        ((distance - bestDistance).abs() <= tolerance &&
            station < (bestStation ?? double.infinity))) {
      bestDistance = distance;
      bestOffset = signedOffset;
      bestStation = station;
      bestFoot = foot;
      bestSegment = index;
      bestDirection = direction;
    }
    accumulated += length;
  }
  if (bestDistance == null ||
      bestOffset == null ||
      bestStation == null ||
      bestFoot == null ||
      bestSegment == null ||
      bestDirection == null ||
      !accumulated.isFinite ||
      accumulated <= 1e-12) {
    return null;
  }
  return CadPolylineStationMeasurement2D(
    point: point,
    foot: bestFoot,
    perpendicularDistance: bestDistance,
    signedOffset: bestOffset,
    station: bestStation,
    totalLength: accumulated,
    remainingLength: math.max(0, accumulated - bestStation),
    segmentIndex: bestSegment,
    directionDegrees: bestDirection,
  );
}

/// Locates a point from cumulative station and left-positive signed offset.
///
/// Stations are measured from the first vertex along finite segments. Closed
/// polylines include their closing segment but do not silently wrap values
/// outside [0, totalLength]. At an exact internal vertex the incoming segment
/// is selected, matching the deterministic smaller-station projection rule.
CadPolylineStakeoutMeasurement2D? cadPolylineStakeoutMeasurement2D(
  List<Offset> points,
  double station,
  double signedOffset, {
  bool closed = false,
}) {
  if (points.length < 2 ||
      points.any((point) => !_finitePoint(point)) ||
      !station.isFinite ||
      !signedOffset.isFinite ||
      station < 0) {
    return null;
  }
  final segmentCount = closed ? points.length : points.length - 1;
  final segments =
      <
        ({
          int index,
          Offset start,
          Offset unit,
          double length,
          double startStation,
          double endStation,
        })
      >[];
  var total = 0.0;
  var compensation = 0.0;
  for (var index = 0; index < segmentCount; index++) {
    final start = points[index];
    final end = points[(index + 1) % points.length];
    final vector = end - start;
    final length = _stableOffsetLength(vector);
    if (!length.isFinite) return null;
    if (length <= 1e-12) continue;
    final corrected = length - compensation;
    final updated = total + corrected;
    compensation = (updated - total) - corrected;
    if (!updated.isFinite) return null;
    segments.add((
      index: index,
      start: start,
      unit: vector / length,
      length: length,
      startStation: total,
      endStation: updated,
    ));
    total = updated;
  }
  if (segments.isEmpty || total <= 1e-12 || !total.isFinite) return null;
  final tolerance = math.max(1.0, total) * 1e-12;
  if (station > total + tolerance) return null;
  final locatedStation = station.clamp(0.0, total).toDouble();
  for (var position = 0; position < segments.length; position++) {
    final segment = segments[position];
    if (locatedStation > segment.endStation + tolerance &&
        position != segments.length - 1) {
      continue;
    }
    final along = (locatedStation - segment.startStation)
        .clamp(0.0, segment.length)
        .toDouble();
    final basePoint = segment.start + segment.unit * along;
    final leftNormal = Offset(-segment.unit.dy, segment.unit.dx);
    final targetPoint = basePoint + leftNormal * signedOffset;
    var direction =
        math.atan2(segment.unit.dy, segment.unit.dx) * 180 / math.pi;
    if (direction < 0) direction += 360;
    final remaining = math.max(0.0, total - locatedStation);
    if (!_finitePoint(basePoint) ||
        !_finitePoint(targetPoint) ||
        !direction.isFinite ||
        !remaining.isFinite) {
      return null;
    }
    return CadPolylineStakeoutMeasurement2D(
      basePoint: basePoint,
      targetPoint: targetPoint,
      station: locatedStation,
      signedOffset: signedOffset,
      totalLength: total,
      remainingLength: remaining,
      segmentIndex: segment.index,
      directionDegrees: direction,
    );
  }
  return null;
}

/// Divides a finite line/polyline into equal station intervals in linear time.
///
/// Degenerate source segments are skipped. Internal nodes that fall exactly on
/// a source vertex use that vertex, while endpoint construction avoids an
/// accumulated floating-point drift. Duplicate output nodes caused by a
/// distance below the available precision of very large coordinates are
/// rejected instead of presenting false engineering accuracy.
CadPolylineDivisionMeasurement2D? cadPolylineDivisionMeasurement2D(
  List<Offset> points,
  int divisions, {
  bool closed = false,
}) {
  if (points.length < 2 ||
      points.any((point) => !_finitePoint(point)) ||
      divisions < 2 ||
      divisions > cadMaximumPolylineDivisions) {
    return null;
  }
  final segmentCount = closed ? points.length : points.length - 1;
  final segments =
      <
        ({
          Offset start,
          Offset end,
          Offset unit,
          double length,
          double startStation,
          double endStation,
        })
      >[];
  var total = 0.0;
  var compensation = 0.0;
  for (var index = 0; index < segmentCount; index++) {
    final start = points[index];
    final end = points[(index + 1) % points.length];
    final vector = end - start;
    final length = _stableOffsetLength(vector);
    if (!length.isFinite) return null;
    if (length <= 1e-12) continue;
    final corrected = length - compensation;
    final updated = total + corrected;
    compensation = (updated - total) - corrected;
    if (!updated.isFinite) return null;
    segments.add((
      start: start,
      end: end,
      unit: vector / length,
      length: length,
      startStation: total,
      endStation: updated,
    ));
    total = updated;
  }
  if (segments.isEmpty || !total.isFinite || total <= 1e-12) return null;
  final interval = total / divisions;
  if (!interval.isFinite || interval <= 0) return null;
  final pointCount = closed ? divisions : divisions + 1;
  final result = <Offset>[];
  var segmentPosition = 0;
  for (var pointIndex = 0; pointIndex < pointCount; pointIndex++) {
    Offset point;
    if (pointIndex == 0) {
      point = segments.first.start;
    } else if (!closed && pointIndex == divisions) {
      point = segments.last.end;
    } else {
      final station = total * (pointIndex / divisions);
      while (segmentPosition < segments.length - 1 &&
          station > segments[segmentPosition].endStation) {
        segmentPosition++;
      }
      final segment = segments[segmentPosition];
      final along = (station - segment.startStation)
          .clamp(0.0, segment.length)
          .toDouble();
      point = segment.start + segment.unit * along;
    }
    if (!_finitePoint(point) || (result.isNotEmpty && point == result.last)) {
      return null;
    }
    result.add(point);
  }
  return CadPolylineDivisionMeasurement2D(
    divisions: divisions,
    totalLength: total,
    intervalLength: interval,
    divisionPoints: List.unmodifiable(result),
  );
}

double? _arcStationBaselineTotalLength(CadArcStationBaseline2D baseline) {
  if (!_finitePoint(baseline.center) ||
      !baseline.radius.isFinite ||
      baseline.radius <= 0 ||
      !baseline.startAngle.isFinite ||
      !baseline.sweepRadians.isFinite ||
      baseline.sweepRadians <= 0 ||
      baseline.sweepRadians > 2 * math.pi) {
    return null;
  }
  final total = baseline.radius * baseline.sweepRadians;
  return total.isFinite && total > 1e-12 ? total : null;
}

Offset? _arcStationPointAt(CadArcStationBaseline2D baseline, double angle) {
  if (!angle.isFinite) return null;
  final point =
      baseline.center +
      Offset(math.cos(angle), math.sin(angle)) * baseline.radius;
  return _finitePoint(point) && point != baseline.center ? point : null;
}

({Offset unit, double directionDegrees})? _arcStationTangentAt(double angle) {
  if (!angle.isFinite) return null;
  final unit = Offset(-math.sin(angle), math.cos(angle));
  var direction = math.atan2(unit.dy, unit.dx) * 180 / math.pi;
  if (direction < 0) direction += 360;
  if (!_finitePoint(unit) || !direction.isFinite) return null;
  return (unit: unit, directionDegrees: direction);
}

/// Projects a point onto a finite counter-clockwise circular-arc baseline.
/// Station starts at the CAD arc start angle. The signed offset follows the
/// tangent direction and is positive on its left side (toward the center).
/// Points outside a partial arc use the nearest endpoint, like a finite line.
CadPolylineStationMeasurement2D? cadArcStationMeasurement2D(
  CadArcStationBaseline2D baseline,
  Offset point,
) {
  final total = _arcStationBaselineTotalLength(baseline);
  if (total == null || !_finitePoint(point)) return null;
  final radial = point - baseline.center;
  final radialLength = _stableOffsetLength(radial);
  final centerTolerance = math.max(1.0, baseline.radius) * 1e-12;
  if (!radialLength.isFinite || radialLength <= centerTolerance) return null;
  final pointAngle = math.atan2(radial.dy, radial.dx);
  final delta = _positiveAngleDelta(baseline.startAngle, pointAngle);
  final angularTolerance = 1e-12;
  double station;
  double footAngle;
  if (baseline.closed || delta <= baseline.sweepRadians + angularTolerance) {
    final clampedDelta = delta.clamp(0.0, baseline.sweepRadians).toDouble();
    station = baseline.radius * clampedDelta;
    footAngle = baseline.startAngle + clampedDelta;
  } else {
    final startPoint = _arcStationPointAt(baseline, baseline.startAngle);
    final endAngle = baseline.startAngle + baseline.sweepRadians;
    final endPoint = _arcStationPointAt(baseline, endAngle);
    if (startPoint == null || endPoint == null) return null;
    final startDistance = _stableOffsetLength(point - startPoint);
    final endDistance = _stableOffsetLength(point - endPoint);
    if (!startDistance.isFinite || !endDistance.isFinite) return null;
    final tolerance =
        math.max(1.0, math.max(startDistance, endDistance)) * 1e-12;
    if (startDistance <= endDistance + tolerance) {
      station = 0;
      footAngle = baseline.startAngle;
    } else {
      station = total;
      footAngle = endAngle;
    }
  }
  final foot = _arcStationPointAt(baseline, footAngle);
  final tangent = _arcStationTangentAt(footAngle);
  if (foot == null || tangent == null) return null;
  final footToPoint = point - foot;
  final signedOffset =
      tangent.unit.dx * footToPoint.dy - tangent.unit.dy * footToPoint.dx;
  final distance = _stableOffsetLength(footToPoint);
  final remaining = math.max(0.0, total - station);
  if (!station.isFinite ||
      !signedOffset.isFinite ||
      !distance.isFinite ||
      !remaining.isFinite) {
    return null;
  }
  return CadPolylineStationMeasurement2D(
    point: point,
    foot: foot,
    perpendicularDistance: distance,
    signedOffset: signedOffset,
    station: station,
    totalLength: total,
    remainingLength: remaining,
    segmentIndex: 0,
    directionDegrees: tangent.directionDegrees,
    elementKind: CadStationElementKind2D.arc,
  );
}

CadPolylineStakeoutMeasurement2D? cadArcStationStakeoutMeasurement2D(
  CadArcStationBaseline2D baseline,
  double station,
  double signedOffset,
) {
  final total = _arcStationBaselineTotalLength(baseline);
  if (total == null ||
      !station.isFinite ||
      !signedOffset.isFinite ||
      station < 0) {
    return null;
  }
  final tolerance = math.max(1.0, total) * 1e-12;
  if (station > total + tolerance) return null;
  final locatedStation = station.clamp(0.0, total).toDouble();
  final angle = baseline.closed && locatedStation == total
      ? baseline.startAngle
      : baseline.startAngle + locatedStation / baseline.radius;
  final basePoint = _arcStationPointAt(baseline, angle);
  final tangent = _arcStationTangentAt(angle);
  if (basePoint == null || tangent == null) return null;
  final leftNormal = Offset(-tangent.unit.dy, tangent.unit.dx);
  final targetPoint = basePoint + leftNormal * signedOffset;
  final remaining = math.max(0.0, total - locatedStation);
  if (!_finitePoint(targetPoint) ||
      (signedOffset != 0 && targetPoint == basePoint) ||
      !remaining.isFinite) {
    return null;
  }
  return CadPolylineStakeoutMeasurement2D(
    basePoint: basePoint,
    targetPoint: targetPoint,
    station: locatedStation,
    signedOffset: signedOffset,
    totalLength: total,
    remainingLength: remaining,
    segmentIndex: 0,
    directionDegrees: tangent.directionDegrees,
    elementKind: CadStationElementKind2D.arc,
  );
}

CadPolylineDivisionMeasurement2D? cadArcStationDivisionMeasurement2D(
  CadArcStationBaseline2D baseline,
  int divisions,
) {
  final total = _arcStationBaselineTotalLength(baseline);
  if (total == null ||
      divisions < 2 ||
      divisions > cadMaximumPolylineDivisions) {
    return null;
  }
  final interval = total / divisions;
  if (!interval.isFinite || interval <= 0) return null;
  final pointCount = baseline.closed ? divisions : divisions + 1;
  final points = <Offset>[];
  for (var index = 0; index < pointCount; index++) {
    final fraction = index / divisions;
    final point = _arcStationPointAt(
      baseline,
      baseline.startAngle + baseline.sweepRadians * fraction,
    );
    if (point == null || (points.isNotEmpty && point == points.last)) {
      return null;
    }
    points.add(point);
  }
  return CadPolylineDivisionMeasurement2D(
    divisions: divisions,
    totalLength: total,
    intervalLength: interval,
    divisionPoints: List.unmodifiable(points),
  );
}

CadPolylineStationMeasurement2D? cadStationMeasurement2D(
  CadStationBaseline2D baseline,
  Offset point,
) => switch (baseline) {
  CadPolylineBaseline2D value => cadPolylineStationMeasurement2D(
    value.points,
    point,
    closed: value.closed,
  ),
  CadArcStationBaseline2D value => cadArcStationMeasurement2D(value, point),
};

CadPolylineStakeoutMeasurement2D? cadStationStakeoutMeasurement2D(
  CadStationBaseline2D baseline,
  double station,
  double signedOffset,
) => switch (baseline) {
  CadPolylineBaseline2D value => cadPolylineStakeoutMeasurement2D(
    value.points,
    station,
    signedOffset,
    closed: value.closed,
  ),
  CadArcStationBaseline2D value => cadArcStationStakeoutMeasurement2D(
    value,
    station,
    signedOffset,
  ),
};

CadPolylineDivisionMeasurement2D? cadStationDivisionMeasurement2D(
  CadStationBaseline2D baseline,
  int divisions,
) => switch (baseline) {
  CadPolylineBaseline2D value => cadPolylineDivisionMeasurement2D(
    value.points,
    divisions,
    closed: value.closed,
  ),
  CadArcStationBaseline2D value => cadArcStationDivisionMeasurement2D(
    value,
    divisions,
  ),
};

/// Builds a field-ready point table from an equal-station division.
///
/// Every table point is independently reconstructed through the station
/// stakeout path and checked against the division geometry. At polyline
/// vertices, the existing deterministic incoming-segment tangent is retained.
/// Cumulative deflection and start-to-point long chord are emitted only for an
/// open minor circular arc, where the simple-curve convention is unambiguous.
CadDivisionStakeoutReport2D? cadDivisionStakeoutReport2D(
  CadStationBaseline2D baseline,
  int divisions,
) {
  final division = cadStationDivisionMeasurement2D(baseline, divisions);
  if (division == null) return null;
  final rows = <CadDivisionStakeoutPoint2D>[];
  final simpleArc = switch (baseline) {
    CadArcStationBaseline2D value
        when !value.closed && value.sweepRadians < math.pi =>
      value,
    _ => null,
  };
  for (var index = 0; index < division.divisionPoints.length; index++) {
    final lastOpenPoint =
        !baseline.closed && index == division.divisionPoints.length - 1;
    final station = lastOpenPoint
        ? division.totalLength
        : division.totalLength * (index / divisions);
    final located = cadStationStakeoutMeasurement2D(baseline, station, 0);
    if (located == null) return null;
    final point = division.divisionPoints[index];
    final mismatch = _stableOffsetLength(located.basePoint - point);
    final pointScale = math.max(
      1.0,
      math.max(math.max(point.dx.abs(), point.dy.abs()), division.totalLength),
    );
    final tolerance = pointScale * 1e-10;
    if (!station.isFinite ||
        !mismatch.isFinite ||
        mismatch > tolerance ||
        !located.directionDegrees.isFinite) {
      return null;
    }
    double? deflection;
    double? longChord;
    if (simpleArc != null) {
      final centralAngle = station / simpleArc.radius;
      deflection = centralAngle * 90 / math.pi;
      longChord = 2 * simpleArc.radius * math.sin(centralAngle / 2);
      if (!deflection.isFinite ||
          !longChord.isFinite ||
          deflection < 0 ||
          longChord < 0) {
        return null;
      }
    }
    rows.add(
      CadDivisionStakeoutPoint2D(
        index: index,
        station: station,
        point: point,
        tangentDirectionDegrees: located.directionDegrees,
        segmentIndex: located.segmentIndex,
        elementKind: located.elementKind,
        cumulativeDeflectionDegrees: deflection,
        longChordFromStart: longChord,
      ),
    );
  }
  if (rows.length != division.divisionPoints.length) return null;
  return CadDivisionStakeoutReport2D(
    divisions: division.divisions,
    totalLength: division.totalLength,
    intervalLength: division.intervalLength,
    closed: baseline.closed,
    points: List.unmodifiable(rows),
  );
}

/// Selects the finite source segment closest to [point]. For polylines this
/// preserves the tapped segment instead of silently using the first edge.
CadLineSegment2D? cadNearestLineSegmentFromGeometry(
  Map<String, dynamic> geometry,
  Offset point,
) {
  if (!_finitePoint(point)) return null;
  final baseline = cadPolylineBaselineFromGeometry(geometry);
  if (baseline == null) return null;
  final points = baseline.points;
  final segmentCount = baseline.closed ? points.length : points.length - 1;
  double? bestDistance;
  CadLineSegment2D? best;
  for (var index = 0; index < segmentCount; index++) {
    final start = points[index];
    final end = points[(index + 1) % points.length];
    final vector = end - start;
    final length = _stableOffsetLength(vector);
    if (!length.isFinite) return null;
    if (length <= 1e-12) continue;
    final unit = vector / length;
    final relative = point - start;
    final along = (relative.dx * unit.dx + relative.dy * unit.dy)
        .clamp(0.0, length)
        .toDouble();
    final foot = start + unit * along;
    final distance = _stableOffsetLength(point - foot);
    if (!distance.isFinite || !_finitePoint(foot)) return null;
    final tolerance =
        math.max(1.0, math.max(distance, bestDistance ?? 0)) * 1e-12;
    if (bestDistance == null || distance < bestDistance - tolerance) {
      var direction = math.atan2(vector.dy, vector.dx) * 180 / math.pi;
      if (direction < 0) direction += 360;
      bestDistance = distance;
      best = CadLineSegment2D(
        start: start,
        end: end,
        segmentIndex: index,
        length: length,
        directionDegrees: direction,
      );
    }
  }
  return best;
}

/// Intersects the infinite extensions of two selected finite segments. Nearly
/// parallel directions are rejected because a tiny angular error would move
/// the reported engineering intersection an unbounded distance.
CadLineIntersectionMeasurement2D? cadLineIntersectionMeasurement2D(
  CadLineSegment2D first,
  CadLineSegment2D second,
) {
  if (!_finitePoint(first.start) ||
      !_finitePoint(first.end) ||
      !_finitePoint(second.start) ||
      !_finitePoint(second.end) ||
      !first.length.isFinite ||
      !second.length.isFinite ||
      first.length <= 1e-12 ||
      second.length <= 1e-12) {
    return null;
  }
  final firstVector = first.end - first.start;
  final secondVector = second.end - second.start;
  final firstLength = _stableOffsetLength(firstVector);
  final secondLength = _stableOffsetLength(secondVector);
  if (!firstLength.isFinite ||
      !secondLength.isFinite ||
      firstLength <= 1e-12 ||
      secondLength <= 1e-12) {
    return null;
  }
  final firstUnit = firstVector / firstLength;
  final secondUnit = secondVector / secondLength;
  final determinant =
      firstUnit.dx * secondUnit.dy - firstUnit.dy * secondUnit.dx;
  if (!determinant.isFinite || determinant.abs() <= 1e-10) return null;
  final delta = second.start - first.start;
  final firstAlong =
      (delta.dx * secondUnit.dy - delta.dy * secondUnit.dx) / determinant;
  final secondAlong =
      (delta.dx * firstUnit.dy - delta.dy * firstUnit.dx) / determinant;
  final intersection = first.start + firstUnit * firstAlong;
  final dot = (firstUnit.dx * secondUnit.dx + firstUnit.dy * secondUnit.dy)
      .abs()
      .clamp(0.0, 1.0)
      .toDouble();
  final includedAngleDegrees = math.acos(dot) * 180 / math.pi;
  double extensionLength(double along, double length) {
    final tolerance = math.max(1.0, length) * 1e-10;
    if (along < -tolerance) return -along;
    if (along > length + tolerance) return along - length;
    return 0;
  }

  final firstExtensionLength = extensionLength(firstAlong, firstLength);
  final secondExtensionLength = extensionLength(secondAlong, secondLength);
  if (!_finitePoint(intersection) ||
      !firstAlong.isFinite ||
      !secondAlong.isFinite ||
      !includedAngleDegrees.isFinite ||
      !firstExtensionLength.isFinite ||
      !secondExtensionLength.isFinite) {
    return null;
  }
  return CadLineIntersectionMeasurement2D(
    first: first,
    second: second,
    intersection: intersection,
    includedAngleDegrees: includedAngleDegrees,
    firstExtensionLength: firstExtensionLength,
    secondExtensionLength: secondExtensionLength,
  );
}

/// Measures the constant perpendicular spacing between two infinite lines.
///
/// The selected finite segments only identify the intended edges. A strict,
/// scale-independent parallel test prevents a varying separation from being
/// reported as a valid engineering clearance. Calculations are translated to
/// the first edge before projection so large world coordinates retain useful
/// precision.
CadParallelLineSpacingMeasurement2D? cadParallelLineSpacingMeasurement2D(
  CadLineSegment2D first,
  CadLineSegment2D second,
) {
  if (!_finitePoint(first.start) ||
      !_finitePoint(first.end) ||
      !_finitePoint(second.start) ||
      !_finitePoint(second.end)) {
    return null;
  }
  final firstVector = first.end - first.start;
  final secondVector = second.end - second.start;
  final firstLength = _stableOffsetLength(firstVector);
  final secondLength = _stableOffsetLength(secondVector);
  if (!firstLength.isFinite ||
      !secondLength.isFinite ||
      firstLength <= 1e-12 ||
      secondLength <= 1e-12) {
    return null;
  }
  final firstUnit = firstVector / firstLength;
  final secondUnit = secondVector / secondLength;
  final cross = firstUnit.dx * secondUnit.dy - firstUnit.dy * secondUnit.dx;
  if (!cross.isFinite || cross.abs() > 1e-10) return null;

  final secondFoot = second.start + secondUnit * (secondLength * 0.5);
  final relative = secondFoot - first.start;
  final along = relative.dx * firstUnit.dx + relative.dy * firstUnit.dy;
  final firstFoot = first.start + firstUnit * along;
  final spacing = _stableOffsetLength(secondFoot - firstFoot);
  var direction = math.atan2(firstUnit.dy, firstUnit.dx) * 180 / math.pi;
  if (direction < 0) direction += 180;
  if (direction >= 180) direction -= 180;
  if (!_finitePoint(firstFoot) ||
      !_finitePoint(secondFoot) ||
      !spacing.isFinite ||
      !direction.isFinite) {
    return null;
  }
  return CadParallelLineSpacingMeasurement2D(
    first: first,
    second: second,
    firstFoot: firstFoot,
    secondFoot: secondFoot,
    spacing: spacing,
    directionDegrees: direction,
  );
}

/// Measures the exact shortest distance between two finite line segments.
///
/// Unlike an infinite-line or parallel-spacing measurement, the closest
/// points are clamped to both source segments. Intersecting and overlapping
/// segments therefore return one shared closest point and zero clearance.
/// All calculations start from translated vectors so ordinary segment sizes
/// retain precision when a drawing uses large world coordinates.
CadSegmentClearanceMeasurement2D? cadSegmentClearanceMeasurement2D(
  CadLineSegment2D first,
  CadLineSegment2D second,
) {
  if (!_finitePoint(first.start) ||
      !_finitePoint(first.end) ||
      !_finitePoint(second.start) ||
      !_finitePoint(second.end)) {
    return null;
  }
  final firstVector = first.end - first.start;
  final secondVector = second.end - second.start;
  final firstLength = _stableOffsetLength(firstVector);
  final secondLength = _stableOffsetLength(secondVector);
  if (!firstLength.isFinite ||
      !secondLength.isFinite ||
      firstLength <= 1e-12 ||
      secondLength <= 1e-12) {
    return null;
  }
  final firstUnit = firstVector / firstLength;
  final secondUnit = secondVector / secondLength;
  final delta = second.start - first.start;
  final determinant =
      firstUnit.dx * secondUnit.dy - firstUnit.dy * secondUnit.dx;
  if (!determinant.isFinite) return null;

  // A non-parallel intersection is the unique zero-clearance result. The
  // dimensionless tolerance applies to normalized directions, not coordinates.
  if (determinant.abs() > 1e-12) {
    final firstAlong =
        (delta.dx * secondUnit.dy - delta.dy * secondUnit.dx) / determinant;
    final secondAlong =
        (delta.dx * firstUnit.dy - delta.dy * firstUnit.dx) / determinant;
    final firstTolerance = math.max(1.0, firstLength) * 1e-10;
    final secondTolerance = math.max(1.0, secondLength) * 1e-10;
    if (firstAlong >= -firstTolerance &&
        firstAlong <= firstLength + firstTolerance &&
        secondAlong >= -secondTolerance &&
        secondAlong <= secondLength + secondTolerance) {
      final clampedFirst = firstAlong.clamp(0.0, firstLength).toDouble();
      final clampedSecond = secondAlong.clamp(0.0, secondLength).toDouble();
      final fromFirst = first.start + firstUnit * clampedFirst;
      final fromSecond = second.start + secondUnit * clampedSecond;
      final intersection = cadMidpoint2D(fromFirst, fromSecond);
      if (!_finitePoint(intersection)) return null;
      return CadSegmentClearanceMeasurement2D(
        first: first,
        second: second,
        firstClosestPoint: intersection,
        secondClosestPoint: intersection,
        clearance: 0,
      );
    }
  } else {
    final perpendicularDelta =
        (delta.dx * firstUnit.dy - delta.dy * firstUnit.dx).abs();
    final collinearTolerance =
        math.max(1.0, math.max(firstLength, secondLength)) * 1e-10;
    if (perpendicularDelta <= collinearTolerance) {
      final secondStartAlong =
          delta.dx * firstUnit.dx + delta.dy * firstUnit.dy;
      final secondEndRelative = second.end - first.start;
      final secondEndAlong =
          secondEndRelative.dx * firstUnit.dx +
          secondEndRelative.dy * firstUnit.dy;
      final overlapStart = math.max(
        0.0,
        math.min(secondStartAlong, secondEndAlong),
      );
      final overlapEnd = math.min(
        firstLength,
        math.max(secondStartAlong, secondEndAlong),
      );
      if (overlapStart <= overlapEnd + collinearTolerance) {
        final shared =
            first.start +
            firstUnit * overlapStart.clamp(0.0, firstLength).toDouble();
        if (!_finitePoint(shared)) return null;
        return CadSegmentClearanceMeasurement2D(
          first: first,
          second: second,
          firstClosestPoint: shared,
          secondClosestPoint: shared,
          clearance: 0,
        );
      }
    }
  }

  ({Offset firstPoint, Offset secondPoint, double distance})? best;

  void consider(Offset firstPoint, Offset secondPoint) {
    final distance = _stableOffsetLength(secondPoint - firstPoint);
    if (!distance.isFinite ||
        !_finitePoint(firstPoint) ||
        !_finitePoint(secondPoint)) {
      return;
    }
    final current = best;
    final tolerance =
        math.max(1.0, math.max(distance, current?.distance ?? 0)) * 1e-12;
    if (current == null || distance < current.distance - tolerance) {
      best = (
        firstPoint: firstPoint,
        secondPoint: secondPoint,
        distance: distance,
      );
    }
  }

  Offset projectionOnFirst(Offset point) {
    final relative = point - first.start;
    final along = (relative.dx * firstUnit.dx + relative.dy * firstUnit.dy)
        .clamp(0.0, firstLength)
        .toDouble();
    return first.start + firstUnit * along;
  }

  Offset projectionOnSecond(Offset point) {
    final relative = point - second.start;
    final along = (relative.dx * secondUnit.dx + relative.dy * secondUnit.dy)
        .clamp(0.0, secondLength)
        .toDouble();
    return second.start + secondUnit * along;
  }

  consider(first.start, projectionOnSecond(first.start));
  consider(first.end, projectionOnSecond(first.end));
  consider(projectionOnFirst(second.start), second.start);
  consider(projectionOnFirst(second.end), second.end);
  final result = best;
  if (result == null) return null;
  final zeroTolerance =
      math.max(1.0, math.max(firstLength, secondLength)) * 1e-10;
  if (result.distance <= zeroTolerance) {
    final shared = cadMidpoint2D(result.firstPoint, result.secondPoint);
    if (!_finitePoint(shared)) return null;
    return CadSegmentClearanceMeasurement2D(
      first: first,
      second: second,
      firstClosestPoint: shared,
      secondClosestPoint: shared,
      clearance: 0,
    );
  }
  return CadSegmentClearanceMeasurement2D(
    first: first,
    second: second,
    firstClosestPoint: result.firstPoint,
    secondClosestPoint: result.secondPoint,
    clearance: result.distance,
  );
}

class CadTriangleMeasurement2D {
  const CadTriangleMeasurement2D({
    required this.angleDegrees,
    required this.firstRayPointAngleDegrees,
    required this.secondRayPointAngleDegrees,
    required this.firstRayLength,
    required this.secondRayLength,
    required this.oppositeLength,
    required this.area,
    required this.perimeter,
    required this.altitudeFromVertex,
    required this.inradius,
    required this.circumradius,
  });

  /// Interior angle at the first selected point (the angle vertex A).
  final double angleDegrees;

  /// Interior angles at the second (B) and third (C) selected points. They are
  /// null for a degenerate collinear triangle.
  final double? firstRayPointAngleDegrees;
  final double? secondRayPointAngleDegrees;
  final double firstRayLength;
  final double secondRayLength;
  final double oppositeLength;
  final double area;
  final double perimeter;

  /// Perpendicular height from A to the infinite supporting line BC.
  final double? altitudeFromVertex;
  final double? inradius;
  final double? circumradius;
}

/// Measures the triangle implied by an angle vertex and two ray points. The
/// angle uses normalized vectors, while area uses coordinates translated to
/// the vertex, preventing large absolute CAD coordinates from contaminating
/// the result. Collinear rays remain a valid 0/180-degree engineering result;
/// a zero-length ray is undefined and rejected.
CadTriangleMeasurement2D? cadTriangleMeasurement2D(
  Offset vertex,
  Offset firstRayPoint,
  Offset secondRayPoint,
) {
  if (!_finitePoint(vertex) ||
      !_finitePoint(firstRayPoint) ||
      !_finitePoint(secondRayPoint)) {
    return null;
  }
  final first = firstRayPoint - vertex;
  final second = secondRayPoint - vertex;
  final firstLength = _stableOffsetLength(first);
  final secondLength = _stableOffsetLength(second);
  if (!firstLength.isFinite ||
      !secondLength.isFinite ||
      firstLength <= 1e-12 ||
      secondLength <= 1e-12) {
    return null;
  }
  final firstUnit = first / firstLength;
  final secondUnit = second / secondLength;
  final normalizedCross =
      firstUnit.dx * secondUnit.dy - firstUnit.dy * secondUnit.dx;
  final normalizedDot =
      firstUnit.dx * secondUnit.dx + firstUnit.dy * secondUnit.dy;
  final angle =
      math.atan2(normalizedCross.abs(), normalizedDot) * 180 / math.pi;
  final oppositeLength = _stableOffsetLength(secondRayPoint - firstRayPoint);
  final shorterRay = math.min(firstLength, secondLength);
  final longerRay = math.max(firstLength, secondLength);
  final area = normalizedCross.abs() * shorterRay * longerRay * 0.5;
  final perimeter = firstLength + secondLength + oppositeLength;
  if (!angle.isFinite ||
      !oppositeLength.isFinite ||
      !area.isFinite ||
      !perimeter.isFinite) {
    return null;
  }
  final nonDegenerate = area > 0 && oppositeLength > 0;
  final firstRayPointAngle = nonDegenerate
      ? _angleBetweenVectors2D(
          Offset(-first.dx, -first.dy),
          secondRayPoint - firstRayPoint,
        )
      : null;
  final secondRayPointAngle = nonDegenerate
      ? _angleBetweenVectors2D(
          Offset(-second.dx, -second.dy),
          firstRayPoint - secondRayPoint,
        )
      : null;
  final altitude = nonDegenerate ? 2 * (area / oppositeLength) : null;
  final inradius = nonDegenerate ? 2 * (area / perimeter) : null;
  final sineAtVertex = normalizedCross.abs();
  final circumradius = nonDegenerate && sineAtVertex > 0
      ? oppositeLength / (2 * sineAtVertex)
      : null;
  return CadTriangleMeasurement2D(
    angleDegrees: angle,
    firstRayPointAngleDegrees: firstRayPointAngle?.isFinite == true
        ? firstRayPointAngle
        : null,
    secondRayPointAngleDegrees: secondRayPointAngle?.isFinite == true
        ? secondRayPointAngle
        : null,
    firstRayLength: firstLength,
    secondRayLength: secondLength,
    oppositeLength: oppositeLength,
    area: area,
    perimeter: perimeter,
    altitudeFromVertex: altitude?.isFinite == true ? altitude : null,
    inradius: inradius?.isFinite == true ? inradius : null,
    circumradius: circumradius?.isFinite == true ? circumradius : null,
  );
}

double? _angleBetweenVectors2D(Offset first, Offset second) {
  final firstLength = _stableOffsetLength(first);
  final secondLength = _stableOffsetLength(second);
  if (!firstLength.isFinite ||
      !secondLength.isFinite ||
      firstLength <= 0 ||
      secondLength <= 0) {
    return null;
  }
  final firstUnit = first / firstLength;
  final secondUnit = second / secondLength;
  final cross = firstUnit.dx * secondUnit.dy - firstUnit.dy * secondUnit.dx;
  final dot = firstUnit.dx * secondUnit.dx + firstUnit.dy * secondUnit.dy;
  final angle = math.atan2(cross.abs(), dot) * 180 / math.pi;
  return angle.isFinite ? angle : null;
}

double _stableOffsetLength(Offset vector) {
  final x = vector.dx.abs();
  final y = vector.dy.abs();
  final scale = math.max(x, y);
  if (scale == 0) return 0;
  if (!scale.isFinite) return double.infinity;
  final normalizedX = x / scale;
  final normalizedY = y / scale;
  return scale *
      math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY);
}

class CadGrade2D {
  const CadGrade2D({
    required this.run,
    required this.rise,
    required this.percent,
    required this.ratio,
  });

  /// Positive horizontal run along the drawing X axis.
  final double run;

  /// Signed rise along the drawing Y axis in pick order.
  final double rise;

  /// Signed grade. Vertical lines use signed infinity; coincident or invalid
  /// points use null.
  final double? percent;

  /// Horizontal-to-vertical magnitude for the conventional 1:n slope ratio.
  /// Level lines use infinity, vertical lines use zero and invalid points use
  /// null.
  final double? ratio;
}

enum CadCardinalDirection { north, east, south, west }

class CadPolarStakeoutMeasurement2D {
  const CadPolarStakeoutMeasurement2D({
    required this.origin,
    required this.target,
    required this.distance,
    required this.azimuthDegrees,
    required this.deltaX,
    required this.deltaY,
  });

  final Offset origin;
  final Offset target;
  final double distance;

  /// Clockwise direction from +Y in the range [0, 360).
  final double azimuthDegrees;
  final double deltaX;
  final double deltaY;
}

class CadTwoDistanceLocation2D {
  const CadTwoDistanceLocation2D({
    required this.firstReference,
    required this.secondReference,
    required this.firstDistance,
    required this.secondDistance,
    required this.baselineLength,
    required this.solutions,
  });

  final Offset firstReference;
  final Offset secondReference;
  final double firstDistance;
  final double secondDistance;
  final double baselineLength;

  /// One point for tangency, or two points ordered left then right relative to
  /// the directed reference baseline A→B.
  final List<Offset> solutions;
}

/// Intersects two distance circles using coordinates translated and scaled by
/// their largest engineering length. This avoids squaring large radii or CAD
/// coordinates. Ambiguous intersections are deliberately returned as two
/// candidates instead of guessing which side of A→B the user intended.
CadTwoDistanceLocation2D? cadTwoDistanceLocation2D(
  Offset firstReference,
  Offset secondReference,
  double firstDistance,
  double secondDistance,
) {
  if (!_finitePoint(firstReference) ||
      !_finitePoint(secondReference) ||
      !firstDistance.isFinite ||
      !secondDistance.isFinite ||
      firstDistance <= 0 ||
      secondDistance <= 0) {
    return null;
  }
  final baseline = secondReference - firstReference;
  final baselineLength = _stableOffsetLength(baseline);
  if (!baselineLength.isFinite || baselineLength <= 0) return null;
  final scale = math.max(
    baselineLength,
    math.max(firstDistance, secondDistance),
  );
  if (!scale.isFinite || scale <= 0) return null;
  final distance = baselineLength / scale;
  final firstRadius = firstDistance / scale;
  final secondRadius = secondDistance / scale;
  final sum = firstRadius + secondRadius;
  final difference = (firstRadius - secondRadius).abs();
  const tolerance = 1e-12;
  if (distance > sum + tolerance || distance < difference - tolerance) {
    return null;
  }
  final along =
      (firstRadius * firstRadius -
          secondRadius * secondRadius +
          distance * distance) /
      (2 * distance);
  var heightSquared = firstRadius * firstRadius - along * along;
  if (!along.isFinite ||
      !heightSquared.isFinite ||
      heightSquared < -tolerance) {
    return null;
  }
  if (heightSquared.abs() <= tolerance) heightSquared = 0;
  final unit = baseline / baselineLength;
  final base = firstReference + unit * (along * scale);
  if (!_finitePoint(base)) return null;
  final height = math.sqrt(heightSquared) * scale;
  final normal = Offset(-unit.dy, unit.dx);
  final solutions = height == 0
      ? <Offset>[base]
      : <Offset>[base + normal * height, base - normal * height];
  if (solutions.any((point) => !_finitePoint(point)) ||
      (solutions.length == 2 && solutions[0] == solutions[1])) {
    return null;
  }
  return CadTwoDistanceLocation2D(
    firstReference: firstReference,
    secondReference: secondReference,
    firstDistance: firstDistance,
    secondDistance: secondDistance,
    baselineLength: baselineLength,
    solutions: List.unmodifiable(solutions),
  );
}

/// Locates a point from an origin using survey-style polar coordinates.
///
/// The input coordinate space may be the drawing frame or a rotated local
/// frame. Zero degrees follows +Y and azimuth increases clockwise, matching
/// [cadSurveyDirection2D]. A target that collapses back onto the origin at the
/// current floating-point magnitude is rejected rather than claiming false
/// precision in very large-coordinate drawings.
CadPolarStakeoutMeasurement2D? cadPolarStakeoutMeasurement2D(
  Offset origin,
  double distance,
  double azimuthDegrees,
) {
  if (!_finitePoint(origin) ||
      !distance.isFinite ||
      distance <= 0 ||
      !azimuthDegrees.isFinite ||
      azimuthDegrees < 0 ||
      azimuthDegrees >= 360) {
    return null;
  }
  final radians = azimuthDegrees * math.pi / 180;
  var deltaX = distance * math.sin(radians);
  var deltaY = distance * math.cos(radians);
  final axisTolerance = distance * 1e-14;
  if (deltaX.abs() <= axisTolerance) deltaX = 0;
  if (deltaY.abs() <= axisTolerance) deltaY = 0;
  final target = Offset(origin.dx + deltaX, origin.dy + deltaY);
  if (!_finitePoint(target) || target == origin) return null;
  return CadPolarStakeoutMeasurement2D(
    origin: origin,
    target: target,
    distance: distance,
    azimuthDegrees: azimuthDegrees,
    deltaX: deltaX,
    deltaY: deltaY,
  );
}

class CadSurveyDirection2D {
  const CadSurveyDirection2D({
    required this.azimuthDegrees,
    this.cardinal,
    this.bearingFrom,
    this.bearingDegrees,
    this.bearingTo,
  });

  /// Clockwise direction from the drawing +Y axis in the range [0, 360).
  final double azimuthDegrees;
  final CadCardinalDirection? cardinal;
  final CadCardinalDirection? bearingFrom;
  final double? bearingDegrees;
  final CadCardinalDirection? bearingTo;
}

/// Converts two drawing points to survey-style direction notation. This is a
/// drawing-coordinate bearing, not geographic true/grid north: +Y is treated
/// as north and azimuth increases clockwise.
CadSurveyDirection2D? cadSurveyDirection2D(Offset start, Offset end) {
  if (!_finitePoint(start) || !_finitePoint(end)) return null;
  final delta = end - start;
  if (!delta.dx.isFinite || !delta.dy.isFinite) return null;
  final extent = math.max(delta.dx.abs(), delta.dy.abs());
  if (extent == 0) return null;
  var azimuth = math.atan2(delta.dx, delta.dy) * 180 / math.pi;
  if (azimuth < 0) azimuth += 360;
  if (azimuth >= 359.9999999999) azimuth = 0;
  const cardinalTolerance = 1e-10;
  CadSurveyDirection2D cardinal(CadCardinalDirection direction, double value) =>
      CadSurveyDirection2D(azimuthDegrees: value, cardinal: direction);
  if (azimuth.abs() <= cardinalTolerance) {
    return cardinal(CadCardinalDirection.north, 0);
  }
  if ((azimuth - 90).abs() <= cardinalTolerance) {
    return cardinal(CadCardinalDirection.east, 90);
  }
  if ((azimuth - 180).abs() <= cardinalTolerance) {
    return cardinal(CadCardinalDirection.south, 180);
  }
  if ((azimuth - 270).abs() <= cardinalTolerance) {
    return cardinal(CadCardinalDirection.west, 270);
  }
  if (azimuth < 90) {
    return CadSurveyDirection2D(
      azimuthDegrees: azimuth,
      bearingFrom: CadCardinalDirection.north,
      bearingDegrees: azimuth,
      bearingTo: CadCardinalDirection.east,
    );
  }
  if (azimuth < 180) {
    return CadSurveyDirection2D(
      azimuthDegrees: azimuth,
      bearingFrom: CadCardinalDirection.south,
      bearingDegrees: 180 - azimuth,
      bearingTo: CadCardinalDirection.east,
    );
  }
  if (azimuth < 270) {
    return CadSurveyDirection2D(
      azimuthDegrees: azimuth,
      bearingFrom: CadCardinalDirection.south,
      bearingDegrees: azimuth - 180,
      bearingTo: CadCardinalDirection.west,
    );
  }
  return CadSurveyDirection2D(
    azimuthDegrees: azimuth,
    bearingFrom: CadCardinalDirection.north,
    bearingDegrees: 360 - azimuth,
    bearingTo: CadCardinalDirection.west,
  );
}

/// Computes a directional 2D engineering grade using ΔY / |ΔX|. Using an
/// absolute run matches the existing 3D grade convention: reversing the two
/// picks reverses uphill/downhill while preserving the 1:n ratio magnitude.
CadGrade2D cadGrade2D(Offset start, Offset end) {
  if (!_finitePoint(start) || !_finitePoint(end)) {
    return const CadGrade2D(
      run: double.nan,
      rise: double.nan,
      percent: null,
      ratio: null,
    );
  }
  final delta = end - start;
  if (!delta.dx.isFinite || !delta.dy.isFinite) {
    return const CadGrade2D(
      run: double.nan,
      rise: double.nan,
      percent: null,
      ratio: null,
    );
  }
  final run = delta.dx.abs();
  final rise = delta.dy;
  if (run == 0 && rise == 0) {
    return CadGrade2D(run: run, rise: rise, percent: null, ratio: null);
  }
  if (run == 0) {
    return CadGrade2D(
      run: run,
      rise: rise,
      percent: rise.isNegative ? double.negativeInfinity : double.infinity,
      ratio: 0,
    );
  }
  if (rise == 0) {
    return CadGrade2D(run: run, rise: rise, percent: 0, ratio: double.infinity);
  }
  return CadGrade2D(
    run: run,
    rise: rise,
    percent: rise / run * 100,
    ratio: run / rise.abs(),
  );
}

/// Measures an axis-aligned rectangle from two opposite corners. Degenerate or
/// non-finite inputs are rejected so a line is never reported as an area.
CadRectangleMeasurement2D? cadRectangleMeasurement2D(
  Offset first,
  Offset second,
) {
  if (!_finitePoint(first) || !_finitePoint(second)) return null;
  final delta = second - first;
  if (!_finitePoint(delta)) return null;
  final width = delta.dx.abs();
  final height = delta.dy.abs();
  if (width <= 1e-12 || height <= 1e-12) return null;
  final diagonal = _stableOffsetLength(delta);
  final center = cadMidpoint2D(first, second);
  final area = width * height;
  final perimeter = 2 * (width + height);
  if (!diagonal.isFinite ||
      !_finitePoint(center) ||
      !area.isFinite ||
      !perimeter.isFinite) {
    return null;
  }
  return CadRectangleMeasurement2D(
    width: width,
    height: height,
    diagonal: diagonal,
    center: center,
    area: area,
    perimeter: perimeter,
  );
}

/// Measures a strict rectangle from an origin, a width-direction point and a
/// height point. The third point is projected onto the perpendicular axis so
/// noisy taps cannot turn the result into a skew quadrilateral.
CadOrientedRectangleMeasurement2D? cadOrientedRectangleMeasurement2D(
  Offset first,
  Offset second,
  Offset third,
) {
  if (!_finitePoint(first) || !_finitePoint(second) || !_finitePoint(third)) {
    return null;
  }
  final widthVector = second - first;
  final width = _stableOffsetLength(widthVector);
  if (!width.isFinite || width <= 1e-12) return null;
  final widthUnit = widthVector / width;
  final normal = Offset(-widthUnit.dy, widthUnit.dx);
  final thirdVector = third - first;
  final signedHeight = thirdVector.dx * normal.dx + thirdVector.dy * normal.dy;
  final height = signedHeight.abs();
  if (!height.isFinite || height <= 1e-12) return null;
  final heightVector = normal * signedHeight;
  final direction = math.atan2(widthVector.dy, widthVector.dx) * 180 / math.pi;
  final diagonal = _stableOffsetLength(Offset(width, height));
  final center = first + widthVector / 2 + heightVector / 2;
  final area = width * height;
  final perimeter = 2 * (width + height);
  final corners = [first, second, second + heightVector, first + heightVector];
  if (!direction.isFinite ||
      !diagonal.isFinite ||
      !_finitePoint(center) ||
      !area.isFinite ||
      !perimeter.isFinite ||
      corners.any((point) => !_finitePoint(point))) {
    return null;
  }
  return CadOrientedRectangleMeasurement2D(
    corners: List.unmodifiable(corners),
    width: width,
    height: height,
    diagonal: diagonal,
    center: center,
    area: area,
    perimeter: perimeter,
    directionDegrees: direction < 0 ? direction + 360 : direction,
  );
}

/// Builds the unique circumcircle through three points. Calculations are
/// translated to the first point before solving, which avoids squaring large
/// absolute CAD coordinates. Near-collinear points are rejected because their
/// circumcircle is numerically ill-conditioned and can become a false huge
/// radius after ordinary touch/snap noise.
CadThreePointCircleMeasurement2D? cadThreePointCircleMeasurement2D(
  Offset first,
  Offset second,
  Offset third,
) {
  if (!_finitePoint(first) || !_finitePoint(second) || !_finitePoint(third)) {
    return null;
  }
  final a = second - first;
  final b = third - first;
  final aLengthSquared = a.dx * a.dx + a.dy * a.dy;
  final bLengthSquared = b.dx * b.dx + b.dy * b.dy;
  if (!aLengthSquared.isFinite ||
      !bLengthSquared.isFinite ||
      aLengthSquared <= 1e-24 ||
      bLengthSquared <= 1e-24) {
    return null;
  }
  final cross = a.dx * b.dy - a.dy * b.dx;
  final crossScale = math.sqrt(aLengthSquared * bLengthSquared);
  if (!cross.isFinite ||
      !crossScale.isFinite ||
      cross.abs() <= crossScale * 1e-10) {
    return null;
  }
  final denominator = 2 * cross;
  final localCenter = Offset(
    (b.dy * aLengthSquared - a.dy * bLengthSquared) / denominator,
    (a.dx * bLengthSquared - b.dx * aLengthSquared) / denominator,
  );
  final center = first + localCenter;
  final radius = localCenter.distance;
  final diameter = radius * 2;
  final circumference = math.pi * diameter;
  final area = math.pi * radius * radius;
  if (!_finitePoint(center) ||
      !radius.isFinite ||
      radius <= 1e-12 ||
      !diameter.isFinite ||
      !circumference.isFinite ||
      !area.isFinite) {
    return null;
  }
  return CadThreePointCircleMeasurement2D(
    center: center,
    radius: radius,
    diameter: diameter,
    circumference: circumference,
    area: area,
  );
}

({double sectorArea, double segmentArea})? _circularArcAreas2D(
  double radius,
  double sweepRadians,
) {
  if (!radius.isFinite ||
      radius <= 0 ||
      !sweepRadians.isFinite ||
      sweepRadians <= 0 ||
      sweepRadians > 2 * math.pi) {
    return null;
  }
  final radiusSquared = radius * radius;
  final sectorArea = radiusSquared * sweepRadians / 2;
  var segmentArea = radiusSquared * _angleMinusSin(sweepRadians) / 2;
  final fullArea = math.pi * radiusSquared;
  final tolerance = fullArea.abs() * 1e-12;
  if (segmentArea > fullArea && segmentArea - fullArea <= tolerance) {
    segmentArea = fullArea;
  }
  if (!sectorArea.isFinite ||
      !segmentArea.isFinite ||
      !fullArea.isFinite ||
      sectorArea <= 0 ||
      segmentArea <= 0 ||
      segmentArea > fullArea) {
    return null;
  }
  return (sectorArea: sectorArea, segmentArea: segmentArea);
}

/// Returns the sagitta measured from the chord to the midpoint of the selected
/// arc. A major arc therefore returns the major sagitta (> radius), not the
/// minor complementary value. A full circle has no unique chord and returns
/// null. The half-angle form avoids cancellation for shallow arcs.
double? cadArcSagitta2D(double radius, double sweepRadians) {
  final fullSweep = 2 * math.pi;
  if (!radius.isFinite ||
      radius <= 0 ||
      !sweepRadians.isFinite ||
      sweepRadians <= 0 ||
      sweepRadians >= fullSweep) {
    return null;
  }
  final sine = math.sin(sweepRadians / 4);
  final factor = 2 * sine * sine;
  final sagitta = factor <= 1
      ? radius * factor
      : radius + radius * (factor - 1);
  return sagitta.isFinite && sagitta > 0 ? sagitta : null;
}

/// Stable evaluation of x - sin(x). Direct subtraction loses every useful
/// digit for shallow arcs, so use its alternating series near zero.
double _angleMinusSin(double angle) {
  if (angle.abs() >= 0.01) return angle - math.sin(angle);
  final squared = angle * angle;
  return angle *
      squared *
      (1 / 6 -
          squared / 120 +
          squared * squared / 5040 -
          squared * squared * squared / 362880);
}

/// Measures the unique directed arc from [first] to [third] that passes
/// through [second]. The selected middle point decides both direction and
/// whether the result is the minor or major arc, including arcs crossing 0°.
CadThreePointArcMeasurement2D? cadThreePointArcMeasurement2D(
  Offset first,
  Offset second,
  Offset third,
) {
  final circle = cadThreePointCircleMeasurement2D(first, second, third);
  if (circle == null) return null;
  final startAngle = math.atan2(
    first.dy - circle.center.dy,
    first.dx - circle.center.dx,
  );
  final middleAngle = math.atan2(
    second.dy - circle.center.dy,
    second.dx - circle.center.dx,
  );
  final endAngle = math.atan2(
    third.dy - circle.center.dy,
    third.dx - circle.center.dx,
  );
  final counterClockwiseSweep = _positiveAngleDelta(startAngle, endAngle);
  final counterClockwiseToMiddle = _positiveAngleDelta(startAngle, middleAngle);
  final counterClockwise = counterClockwiseToMiddle < counterClockwiseSweep;
  final sweepRadians = counterClockwise
      ? counterClockwiseSweep
      : 2 * math.pi - counterClockwiseSweep;
  final sweepDegrees = sweepRadians * 180 / math.pi;
  final arcLength = circle.radius * sweepRadians;
  final chordLength = _stableOffsetLength(third - first);
  final sagitta = cadArcSagitta2D(circle.radius, sweepRadians);
  final areas = _circularArcAreas2D(circle.radius, sweepRadians);
  if (!startAngle.isFinite ||
      !middleAngle.isFinite ||
      !endAngle.isFinite ||
      !sweepRadians.isFinite ||
      sweepRadians <= 1e-12 ||
      sweepRadians >= 2 * math.pi ||
      !sweepDegrees.isFinite ||
      !arcLength.isFinite ||
      !chordLength.isFinite ||
      chordLength <= 1e-12 ||
      sagitta == null ||
      areas == null) {
    return null;
  }
  return CadThreePointArcMeasurement2D(
    center: circle.center,
    radius: circle.radius,
    diameter: circle.diameter,
    sweepRadians: sweepRadians,
    sweepDegrees: sweepDegrees,
    arcLength: arcLength,
    chordLength: chordLength,
    sagitta: sagitta,
    sectorArea: areas.sectorArea,
    segmentArea: areas.segmentArea,
    counterClockwise: counterClockwise,
  );
}

/// Derives the standard tangent geometry of a simple circular curve.
///
/// Only a minor arc (`0 < delta < 180 degrees`) has the unambiguous finite PI
/// convention used by field alignment work. Endpoint radii, directed sweep,
/// and the independently constructed end tangent are all validated before a
/// result is returned. This prevents a plausible-looking PI from being shown
/// for inconsistent imported geometry or a semicircle with parallel tangents.
CadSimpleCircularCurve2D? cadSimpleCircularCurve2D({
  required Offset center,
  required Offset start,
  required Offset end,
  required double radius,
  required double sweepRadians,
  required bool counterClockwise,
}) {
  if (!_finitePoint(center) ||
      !_finitePoint(start) ||
      !_finitePoint(end) ||
      !radius.isFinite ||
      radius <= 0 ||
      !sweepRadians.isFinite ||
      sweepRadians <= 1e-12 ||
      sweepRadians >= math.pi) {
    return null;
  }
  final startVector = start - center;
  final endVector = end - center;
  final startRadius = _stableOffsetLength(startVector);
  final endRadius = _stableOffsetLength(endVector);
  if (!startRadius.isFinite ||
      !endRadius.isFinite ||
      startRadius <= 1e-12 ||
      endRadius <= 1e-12) {
    return null;
  }
  final coordinateScale = [
    center.dx.abs(),
    center.dy.abs(),
    start.dx.abs(),
    start.dy.abs(),
    end.dx.abs(),
    end.dy.abs(),
  ].reduce(math.max);
  final representableTolerance = math.min(
    radius * 1e-4,
    coordinateScale * 4e-16,
  );
  final radiusTolerance = math.max(
    math.max(1.0, radius) * 1e-10,
    representableTolerance,
  );
  if ((startRadius - radius).abs() > radiusTolerance ||
      (endRadius - radius).abs() > radiusTolerance) {
    return null;
  }

  final startAngle = math.atan2(startVector.dy, startVector.dx);
  final endAngle = math.atan2(endVector.dy, endVector.dx);
  final endpointSweep = counterClockwise
      ? _positiveAngleDelta(startAngle, endAngle)
      : _positiveAngleDelta(endAngle, startAngle);
  final sweepTolerance = math.max(1e-10, sweepRadians * 1e-10);
  if (!endpointSweep.isFinite ||
      (endpointSweep - sweepRadians).abs() > sweepTolerance) {
    return null;
  }

  final halfSweep = sweepRadians / 2;
  final cosine = math.cos(halfSweep);
  final tangentLength = radius * math.tan(halfSweep);
  final halfHalfSine = math.sin(halfSweep / 2);
  final oneMinusCosine = 2 * halfHalfSine * halfHalfSine;
  final externalDistance = radius * oneMinusCosine / cosine;
  final middleOrdinate = radius * oneMinusCosine;
  final turn = counterClockwise ? 1.0 : -1.0;
  final startRadialUnit = startVector / startRadius;
  final endRadialUnit = endVector / endRadius;
  final startTangentUnit = Offset(
    -turn * startRadialUnit.dy,
    turn * startRadialUnit.dx,
  );
  final endTangentUnit = Offset(
    -turn * endRadialUnit.dy,
    turn * endRadialUnit.dx,
  );
  final fromStart = start + startTangentUnit * tangentLength;
  final fromEnd = end - endTangentUnit * tangentLength;
  final tangentMismatch = _stableOffsetLength(fromEnd - fromStart);
  final positionTolerance = math.max(
    radiusTolerance * 8,
    math.max(1.0, tangentLength) * 1e-9,
  );
  if (!cosine.isFinite ||
      cosine <= 0 ||
      !tangentLength.isFinite ||
      !externalDistance.isFinite ||
      !middleOrdinate.isFinite ||
      tangentLength <= 0 ||
      externalDistance <= 0 ||
      middleOrdinate <= 0 ||
      !tangentMismatch.isFinite ||
      tangentMismatch > positionTolerance ||
      !_finitePoint(fromStart) ||
      !_finitePoint(fromEnd)) {
    return null;
  }
  final tangentIntersection = cadMidpoint2D(fromStart, fromEnd);
  var startDirection =
      math.atan2(startTangentUnit.dy, startTangentUnit.dx) * 180 / math.pi;
  var endDirection =
      math.atan2(endTangentUnit.dy, endTangentUnit.dx) * 180 / math.pi;
  if (startDirection < 0) startDirection += 360;
  if (endDirection < 0) endDirection += 360;
  if (!_finitePoint(tangentIntersection) ||
      !startDirection.isFinite ||
      !endDirection.isFinite) {
    return null;
  }
  return CadSimpleCircularCurve2D(
    tangentIntersection: tangentIntersection,
    tangentLength: tangentLength,
    externalDistance: externalDistance,
    middleOrdinate: middleOrdinate,
    startTangentDirectionDegrees: startDirection,
    endTangentDirectionDegrees: endDirection,
  );
}

/// Projects a point onto an infinite directed baseline. Station is measured
/// from the first baseline point; signed offset is positive on the left side
/// of the first-to-second direction and negative on the right.
CadPointLineMeasurement2D? cadPointLineMeasurement2D(
  Offset first,
  Offset second,
  Offset point,
) {
  if (!_finitePoint(first) || !_finitePoint(second) || !_finitePoint(point)) {
    return null;
  }
  final baseline = second - first;
  final length = baseline.distance;
  if (!length.isFinite || length <= 1e-12) return null;
  final unit = baseline / length;
  final relative = point - first;
  final station = relative.dx * unit.dx + relative.dy * unit.dy;
  final signedOffset = unit.dx * relative.dy - unit.dy * relative.dx;
  final foot = first + unit * station;
  var direction = math.atan2(baseline.dy, baseline.dx) * 180 / math.pi;
  if (direction < 0) direction += 360;
  if (!_finitePoint(foot) ||
      !station.isFinite ||
      !signedOffset.isFinite ||
      !direction.isFinite) {
    return null;
  }
  return CadPointLineMeasurement2D(
    foot: foot,
    perpendicularDistance: signedOffset.abs(),
    signedOffset: signedOffset,
    station: station,
    directionDegrees: direction,
  );
}

/// Returns an area only when the normalized visible entity is a valid closed
/// boundary. Circles use their analytic values; closed polylines must pass the
/// same self-intersection and degeneracy validation used by manual area tools.
CadAreaMeasurement2D? cadClosedEntityAreaMeasurement2D(
  Map<String, dynamic> geometry,
) {
  final metrics = cadEntityMetrics2D(geometry);
  final perimeter = switch (metrics.kind) {
    'circle' => metrics.circumference,
    'polyline' when metrics.closed == true => metrics.length,
    _ => null,
  };
  final area = metrics.area;
  final centroid = switch (metrics.kind) {
    'circle' => metrics.center,
    'polyline' when metrics.closed == true => cadPolygonCentroid2D(
      (geometry['points'] as List<dynamic>? ?? const [])
          .map(_point)
          .toList(growable: false),
    ),
    _ => null,
  };
  if (area == null ||
      perimeter == null ||
      centroid == null ||
      !_finitePoint(centroid) ||
      !area.isFinite ||
      !perimeter.isFinite ||
      area <= 0 ||
      perimeter <= 0) {
    return null;
  }
  return CadAreaMeasurement2D(
    area: area,
    perimeter: perimeter,
    centroid: centroid,
  );
}

/// Returns the geometric centroid of a finite, non-degenerate simple polygon.
/// Coordinates are translated to the first vertex and all three sums use
/// compensated addition, preserving small engineering geometry located far
/// from the drawing origin.
Offset? cadPolygonCentroid2D(
  List<Offset> source, {
  int maxValidationVertices = 4096,
}) {
  if (simplePolygonArea2D(
        source,
        maxValidationVertices: maxValidationVertices,
      ) ==
      null) {
    return null;
  }
  return _validatedPolygonCentroid2D(source);
}

/// Computes a centroid after [simplePolygonArea2D] has accepted the boundary.
/// Keeping validation outside this helper lets section-property calculation
/// reuse the same O(n²) simplicity check instead of repeating it on mobile.
Offset? _validatedPolygonCentroid2D(List<Offset> source) {
  final points = List<Offset>.of(source);
  final tolerance = _centroidTolerance(points);
  if ((points.last - points.first).distanceSquared <= tolerance * tolerance) {
    points.removeLast();
  }
  final origin = points.first;
  final twiceArea = _CompensatedSum();
  final weightedX = _CompensatedSum();
  final weightedY = _CompensatedSum();
  for (var index = 0; index < points.length; index++) {
    final current = points[index] - origin;
    final next = points[(index + 1) % points.length] - origin;
    final cross = current.dx * next.dy - next.dx * current.dy;
    twiceArea.add(cross);
    weightedX.add((current.dx + next.dx) * cross);
    weightedY.add((current.dy + next.dy) * cross);
  }
  final denominator = 3 * twiceArea.value;
  if (!denominator.isFinite || denominator.abs() <= tolerance * tolerance) {
    return null;
  }
  final centroid =
      origin +
      Offset(weightedX.value / denominator, weightedY.value / denominator);
  return _finitePoint(centroid) ? centroid : null;
}

double _centroidTolerance(List<Offset> points) {
  var minX = points.first.dx;
  var maxX = minX;
  var minY = points.first.dy;
  var maxY = minY;
  for (final point in points.skip(1)) {
    minX = math.min(minX, point.dx);
    maxX = math.max(maxX, point.dx);
    minY = math.min(minY, point.dy);
    maxY = math.max(maxY, point.dy);
  }
  return math.max(math.max(maxX - minX, maxY - minY), 1) * 1e-12;
}

class _CompensatedSum {
  double value = 0;
  double _compensation = 0;

  void add(double term) {
    final corrected = term - _compensation;
    final updated = value + corrected;
    _compensation = (updated - value) - corrected;
    value = updated;
  }
}

class CadBounds3D {
  const CadBounds3D({
    required this.minX,
    required this.minY,
    required this.minZ,
    required this.maxX,
    required this.maxY,
    required this.maxZ,
  });

  final double minX;
  final double minY;
  final double minZ;
  final double maxX;
  final double maxY;
  final double maxZ;

  double get sizeX => maxX - minX;
  double get sizeY => maxY - minY;
  double get sizeZ => maxZ - minZ;
}

CadEntityMetrics2D cadEntityMetrics2D(Map<String, dynamic> geometry) {
  final kind = geometry['kind'] as String? ?? 'unknown';
  switch (kind) {
    case 'line':
      final start = _point(geometry['start']);
      final end = _point(geometry['end']);
      return CadEntityMetrics2D(
        kind: kind,
        start: start,
        end: end,
        length: (end - start).distance,
        bounds: _bounds2D([start, end]),
      );
    case 'polyline':
      final points = (geometry['points'] as List<dynamic>? ?? const [])
          .map(_point)
          .toList(growable: false);
      final closed = geometry['closed'] as bool? ?? false;
      return CadEntityMetrics2D(
        kind: kind,
        length: polylineLength2D(points, closed: closed),
        area: closed ? simplePolygonArea2D(points) : null,
        vertexCount: points.length,
        closed: closed,
        bounds: _bounds2D(points),
      );
    case 'circle':
      final center = _point(geometry['center']);
      final radius = _finiteRadius(geometry['radius']);
      return CadEntityMetrics2D(
        kind: kind,
        center: center,
        radius: radius,
        diameter: radius == null ? null : radius * 2,
        circumference: radius == null ? null : math.pi * radius * 2,
        area: radius == null ? null : math.pi * radius * radius,
        bounds: radius == null || !_finitePoint(center)
            ? null
            : Rect.fromCircle(center: center, radius: radius),
      );
    case 'arc':
      final center = _point(geometry['center']);
      final radius = _finiteRadius(geometry['radius']);
      final start = (geometry['start_angle'] as num?)?.toDouble();
      final end = (geometry['end_angle'] as num?)?.toDouble();
      final sweep =
          start == null || end == null || !start.isFinite || !end.isFinite
          ? null
          : cadArcSweepRadians(start, end);
      final areas = radius == null || sweep == null
          ? null
          : _circularArcAreas2D(radius, sweep);
      final fullCircle = sweep == 2 * math.pi;
      final chordLength = radius == null || sweep == null
          ? null
          : fullCircle
          ? 0.0
          : 2 * radius * math.sin(sweep / 2).abs();
      final sagitta = radius == null || sweep == null
          ? null
          : cadArcSagitta2D(radius, sweep);
      Offset? chordStart;
      Offset? chordEnd;
      if (radius != null &&
          start != null &&
          end != null &&
          !fullCircle &&
          _finitePoint(center)) {
        final candidateStart =
            center + Offset(math.cos(start), math.sin(start)) * radius;
        final candidateEnd =
            center + Offset(math.cos(end), math.sin(end)) * radius;
        if (_finitePoint(candidateStart) && _finitePoint(candidateEnd)) {
          chordStart = candidateStart;
          chordEnd = candidateEnd;
        }
      }
      return CadEntityMetrics2D(
        kind: kind,
        start: chordStart,
        end: chordEnd,
        center: center,
        radius: radius,
        diameter: radius == null ? null : radius * 2,
        sweepDegrees: sweep == null ? null : sweep * 180 / math.pi,
        arcLength: radius == null || sweep == null ? null : radius * sweep,
        chordLength: chordLength?.isFinite == true ? chordLength : null,
        sagitta: sagitta,
        sectorArea: areas?.sectorArea,
        segmentArea: areas?.segmentArea,
        bounds: radius == null || start == null || end == null
            ? null
            : _arcBounds(center, radius, start, end),
      );
    case 'point':
      return CadEntityMetrics2D(
        kind: kind,
        position: _point(geometry['position']),
      );
    case 'text':
      return CadEntityMetrics2D(
        kind: kind,
        position: _point(geometry['origin']),
        content: geometry['value'] as String? ?? '',
        textHeight: (geometry['height'] as num?)?.toDouble().abs(),
      );
    default:
      return CadEntityMetrics2D(kind: kind);
  }
}

final Expando<_CachedBounds3D> _meshBoundsCache = Expando<_CachedBounds3D>();

CadBounds3D? cadMeshBounds3D(Map<String, dynamic> mesh) {
  final cached = _meshBoundsCache[mesh];
  if (cached != null) return cached.value;
  final positions = mesh['positions'] as List<dynamic>? ?? const [];
  CadBounds3D? result;
  if (positions.isNotEmpty) {
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;
    var valid = true;
    for (final value in positions) {
      final point = value as Map<String, dynamic>?;
      final x = (point?['x'] as num?)?.toDouble();
      final y = (point?['y'] as num?)?.toDouble();
      final z = (point?['z'] as num?)?.toDouble();
      if (x == null ||
          y == null ||
          z == null ||
          !x.isFinite ||
          !y.isFinite ||
          !z.isFinite) {
        valid = false;
        break;
      }
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }
    if (valid) {
      result = CadBounds3D(
        minX: minX,
        minY: minY,
        minZ: minZ,
        maxX: maxX,
        maxY: maxY,
        maxZ: maxZ,
      );
    }
  }
  _meshBoundsCache[mesh] = _CachedBounds3D(result);
  return result;
}

class _CachedBounds3D {
  const _CachedBounds3D(this.value);

  final CadBounds3D? value;
}

double cadArcSweepRadians(double start, double end) {
  if (!start.isFinite || !end.isFinite) return 0;
  final tau = math.pi * 2;
  final normalized = ((end - start) % tau + tau) % tau;
  return normalized <= 1e-12 ? tau : normalized;
}

double _positiveAngleDelta(double start, double end) {
  final tau = math.pi * 2;
  return ((end - start) % tau + tau) % tau;
}

Rect? _arcBounds(Offset center, double radius, double start, double end) {
  if (!_finitePoint(center) || !start.isFinite || !end.isFinite) return null;
  final sweep = cadArcSweepRadians(start, end);
  final angles = <double>[start, start + sweep];
  for (final cardinal in const [0.0, math.pi / 2, math.pi, math.pi * 3 / 2]) {
    if (_angleInSweep(cardinal, start, sweep)) angles.add(cardinal);
  }
  return _bounds2D(
    angles
        .map(
          (angle) => center + Offset(math.cos(angle), math.sin(angle)) * radius,
        )
        .toList(growable: false),
  );
}

bool _angleInSweep(double angle, double start, double sweep) {
  const tau = math.pi * 2;
  final delta = (angle - start) % tau;
  return delta <= sweep + 1e-12;
}

Rect? _bounds2D(List<Offset> points) {
  if (points.isEmpty || points.any((point) => !_finitePoint(point))) {
    return null;
  }
  var minX = points.first.dx;
  var minY = points.first.dy;
  var maxX = minX;
  var maxY = minY;
  for (final point in points.skip(1)) {
    minX = math.min(minX, point.dx);
    minY = math.min(minY, point.dy);
    maxX = math.max(maxX, point.dx);
    maxY = math.max(maxY, point.dy);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

bool _finitePoint(Offset point) => point.dx.isFinite && point.dy.isFinite;

Offset? _strictPoint(dynamic value) {
  if (value is! Map<String, dynamic>) return null;
  final x = (value['x'] as num?)?.toDouble();
  final y = (value['y'] as num?)?.toDouble();
  if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
  return Offset(x, y);
}

Offset _point(dynamic value) {
  final point = value as Map<String, dynamic>?;
  if (point == null) return Offset.zero;
  return Offset(
    (point['x'] as num?)?.toDouble() ?? 0,
    (point['y'] as num?)?.toDouble() ?? 0,
  );
}

double? _finiteRadius(dynamic value) {
  final radius = (value as num?)?.toDouble().abs();
  return radius != null && radius.isFinite ? radius : null;
}
