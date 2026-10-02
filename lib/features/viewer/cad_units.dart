class CadEngineeringUnit {
  const CadEngineeringUnit({
    required this.id,
    required this.symbol,
    required this.metersPerUnit,
  });

  final String id;
  final String symbol;
  final double metersPerUnit;
}

const cadEngineeringUnits = <CadEngineeringUnit>[
  CadEngineeringUnit(id: 'microin', symbol: 'µin', metersPerUnit: 2.54e-8),
  CadEngineeringUnit(id: 'mil', symbol: 'mil', metersPerUnit: 2.54e-5),
  CadEngineeringUnit(id: 'in', symbol: 'in', metersPerUnit: 0.0254),
  CadEngineeringUnit(id: 'ft', symbol: 'ft', metersPerUnit: 0.3048),
  CadEngineeringUnit(id: 'yd', symbol: 'yd', metersPerUnit: 0.9144),
  CadEngineeringUnit(id: 'mi', symbol: 'mi', metersPerUnit: 1609.344),
  CadEngineeringUnit(id: 'angstrom', symbol: 'Å', metersPerUnit: 1e-10),
  CadEngineeringUnit(id: 'nm', symbol: 'nm', metersPerUnit: 1e-9),
  CadEngineeringUnit(id: 'micron', symbol: 'µm', metersPerUnit: 1e-6),
  CadEngineeringUnit(id: 'mm', symbol: 'mm', metersPerUnit: 0.001),
  CadEngineeringUnit(id: 'cm', symbol: 'cm', metersPerUnit: 0.01),
  CadEngineeringUnit(id: 'dm', symbol: 'dm', metersPerUnit: 0.1),
  CadEngineeringUnit(id: 'm', symbol: 'm', metersPerUnit: 1),
  CadEngineeringUnit(id: 'dam', symbol: 'dam', metersPerUnit: 10),
  CadEngineeringUnit(id: 'hm', symbol: 'hm', metersPerUnit: 100),
  CadEngineeringUnit(id: 'km', symbol: 'km', metersPerUnit: 1000),
  CadEngineeringUnit(id: 'gm', symbol: 'Gm', metersPerUnit: 1e9),
  CadEngineeringUnit(id: 'au', symbol: 'AU', metersPerUnit: 149597870700),
  CadEngineeringUnit(id: 'ly', symbol: 'ly', metersPerUnit: 9.4607304725808e15),
  CadEngineeringUnit(
    id: 'pc',
    symbol: 'pc',
    metersPerUnit: 3.0856775814913673e16,
  ),
  CadEngineeringUnit(id: 'in_us', symbol: 'inUS', metersPerUnit: 100 / 3937),
  CadEngineeringUnit(id: 'ft_us', symbol: 'ftUS', metersPerUnit: 1200 / 3937),
  CadEngineeringUnit(id: 'yd_us', symbol: 'ydUS', metersPerUnit: 3600 / 3937),
  CadEngineeringUnit(
    id: 'mi_us',
    symbol: 'miUS',
    metersPerUnit: 6336000 / 3937,
  ),
];

CadEngineeringUnit? cadEngineeringUnitById(String? id) {
  if (id == null) return null;
  for (final unit in cadEngineeringUnits) {
    if (unit.id == id) return unit;
  }
  return null;
}

const cadCommonDisplayUnitIds = <String>['mm', 'cm', 'm', 'in', 'ft'];

double convertCadLength(
  double value,
  CadEngineeringUnit from,
  CadEngineeringUnit to,
) => value * from.metersPerUnit / to.metersPerUnit;

double convertCadArea(
  double value,
  CadEngineeringUnit from,
  CadEngineeringUnit to,
) {
  final scale = from.metersPerUnit / to.metersPerUnit;
  return value * scale * scale;
}

double convertCadVolume(
  double value,
  CadEngineeringUnit from,
  CadEngineeringUnit to,
) {
  final scale = from.metersPerUnit / to.metersPerUnit;
  return value * scale * scale * scale;
}

double convertCadFourthPower(
  double value,
  CadEngineeringUnit from,
  CadEngineeringUnit to,
) {
  final scale = from.metersPerUnit / to.metersPerUnit;
  final squared = scale * scale;
  return value * squared * squared;
}

/// Returns the real-world size represented by one drawing unit.
///
/// Invalid or degenerate calibration input is rejected instead of silently
/// producing infinite measurements.
double? cadCalibrationMetersPerDrawingUnit({
  required double drawingDistance,
  required double knownLength,
  required CadEngineeringUnit knownUnit,
}) {
  if (!drawingDistance.isFinite ||
      !knownLength.isFinite ||
      drawingDistance <= 0 ||
      knownLength <= 0) {
    return null;
  }
  final value = knownLength * knownUnit.metersPerUnit / drawingDistance;
  return value.isFinite && value > 0 ? value : null;
}

double convertCalibratedCadLength(
  double value,
  double metersPerDrawingUnit,
  CadEngineeringUnit to,
) => value * metersPerDrawingUnit / to.metersPerUnit;

/// Converts a coordinate entered in the current display unit back to source
/// drawing units. Negative coordinates are valid; non-finite values and an
/// invalid calibration are rejected instead of reaching the viewport.
double? cadDisplayLengthToDrawingUnits(
  double value, {
  CadEngineeringUnit? source,
  CadEngineeringUnit? display,
  double? metersPerDrawingUnit,
}) {
  if (!value.isFinite) return null;
  final effectiveDisplay = display ?? source;
  double drawingValue;
  if (metersPerDrawingUnit != null) {
    if (!metersPerDrawingUnit.isFinite ||
        metersPerDrawingUnit <= 0 ||
        effectiveDisplay == null) {
      return null;
    }
    drawingValue =
        value * effectiveDisplay.metersPerUnit / metersPerDrawingUnit;
  } else if (source != null && effectiveDisplay != null) {
    drawingValue = convertCadLength(value, effectiveDisplay, source);
  } else {
    drawingValue = value;
  }
  return drawingValue.isFinite ? drawingValue : null;
}

/// Converts source drawing units to the current display unit. This is the
/// validated inverse of [cadDisplayLengthToDrawingUnits] and also supports a
/// real-world scale calibration for otherwise unitless drawings.
double? cadDrawingLengthToDisplayUnits(
  double value, {
  CadEngineeringUnit? source,
  CadEngineeringUnit? display,
  double? metersPerDrawingUnit,
}) {
  if (!value.isFinite) return null;
  final effectiveDisplay = display ?? source;
  double displayValue;
  if (metersPerDrawingUnit != null) {
    if (!metersPerDrawingUnit.isFinite ||
        metersPerDrawingUnit <= 0 ||
        effectiveDisplay == null) {
      return null;
    }
    displayValue = convertCalibratedCadLength(
      value,
      metersPerDrawingUnit,
      effectiveDisplay,
    );
  } else if (source != null && effectiveDisplay != null) {
    displayValue = convertCadLength(value, source, effectiveDisplay);
  } else {
    displayValue = value;
  }
  return displayValue.isFinite ? displayValue : null;
}

/// Converts an area entered in the current display unit squared back to
/// drawing-unit squared. This is the area counterpart of
/// [cadDisplayLengthToDrawingUnits] and preserves unitless drawings without
/// inventing a physical scale.
double? cadDisplayAreaToDrawingUnits(
  double value, {
  CadEngineeringUnit? source,
  CadEngineeringUnit? display,
  double? metersPerDrawingUnit,
}) {
  if (!value.isFinite) return null;
  final effectiveDisplay = display ?? source;
  double drawingValue;
  if (metersPerDrawingUnit != null) {
    if (!metersPerDrawingUnit.isFinite ||
        metersPerDrawingUnit <= 0 ||
        effectiveDisplay == null) {
      return null;
    }
    final scale = effectiveDisplay.metersPerUnit / metersPerDrawingUnit;
    drawingValue = value * scale * scale;
  } else if (source != null && effectiveDisplay != null) {
    drawingValue = convertCadArea(value, effectiveDisplay, source);
  } else {
    drawingValue = value;
  }
  return drawingValue.isFinite ? drawingValue : null;
}

double convertCalibratedCadArea(
  double value,
  double metersPerDrawingUnit,
  CadEngineeringUnit to,
) {
  final scale = metersPerDrawingUnit / to.metersPerUnit;
  return value * scale * scale;
}

double convertCalibratedCadVolume(
  double value,
  double metersPerDrawingUnit,
  CadEngineeringUnit to,
) {
  final scale = metersPerDrawingUnit / to.metersPerUnit;
  return value * scale * scale * scale;
}

double convertCalibratedCadFourthPower(
  double value,
  double metersPerDrawingUnit,
  CadEngineeringUnit to,
) {
  final scale = metersPerDrawingUnit / to.metersPerUnit;
  final squared = scale * scale;
  return value * squared * squared;
}

/// Converts a volume expressed in drawing-unit cubed into the active display
/// unit cubed. Invalid calibration and overflow are rejected instead of being
/// presented as plausible engineering quantities.
double? cadDrawingVolumeToDisplayUnits(
  double value, {
  CadEngineeringUnit? source,
  CadEngineeringUnit? display,
  double? metersPerDrawingUnit,
}) {
  if (!value.isFinite) return null;
  final effectiveDisplay = display ?? source;
  double displayValue;
  if (metersPerDrawingUnit != null) {
    if (!metersPerDrawingUnit.isFinite ||
        metersPerDrawingUnit <= 0 ||
        effectiveDisplay == null) {
      return null;
    }
    displayValue = convertCalibratedCadVolume(
      value,
      metersPerDrawingUnit,
      effectiveDisplay,
    );
  } else if (source != null && effectiveDisplay != null) {
    displayValue = convertCadVolume(value, source, effectiveDisplay);
  } else {
    displayValue = value;
  }
  return displayValue.isFinite ? displayValue : null;
}

/// Converts a section property expressed in drawing-unit to the fourth power
/// into the active display unit. Invalid calibration and overflow are rejected.
double? cadDrawingFourthPowerToDisplayUnits(
  double value, {
  CadEngineeringUnit? source,
  CadEngineeringUnit? display,
  double? metersPerDrawingUnit,
}) {
  if (!value.isFinite) return null;
  final effectiveDisplay = display ?? source;
  double displayValue;
  if (metersPerDrawingUnit != null) {
    if (!metersPerDrawingUnit.isFinite ||
        metersPerDrawingUnit <= 0 ||
        effectiveDisplay == null) {
      return null;
    }
    displayValue = convertCalibratedCadFourthPower(
      value,
      metersPerDrawingUnit,
      effectiveDisplay,
    );
  } else if (source != null && effectiveDisplay != null) {
    displayValue = convertCadFourthPower(value, source, effectiveDisplay);
  } else {
    displayValue = value;
  }
  return displayValue.isFinite ? displayValue : null;
}
