import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cad_engine.dart';
import '../../core/distribution.dart';
import '../../core/document_details.dart';
import '../../core/image_export.dart';
import '../../core/sheet_export.dart';
import '../../l10n/app_localizations.dart';
import 'cad_document_model.dart';
import 'cad_entity_metrics.dart';
import 'cad_scene_painter.dart';
import 'cad_units.dart';
import 'pdf_document_viewport.dart';

enum ViewerTool {
  pan,
  select,
  measureCoordinate,
  collectCoordinates,
  locatePolarPoint,
  locateTwoDistances,
  measure,
  measurePath,
  measureEntityLength,
  measureEntityArea,
  measureAngle,
  measureFaceAngle,
  measureRadius,
  measureRadialClearance,
  measureCircle3Point,
  measureArc3Point,
  measurePointLineOffset,
  measurePolylineStation,
  locatePolylineStation,
  dividePolyline,
  measureLineIntersection,
  measureParallelLineSpacing,
  measureSegmentClearance,
  measureArea,
  measureRectangle,
  measureOrientedRectangle,
  calibrateScale,
  setCoordinateOrigin,
  setCoordinateAxis,
  annotate,
}

enum _ViewerMenuAction {
  annotations,
  exportAnnotations,
  exportImage,
  exportPdf,
  layers,
  overview,
}

enum _QuantityLengthPurpose { volumeDepth, perimeterHeight, planRise }

class _CadCalibrationInput {
  const _CadCalibrationInput(this.length, this.unit);

  final double length;
  final CadEngineeringUnit unit;
}

class _CadCoordinateInput {
  const _CadCoordinateInput(this.x, this.y);

  final double x;
  final double y;
}

class _CadPolarInput {
  const _CadPolarInput(this.distance, this.azimuthDegrees);

  final double distance;
  final double azimuthDegrees;
}

class _CadTwoDistanceInput {
  const _CadTwoDistanceInput(this.firstDistance, this.secondDistance);

  final double firstDistance;
  final double secondDistance;
}

class _CadStationOffsetInput {
  const _CadStationOffsetInput(this.station, this.signedOffset);

  final double station;
  final double signedOffset;
}

class _CadDensityInput {
  const _CadDensityInput(this.value, this.unit);

  final double value;
  final CadDensityUnit unit;
}

class _CadAverageEndAreaInput {
  const _CadAverageEndAreaInput(this.secondArea, this.intervalLength);

  final double secondArea;
  final double intervalLength;
}

class _CadPrismoidalInput {
  const _CadPrismoidalInput(
    this.midpointArea,
    this.secondArea,
    this.intervalLength,
  );

  final double midpointArea;
  final double secondArea;
  final double intervalLength;
}

class _CadCoverageInput {
  const _CadCoverageInput(this.coveragePerUnit, this.wastePercent);

  final double coveragePerUnit;
  final double wastePercent;
}

class _CadLinearQuantityInput {
  const _CadLinearQuantityInput(this.lengthPerUnit, this.wastePercent);

  final double lengthPerUnit;
  final double wastePercent;
}

String _densityUnitSymbol(CadDensityUnit unit) => switch (unit) {
  CadDensityUnit.kilogramsPerCubicMeter => 'kg/m³',
  CadDensityUnit.tonnesPerCubicMeter => 't/m³',
  CadDensityUnit.poundsPerCubicFoot => 'lb/ft³',
};

const int _maximumCoordinateCollectionPoints = 200;

String cadPropertiesClipboardText(
  String title,
  List<({String label, String value})> rows,
) => '$title\n${rows.map((row) => '${row.label}: ${row.value}').join('\n')}';

String formatEngineeringValue(double value, int decimalPlaces) {
  final precision = decimalPlaces.clamp(0, 6).toInt();
  final formatted = value.toStringAsFixed(precision);
  final zero = 0.0.toStringAsFixed(precision);
  return formatted == '-$zero' ? zero : formatted;
}

class CadViewerPage extends StatefulWidget {
  const CadViewerPage({
    required this.engine,
    required this.opened,
    this.decimalPlaces = 3,
    super.key,
  });

  final CadEngine engine;
  final OpenedCadDocument opened;
  final int decimalPlaces;

  @override
  State<CadViewerPage> createState() => _CadViewerPageState();
}

class _CadViewerPageState extends State<CadViewerPage> {
  final GlobalKey _imageCaptureKey = GlobalKey();
  bool _exportingImage = false;
  bool _pdfExportReady = false;
  bool get _canExportImage =>
      !_exportingImage && (widget.opened.formatId != 'pdf' || _pdfExportReady);

  /// PDF documents are already pages; every other scene can be exported.
  bool get _canExportPdf => _canExportImage && widget.opened.formatId != 'pdf';

  /// Detected drawing sheets that image/PDF export splits on.
  List<CadDrawingFrame> get _sheetFrames =>
      _document.sceneKind == 'two_d' && widget.opened.formatId != 'pdf'
      ? _document.frames
      : const [];
  late CadDocumentModel _document = widget.opened.document;
  ViewerTool _tool = ViewerTool.pan;
  double _zoom = 1;
  double _startZoom = 1;
  Offset _pan = Offset.zero;
  Offset _startFocal = Offset.zero;
  BigInt? _selectedEntityId;
  BigInt? _selectedMeshId;
  CadHit? _hit;
  CadMeshHit? _meshHit;
  final List<Offset> _measurementPoints = [];
  final List<Offset> _coordinateCollectionPoints = [];
  final List<Offset> _areaBoundaryReportPoints = [];
  final List<bool> _areaPointIntersections = [];
  final Map<BigInt, double> _lengthEntityMeasurements = {};
  final Map<BigInt, CadAreaMeasurement2D> _areaEntityMeasurements = {};
  final Set<BigInt> _subtractedAreaEntityIds = {};
  bool _areaTakeoffSubtractMode = false;
  final List<CadPoint3> _measurement3DPoints = [];
  final List<({CadMeshHit hit, CadPoint3 normal})> _measurement3DFaces = [];
  CadMeshFaceRelation3D? _faceRelationMeasurement;
  late List<CadTextAnnotation> _annotations = widget.opened.annotations;
  double? _measurement;
  double? _measurementPerimeter;
  Offset? _measurementCentroid;
  BigInt? _measuredAreaEntityId;
  BigInt? _stationBaselineEntityId;
  CadStationBaseline2D? _stationBaseline;
  CadPolylineStationMeasurement2D? _stationMeasurement;
  CadPolylineStakeoutMeasurement2D? _stationStakeoutMeasurement;
  CadPolylineDivisionMeasurement2D? _polylineDivisionMeasurement;
  Offset? _polarStakeoutOriginWorld;
  CadPolarStakeoutMeasurement2D? _polarStakeoutMeasurement;
  CadTwoDistanceLocation2D? _twoDistanceLocation;
  BigInt? _intersectionFirstEntityId;
  CadLineSegment2D? _intersectionFirstSegment;
  CadLineIntersectionMeasurement2D? _lineIntersectionMeasurement;
  CadParallelLineSpacingMeasurement2D? _parallelLineSpacingMeasurement;
  CadSegmentClearanceMeasurement2D? _segmentClearanceMeasurement;
  final Set<BigInt> _lineIntersectionEntityIds = {};
  BigInt? _radialClearanceFirstEntityId;
  CadRadialMeasurement2D? _radialClearanceFirst;
  CadRadialClearanceMeasurement2D? _radialClearanceMeasurement;
  final Set<BigInt> _radialClearanceEntityIds = {};
  CadLocalCoordinateFrame2D? _localFrame2D;
  CadPoint3? _localOrigin3D;
  Offset? get _localOrigin2D => _localFrame2D?.origin;
  double _yaw = -0.75;
  double _pitch = 0.55;
  double _startYaw = -0.75;
  double _startPitch = 0.55;
  double _startGestureScale = 1;
  int _gesturePointerCount = 0;
  Offset? _scaleAnchor2D;
  CadPoint3? _scaleAnchor3D;
  bool _isInteracting = false;
  Offset? _precisionPosition;
  CadSnap? _precisionSnap;
  int _precisionRequest = 0;
  int _activePointers = 0;

  bool get _canPrecisionPick =>
      _tool != ViewerTool.pan && _tool != ViewerTool.annotate;

  // Entity commands must retain the touched position: snapping to a circle's
  // center, for example, would make its circumference impossible to select.
  bool get _picksGeometryPoint => switch (_tool) {
    ViewerTool.pan ||
    ViewerTool.select ||
    ViewerTool.annotate ||
    ViewerTool.measureRadius ||
    ViewerTool.measureRadialClearance ||
    ViewerTool.measureEntityLength ||
    ViewerTool.measureEntityArea ||
    ViewerTool.locatePolylineStation ||
    ViewerTool.dividePolyline ||
    ViewerTool.measureLineIntersection ||
    ViewerTool.measureParallelLineSpacing ||
    ViewerTool.measureSegmentClearance ||
    ViewerTool.measureFaceAngle => false,
    ViewerTool.measurePolylineStation => _stationBaseline != null,
    _ => true,
  };

  void _cancelPrecisionPick() {
    _precisionRequest++;
    _precisionPosition = null;
    _precisionSnap = null;
  }

  Future<void> _previewPrecisionPick(Offset local, Size size) async {
    if (!_canPrecisionPick || _activePointers > 1) return;
    final request = ++_precisionRequest;
    final position = Offset(
      local.dx.clamp(0.0, size.width),
      local.dy.clamp(0.0, size.height),
    );
    setState(() {
      _precisionPosition = position;
      _precisionSnap = null;
    });
    if (_document.sceneKind != 'two_d' || !_picksGeometryPoint) return;
    final transform = CadViewTransform.forScene(_document, size, _zoom, _pan);
    final world = transform.screenToWorld(position);
    try {
      // Keep the aperture at 18 visible pixels inside the 3x loupe.
      final snap = _tool == ViewerTool.measureArea
          ? await _snapAreaWorldPoint(world, transform, aperture: 6)
          : await _snapWorldPoint(world, transform, aperture: 6);
      if (!mounted || request != _precisionRequest) return;
      setState(() => _precisionSnap = snap);
    } catch (_) {
      // Free picking remains available if a native snap query fails.
    }
  }

  Future<void> _finishPrecisionPick(Offset local, Size size) async {
    if (_precisionPosition == null) return;
    final tool = _tool;
    final preview = _previewPrecisionPick(local, size);
    final request = _precisionRequest;
    await preview;
    if (!mounted || request != _precisionRequest || tool != _tool) return;
    final position = _precisionPosition;
    final snap = _precisionSnap;
    setState(_cancelPrecisionPick);
    if (position != null) {
      await _onTap(position, size, precise: true, snap: snap);
    }
  }

  Widget _buildPrecisionLoupe(Size size) {
    final position = _precisionPosition!;
    final diameter = math.min(144.0, math.min(size.width, size.height));
    final radius = diameter / 2;
    final center = Offset(
      position.dx.clamp(radius, size.width - radius),
      (position.dy >= diameter + 36
              ? position.dy - radius - 36
              : position.dy + radius + 36)
          .clamp(radius, size.height - radius),
    );
    final snapped = _precisionSnap;
    final target = snapped == null
        ? position
        : CadViewTransform.forScene(
            _document,
            size,
            _zoom,
            _pan,
          ).worldToScreen(snapped.position);
    return Positioned(
      left: center.dx - radius,
      top: center.dy - radius,
      child: IgnorePointer(
        child: RawMagnifier(
          key: const ValueKey('measurement_precision_loupe'),
          size: Size.square(diameter),
          magnificationScale: 3,
          focalPointOffset: position - center,
          decoration: const MagnifierDecoration(
            shape: CircleBorder(
              side: BorderSide(color: Colors.white, width: 2),
            ),
          ),
          child: Stack(
            children: [
              Center(child: Icon(Icons.add, color: Colors.white, size: 24)),
              if (snapped != null)
                Positioned(
                  left: radius + (target.dx - position.dx) * 3 - 9,
                  top: radius + (target.dy - position.dy) * 3 - 9,
                  child: const Icon(
                    Icons.crop_square,
                    size: 18,
                    color: Color(0xff66ff99),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Size _viewportSize = Size.zero;
  int _viewportRequest = 0;
  bool _initialViewportRequested = false;
  bool _viewportRefreshScheduled = false;
  bool _visibilityUpdating = false;
  Timer? _interactionViewportTimer;
  bool _viewerChromeVisible = false;
  late final CadEngineeringUnit? _sourceUnit;
  CadEngineeringUnit? _displayUnit;
  CadEngineeringUnit? _calibrationUnit;
  double? _calibrationMetersPerDrawingUnit;

  @override
  void initState() {
    super.initState();
    _sourceUnit = cadEngineeringUnitById(_document.units);
    _displayUnit = _sourceUnit;
    unawaited(_applySystemUi());
  }

  Future<void> _applySystemUi() => SystemChrome.setEnabledSystemUIMode(
    _viewerChromeVisible
        ? SystemUiMode.edgeToEdge
        : SystemUiMode.immersiveSticky,
  );

  void _toggleViewerChrome() {
    setState(() => _viewerChromeVisible = !_viewerChromeVisible);
    unawaited(_applySystemUi());
  }

  @override
  void dispose() {
    _cancelPrecisionPick();
    _interactionViewportTimer?.cancel();
    widget.engine.closeDocument(widget.opened.sessionId);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _resetView() {
    _cancelPrecisionPick();
    final orientation = cadStandardViewOrientation(CadStandardView.isometric);
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
      _yaw = orientation.yaw;
      _pitch = orientation.pitch;
    });
    unawaited(_refreshViewport());
  }

  void _onScaleStart(ScaleStartDetails details, Size size) {
    _cancelPrecisionPick();
    _gesturePointerCount = details.pointerCount;
    _startGestureScale = 1;
    _captureGestureBaseline(details.localFocalPoint, size);
    setState(() => _isInteracting = true);
  }

  void _captureGestureBaseline(Offset focalPoint, Size size) {
    _startZoom = _zoom;
    _startFocal = focalPoint;
    _startYaw = _yaw;
    _startPitch = _pitch;
    if (_document.sceneKind == 'three_d') {
      _scaleAnchor3D = Cad3DViewTransform.forScene(
        _document,
        size,
        _zoom,
        _pan,
        _yaw,
        _pitch,
      ).screenPlanePoint(focalPoint);
      _scaleAnchor2D = null;
    } else if (_document.sceneKind == 'two_d') {
      _scaleAnchor2D = CadViewTransform.forScene(
        _document,
        size,
        _zoom,
        _pan,
      ).screenToWorld(focalPoint);
      _scaleAnchor3D = null;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size size) {
    if (details.pointerCount != _gesturePointerCount) {
      _gesturePointerCount = details.pointerCount;
      _startGestureScale = details.scale;
      _captureGestureBaseline(details.localFocalPoint, size);
      return;
    }
    final scaleFactor = details.scale / _startGestureScale;
    if (_document.sceneKind == 'three_d') {
      if (_tool != ViewerTool.pan && details.pointerCount == 1) return;
      setState(() {
        if (details.pointerCount == 1) {
          final drag = details.localFocalPoint - _startFocal;
          _yaw = _startYaw - drag.dx * 0.01;
          _pitch = (_startPitch + drag.dy * 0.01).clamp(-1.5, 1.5);
        } else {
          _zoom = (_startZoom * scaleFactor).clamp(0.05, 100);
          final anchor = _scaleAnchor3D;
          if (anchor != null) {
            _pan = Cad3DViewTransform.panForAnchor(
              _document,
              size,
              _zoom,
              _startYaw,
              _startPitch,
              anchor,
              details.localFocalPoint,
            );
          }
        }
      });
      return;
    }
    if (_tool != ViewerTool.pan && details.pointerCount == 1) return;
    setState(() {
      _zoom = (_startZoom * scaleFactor).clamp(0.05, 100);
      final anchor = _scaleAnchor2D;
      if (anchor != null) {
        _pan = CadViewTransform.panForAnchor(
          _document,
          size,
          _zoom,
          anchor,
          details.localFocalPoint,
        );
      }
    });
    _scheduleInteractiveViewportRefresh();
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _interactionViewportTimer?.cancel();
    if (_isInteracting) setState(() => _isInteracting = false);
    unawaited(_refreshViewport());
  }

  Future<void> _refreshViewport({bool propagateFailure = false}) async {
    if (_document.sceneKind != 'two_d' || _viewportSize.isEmpty) return;
    final transform = CadViewTransform.forScene(
      _document,
      _viewportSize,
      _zoom,
      _pan,
    );
    final first = transform.screenToWorld(Offset.zero);
    final second = transform.screenToWorld(
      Offset(_viewportSize.width, _viewportSize.height),
    );
    final bounds = Rect.fromLTRB(
      math.min(first.dx, second.dx),
      math.min(first.dy, second.dy),
      math.max(first.dx, second.dx),
      math.max(first.dy, second.dy),
    );
    // Retain a generous guard band and refresh it during a drag. This prevents
    // geometry entering from any edge from disappearing until gesture end.
    final padding = math.max(bounds.width, bounds.height) * 0.5;
    final request = ++_viewportRequest;
    try {
      final updated = await widget.engine.loadViewport(
        widget.opened.sessionId,
        bounds.inflate(padding),
      );
      if (!mounted || request != _viewportRequest) return;
      setState(() => _document = updated);
    } catch (_) {
      if (propagateFailure) rethrow;
      // Keep the last valid retained batch if a viewport refresh is cancelled
      // by navigation or a native session shutdown.
    }
  }

  void _scheduleInteractiveViewportRefresh() {
    if (_document.sceneKind != 'two_d' ||
        (_interactionViewportTimer?.isActive ?? false)) {
      return;
    }
    _interactionViewportTimer = Timer(const Duration(milliseconds: 90), () {
      if (mounted && _isInteracting) unawaited(_refreshViewport());
    });
  }

  void _scheduleViewportRefresh() {
    if (_viewportRefreshScheduled) return;
    _viewportRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportRefreshScheduled = false;
      if (mounted && !_isInteracting) unawaited(_refreshViewport());
    });
  }

  Future<void> _onTap(
    Offset local,
    Size size, {
    bool precise = false,
    CadSnap? snap,
  }) async {
    if (_tool == ViewerTool.pan) {
      if (!_isInteracting) _toggleViewerChrome();
      return;
    }
    if (_document.sceneKind == 'three_d') {
      final transform = Cad3DViewTransform.forScene(
        _document,
        size,
        _zoom,
        _pan,
        _yaw,
        _pitch,
      );
      final hit = transform.hitTest(_document, local);
      if (!mounted) return;
      if (_tool == ViewerTool.select) {
        setState(() {
          _meshHit = hit;
          _selectedMeshId = hit?.meshId;
        });
        if (hit != null) await _showMeshProperties(hit);
      } else if (_tool == ViewerTool.annotate) {
        if (hit != null) await _addAnnotation3D(hit);
      } else if (_tool == ViewerTool.setCoordinateOrigin && hit != null) {
        setState(() {
          _localOrigin3D = hit.position;
          _tool = ViewerTool.measureCoordinate;
          _measurement3DPoints.clear();
          _measurement = null;
        });
        _showLocalOriginSetMessage();
      } else if (_tool == ViewerTool.calibrateScale && hit != null) {
        double? drawingDistance;
        setState(() {
          if (_measurement3DPoints.length == 2) {
            _measurement3DPoints.clear();
          }
          _measurement3DPoints.add(hit.position);
          _measurement = null;
          if (_measurement3DPoints.length == 2) {
            final first = _measurement3DPoints[0];
            final second = _measurement3DPoints[1];
            drawingDistance = widget.engine.measureDistance3D(
              first.x,
              first.y,
              first.z,
              second.x,
              second.y,
              second.z,
            );
          }
        });
        if (drawingDistance != null) {
          await _requestScaleCalibration(drawingDistance!);
        }
      } else if (_tool == ViewerTool.measureCoordinate && hit != null) {
        setState(() {
          _measurement3DPoints
            ..clear()
            ..add(hit.position);
          _measurement = null;
        });
      } else if (_tool == ViewerTool.measure && hit != null) {
        setState(() {
          if (_measurement3DPoints.length == 2) {
            _measurement3DPoints.clear();
            _measurement = null;
          }
          _measurement3DPoints.add(hit.position);
          if (_measurement3DPoints.length == 2) {
            final first = _measurement3DPoints[0];
            final second = _measurement3DPoints[1];
            _measurement = widget.engine.measureDistance3D(
              first.x,
              first.y,
              first.z,
              second.x,
              second.y,
              second.z,
            );
          }
        });
      } else if (_tool == ViewerTool.measureFaceAngle && hit != null) {
        final normal = _meshFaceMetrics(hit)?.normal;
        if (normal == null) {
          _showViewerMessage(context.l10n.text('invalidFaceAngleFace'));
          return;
        }
        setState(() {
          if (_measurement3DFaces.length == 2) {
            _measurement3DFaces.clear();
            _measurement3DPoints.clear();
          }
          _measurement3DFaces.add((hit: hit, normal: normal));
          _measurement3DPoints.add(hit.position);
          _faceRelationMeasurement = _measurement3DFaces.length == 2
              ? cadMeshFaceRelation3D(
                  _measurement3DFaces[0].hit.position,
                  _measurement3DFaces[0].normal,
                  _measurement3DFaces[1].hit.position,
                  _measurement3DFaces[1].normal,
                )
              : null;
          _measurement = _faceRelationMeasurement?.angleDegrees;
        });
      } else if (_tool == ViewerTool.measureAngle && hit != null) {
        setState(() {
          if (_measurement3DPoints.length == 3) {
            _measurement3DPoints.clear();
            _measurement = null;
          }
          _measurement3DPoints.add(hit.position);
          if (_measurement3DPoints.length == 3) {
            _measurement = angleDegrees3D(
              _measurement3DPoints[0],
              _measurement3DPoints[1],
              _measurement3DPoints[2],
            );
          }
        });
      }
      return;
    }
    if (_document.sceneKind != 'two_d') return;
    final transform = CadViewTransform.forScene(_document, size, _zoom, _pan);
    var world = transform.screenToWorld(local);
    if (_tool == ViewerTool.annotate) {
      await _addAnnotation(world);
      return;
    }
    if (_tool == ViewerTool.select) {
      final hit = await widget.engine.hitTest(
        widget.opened.sessionId,
        world.dx,
        world.dy,
        12 / transform.scale,
      );
      if (!mounted) return;
      setState(() {
        _hit = hit;
        _selectedEntityId = hit?.entityId;
      });
      if (hit != null) await _showEntityProperties(hit);
      return;
    }
    if (_tool == ViewerTool.measureRadius) {
      await _measureRadiusAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureRadialClearance) {
      await _measureRadialClearanceAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureEntityLength) {
      await _toggleEntityLengthAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureEntityArea) {
      await _toggleEntityAreaAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measurePolylineStation) {
      await _measurePolylineStationAt(
        world,
        transform,
        precise: precise,
        resolvedSnap: snap,
      );
      return;
    }
    if (_tool == ViewerTool.locatePolylineStation) {
      await _locatePolylineStationAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.dividePolyline) {
      await _dividePolylineAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureLineIntersection) {
      await _measureLineIntersectionAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureParallelLineSpacing) {
      await _measureParallelLineSpacingAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureSegmentClearance) {
      await _measureSegmentClearanceAt(world, transform);
      return;
    }
    if (_tool == ViewerTool.measureArea) {
      if (!precise) snap = await _snapAreaWorldPoint(world, transform);
      if (!mounted) return;
      // An intersection is an intentional engineering pick. Give it priority
      // over the one-tap closed-boundary shortcut when both are under the tap.
      if (_measurementPoints.isEmpty &&
          snap?.kind != 'intersection' &&
          await _measureClosedAreaAt(world, transform)) {
        return;
      }
      if (!mounted) return;
    }
    if (_tool == ViewerTool.measureCoordinate ||
        _tool == ViewerTool.collectCoordinates ||
        _tool == ViewerTool.locatePolarPoint ||
        _tool == ViewerTool.locateTwoDistances ||
        _tool == ViewerTool.measure ||
        _tool == ViewerTool.measurePath ||
        _tool == ViewerTool.measureAngle ||
        _tool == ViewerTool.measureCircle3Point ||
        _tool == ViewerTool.measureArc3Point ||
        _tool == ViewerTool.measurePointLineOffset ||
        _tool == ViewerTool.measureArea ||
        _tool == ViewerTool.measureRectangle ||
        _tool == ViewerTool.measureOrientedRectangle ||
        _tool == ViewerTool.calibrateScale ||
        _tool == ViewerTool.setCoordinateOrigin ||
        _tool == ViewerTool.setCoordinateAxis) {
      final snapped =
          snap ?? (precise ? null : await _snapWorldPoint(world, transform));
      if (!mounted) return;
      world = snapped?.position ?? world;
      snap = snapped;
    }
    if (_tool == ViewerTool.measureCoordinate) {
      setState(() {
        _measurementPoints
          ..clear()
          ..add(world);
        _measurement = null;
      });
      return;
    }
    if (_tool == ViewerTool.collectCoordinates) {
      if (_coordinateCollectionPoints.length >=
          _maximumCoordinateCollectionPoints) {
        _showViewerMessage(
          context.l10n.text('coordinateCollectionLimit', {
            'maximum': _maximumCoordinateCollectionPoints,
          }),
        );
        return;
      }
      if (_coordinateCollectionPoints.contains(world)) {
        _showViewerMessage(context.l10n.text('coordinateAlreadyCollected'));
        return;
      }
      setState(() {
        _coordinateCollectionPoints.add(world);
        _measurement = _coordinateCollectionPoints.length.toDouble();
      });
      return;
    }
    if (_tool == ViewerTool.locatePolarPoint) {
      setState(() {
        _polarStakeoutOriginWorld = world;
        _polarStakeoutMeasurement = null;
        _measurementPoints
          ..clear()
          ..add(world);
        _measurement = null;
      });
      await _requestPolarStakeoutLocation();
      return;
    }
    if (_tool == ViewerTool.locateTwoDistances) {
      if (_measurementPoints.length == 1 && _measurementPoints.first == world) {
        _showViewerMessage(context.l10n.text('distinctTwoDistanceReferences'));
        return;
      }
      var requestDistances = false;
      setState(() {
        if (_twoDistanceLocation != null || _measurementPoints.length >= 2) {
          _measurementPoints.clear();
          _twoDistanceLocation = null;
          _measurement = null;
        }
        _measurementPoints.add(world);
        requestDistances = _measurementPoints.length == 2;
      });
      if (requestDistances) await _requestTwoDistanceLocation();
      return;
    }
    if (_tool == ViewerTool.setCoordinateOrigin) {
      setState(() {
        _localFrame2D = CadLocalCoordinateFrame2D.axisAligned(world);
        _tool = ViewerTool.measureCoordinate;
        _measurementPoints.clear();
        _measurement = null;
      });
      _showLocalOriginSetMessage();
      return;
    }
    if (_tool == ViewerTool.setCoordinateAxis) {
      if (_measurementPoints.isEmpty) {
        setState(() => _measurementPoints.add(world));
        return;
      }
      final frame = CadLocalCoordinateFrame2D.fromOriginAndXAxis(
        _measurementPoints.first,
        world,
      );
      if (frame == null) {
        _showViewerMessage(context.l10n.text('invalidLocalAxisDirection'));
        return;
      }
      setState(() {
        _localFrame2D = frame;
        _tool = ViewerTool.measureCoordinate;
        _measurementPoints.clear();
        _measurement = null;
      });
      _showViewerMessage(context.l10n.text('localAxisSet'));
      return;
    }
    if (_tool == ViewerTool.calibrateScale) {
      setState(() {
        if (_measurementPoints.length == 2) {
          _measurementPoints.clear();
        }
        _measurementPoints.add(world);
        _measurement = null;
      });
      if (_measurementPoints.length == 2) {
        final drawingDistance = widget.engine.measureDistance(
          _measurementPoints[0].dx,
          _measurementPoints[0].dy,
          _measurementPoints[1].dx,
          _measurementPoints[1].dy,
        );
        await _requestScaleCalibration(drawingDistance);
      }
      return;
    }
    if (_tool == ViewerTool.measureArea) {
      setState(() {
        _measurementPerimeter = null;
        _measuredAreaEntityId = null;
        _areaBoundaryReportPoints.clear();
        _measurementPoints.add(world);
        _areaPointIntersections.add(snap?.kind == 'intersection');
        _measurement = _measurementPoints.length >= 3
            ? widget.engine.measureArea(_measurementPoints)
            : null;
        _measurementCentroid = _measurement == null
            ? null
            : cadPolygonCentroid2D(_measurementPoints);
      });
      return;
    }
    if (_tool == ViewerTool.measureRectangle) {
      setState(() {
        if (_measurementPoints.length == 2) {
          _measurementPoints.clear();
        }
        _measurementPoints.add(world);
        final rectangle = _measurementPoints.length == 2
            ? cadRectangleMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
              )
            : null;
        _measurement = rectangle?.area;
        _measurementPerimeter = rectangle?.perimeter;
      });
      return;
    }
    if (_tool == ViewerTool.measureOrientedRectangle) {
      if (_measurementPoints.length == 1 &&
          (world - _measurementPoints.first).distance <= 1e-12) {
        _showViewerMessage(context.l10n.text('invalidOrientedRectangle'));
        return;
      }
      if (_measurementPoints.length == 2 &&
          cadOrientedRectangleMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                world,
              ) ==
              null) {
        _showViewerMessage(context.l10n.text('invalidOrientedRectangle'));
        return;
      }
      setState(() {
        if (_measurementPoints.length == 3) {
          _measurementPoints.clear();
        }
        _measurementPoints.add(world);
        final rectangle = _measurementPoints.length == 3
            ? cadOrientedRectangleMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                _measurementPoints[2],
              )
            : null;
        _measurement = rectangle?.area;
        _measurementPerimeter = rectangle?.perimeter;
      });
      return;
    }
    if (_tool == ViewerTool.measureCircle3Point) {
      if (_measurementPoints.length == 1 &&
          (world - _measurementPoints.first).distance <= 1e-12) {
        _showViewerMessage(context.l10n.text('invalidThreePointCircle'));
        return;
      }
      if (_measurementPoints.length == 2 &&
          cadThreePointCircleMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                world,
              ) ==
              null) {
        _showViewerMessage(context.l10n.text('invalidThreePointCircle'));
        return;
      }
      setState(() {
        if (_measurementPoints.length == 3) {
          _measurementPoints.clear();
        }
        _measurementPoints.add(world);
        final circle = _measurementPoints.length == 3
            ? cadThreePointCircleMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                _measurementPoints[2],
              )
            : null;
        _measurement = circle?.radius;
        _measurementPerimeter = circle?.circumference;
      });
      return;
    }
    if (_tool == ViewerTool.measureArc3Point) {
      if (_measurementPoints.length == 1 &&
          (world - _measurementPoints.first).distance <= 1e-12) {
        _showViewerMessage(context.l10n.text('invalidThreePointArc'));
        return;
      }
      if (_measurementPoints.length == 2 &&
          cadThreePointArcMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                world,
              ) ==
              null) {
        _showViewerMessage(context.l10n.text('invalidThreePointArc'));
        return;
      }
      setState(() {
        if (_measurementPoints.length == 3) {
          _measurementPoints.clear();
        }
        _measurementPoints.add(world);
        final arc = _measurementPoints.length == 3
            ? cadThreePointArcMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                _measurementPoints[2],
              )
            : null;
        _measurement = arc?.arcLength;
        _measurementPerimeter = null;
      });
      return;
    }
    if (_tool == ViewerTool.measurePointLineOffset) {
      if (_measurementPoints.length == 1 &&
          cadPointLineMeasurement2D(_measurementPoints.first, world, world) ==
              null) {
        _showViewerMessage(context.l10n.text('invalidBaseline'));
        return;
      }
      setState(() {
        if (_measurementPoints.length == 3) {
          _measurementPoints.clear();
        }
        _measurementPoints.add(world);
        final offset = _measurementPoints.length == 3
            ? cadPointLineMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                _measurementPoints[2],
              )
            : null;
        _measurement = offset?.perpendicularDistance;
        _measurementPerimeter = null;
      });
      return;
    }
    if (_tool == ViewerTool.measurePath) {
      setState(() {
        _measurementPoints.add(world);
        _measurement = _measurementPoints.length >= 2
            ? widget.engine.measurePath(_measurementPoints)
            : null;
      });
      return;
    }
    if (_tool == ViewerTool.measureAngle) {
      if (_measurementPoints.length == 3) {
        setState(() {
          _measurementPoints
            ..clear()
            ..add(world);
          _measurement = null;
        });
        return;
      }
      if (_measurementPoints.length == 1 &&
          cadTriangleMeasurement2D(_measurementPoints.first, world, world) ==
              null) {
        _showViewerMessage(context.l10n.text('invalidAnglePoint'));
        return;
      }
      final triangle = _measurementPoints.length == 2
          ? cadTriangleMeasurement2D(
              _measurementPoints[0],
              _measurementPoints[1],
              world,
            )
          : null;
      if (_measurementPoints.length == 2 && triangle == null) {
        _showViewerMessage(context.l10n.text('invalidAnglePoint'));
        return;
      }
      setState(() {
        _measurementPoints.add(world);
        _measurement = triangle?.angleDegrees;
      });
      return;
    }
    setState(() {
      if (_measurementPoints.length == 2) {
        _measurementPoints.clear();
        _measurement = null;
      }
      _measurementPoints.add(world);
      if (_measurementPoints.length == 2) {
        _measurement = widget.engine.measureDistance(
          _measurementPoints[0].dx,
          _measurementPoints[0].dy,
          _measurementPoints[1].dx,
          _measurementPoints[1].dy,
        );
      }
    });
  }

  Future<CadSnap?> _snapWorldPoint(
    Offset world,
    CadViewTransform transform, {
    double aperture = 18,
  }) => widget.engine.snap(
    widget.opened.sessionId,
    world.dx,
    world.dy,
    aperture / transform.scale,
  );

  Future<CadSnap?> _snapAreaWorldPoint(
    Offset world,
    CadViewTransform transform, {
    double aperture = 18,
  }) async {
    final tolerance = aperture / transform.scale;
    final intersection = await widget.engine.snapIntersection(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      tolerance,
    );
    return intersection ??
        widget.engine.snap(
          widget.opened.sessionId,
          world.dx,
          world.dy,
          tolerance,
        );
  }

  Future<void> _measureRadiusAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity =
        hit != null && (hit.entityKind == 'circle' || hit.entityKind == 'arc')
        ? _entityById(hit.entityId)
        : null;
    final geometry = entity?['geometry'];
    final radial = geometry is Map<String, dynamic>
        ? cadRadialEntityMeasurement2D(geometry)
        : null;
    if (radial == null) {
      setState(() {
        _measurement = null;
        _measurementPoints.clear();
        _selectedEntityId = null;
      });
      return;
    }
    final direction = world - radial.center;
    final angle = direction.distanceSquared == 0
        ? 0.0
        : math.atan2(direction.dy, direction.dx);
    final circumference =
        radial.center +
        Offset(math.cos(angle), math.sin(angle)) * radial.radius;
    setState(() {
      _measurement = radial.radius;
      _measurementPoints
        ..clear()
        ..addAll([radial.center, circumference]);
      _selectedEntityId = hit!.entityId;
    });
  }

  Future<void> _measureRadialClearanceAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final radial = geometry is Map<String, dynamic>
        ? cadRadialEntityMeasurement2D(geometry)
        : null;
    if (hit == null || radial == null) {
      _showViewerMessage(context.l10n.text('unsupportedRadialClearanceEntity'));
      return;
    }

    final first = _radialClearanceFirst;
    if (first == null || _radialClearanceMeasurement != null) {
      setState(() {
        _radialClearanceFirstEntityId = hit.entityId;
        _radialClearanceFirst = radial;
        _radialClearanceMeasurement = null;
        _radialClearanceEntityIds
          ..clear()
          ..add(hit.entityId);
        _measurementPoints
          ..clear()
          ..add(radial.center);
        _measurement = null;
      });
      return;
    }
    if (_radialClearanceFirstEntityId == hit.entityId) {
      _showViewerMessage(context.l10n.text('sameRadialClearanceEntity'));
      return;
    }
    final measurement = cadRadialClearanceMeasurement2D(first, radial);
    if (measurement == null) {
      _showViewerMessage(context.l10n.text('unsupportedRadialClearanceEntity'));
      return;
    }
    setState(() {
      _radialClearanceMeasurement = measurement;
      _radialClearanceEntityIds.add(hit.entityId);
      _measurementPoints
        ..clear()
        ..addAll([first.center, radial.center]);
      _measurement = measurement.signedClearance;
    });
  }

  Future<void> _toggleEntityLengthAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final length = geometry is Map<String, dynamic>
        ? cadMeasurableEntityLength2D(geometry)
        : null;
    if (hit == null || length == null) {
      _showViewerMessage(context.l10n.text('unsupportedLengthEntity'));
      return;
    }
    setState(() {
      if (_lengthEntityMeasurements.containsKey(hit.entityId)) {
        _lengthEntityMeasurements.remove(hit.entityId);
      } else {
        _lengthEntityMeasurements[hit.entityId] = length;
      }
      _measurement = _selectedEntityLengthTotal();
      _selectedEntityId = null;
    });
  }

  double? _selectedEntityLengthTotal() {
    return _compensatedTotal(_lengthEntityMeasurements.values);
  }

  double? _compensatedTotal(Iterable<double> values) {
    if (values.isEmpty) return null;
    var sum = 0.0;
    var compensation = 0.0;
    for (final value in values) {
      final corrected = value - compensation;
      final updated = sum + corrected;
      compensation = (updated - sum) - corrected;
      sum = updated;
    }
    return sum;
  }

  Future<void> _toggleEntityAreaAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final area = geometry is Map<String, dynamic>
        ? cadClosedEntityAreaMeasurement2D(geometry)
        : null;
    if (hit == null || area == null) {
      _showViewerMessage(context.l10n.text('unsupportedAreaEntity'));
      return;
    }
    setState(() {
      if (_areaEntityMeasurements.containsKey(hit.entityId)) {
        _areaEntityMeasurements.remove(hit.entityId);
        _subtractedAreaEntityIds.remove(hit.entityId);
      } else {
        _areaEntityMeasurements[hit.entityId] = area;
        if (_areaTakeoffSubtractMode) {
          _subtractedAreaEntityIds.add(hit.entityId);
        } else {
          _subtractedAreaEntityIds.remove(hit.entityId);
        }
      }
      _updateAreaTakeoffTotals();
      _selectedEntityId = null;
    });
  }

  double _areaTakeoffAddedTotal() =>
      _compensatedTotal(
        _areaEntityMeasurements.entries
            .where((entry) => !_subtractedAreaEntityIds.contains(entry.key))
            .map((entry) => entry.value.area),
      ) ??
      0;

  double _areaTakeoffDeductedTotal() =>
      _compensatedTotal(
        _areaEntityMeasurements.entries
            .where((entry) => _subtractedAreaEntityIds.contains(entry.key))
            .map((entry) => entry.value.area),
      ) ??
      0;

  void _updateAreaTakeoffTotals() {
    if (_areaEntityMeasurements.isEmpty) {
      _measurement = null;
      _measurementPerimeter = null;
      return;
    }
    _measurement = _areaTakeoffAddedTotal() - _areaTakeoffDeductedTotal();
    _measurementPerimeter = _compensatedTotal(
      _areaEntityMeasurements.values.map((item) => item.perimeter),
    );
  }

  void _toggleAreaTakeoffMode() {
    setState(() => _areaTakeoffSubtractMode = !_areaTakeoffSubtractMode);
  }

  Future<void> _measurePolylineStationAt(
    Offset world,
    CadViewTransform transform, {
    bool precise = false,
    CadSnap? resolvedSnap,
  }) async {
    if (_stationBaseline == null) {
      final hit = await widget.engine.hitTest(
        widget.opened.sessionId,
        world.dx,
        world.dy,
        18 / transform.scale,
      );
      if (!mounted) return;
      final entity = hit == null ? null : _entityById(hit.entityId);
      final geometry = entity?['geometry'];
      final baseline = geometry is Map<String, dynamic>
          ? cadStationBaselineFromGeometry(geometry)
          : null;
      if (hit == null || baseline == null) {
        _showViewerMessage(context.l10n.text('unsupportedStationBaseline'));
        return;
      }
      setState(() {
        _stationBaselineEntityId = hit.entityId;
        _stationBaseline = baseline;
        _stationMeasurement = null;
        _measurement = null;
        _measurementPoints.clear();
        _selectedEntityId = hit.entityId;
      });
      return;
    }

    final snap = precise
        ? resolvedSnap
        : await _snapWorldPoint(world, transform);
    if (!mounted) return;
    final point = snap?.position ?? world;
    final baseline = _stationBaseline!;
    final measurement = cadStationMeasurement2D(baseline, point);
    if (measurement == null) {
      _showViewerMessage(context.l10n.text('invalidStationMeasurement'));
      return;
    }
    setState(() {
      _stationMeasurement = measurement;
      _measurement = measurement.perpendicularDistance;
      _measurementPoints
        ..clear()
        ..addAll([measurement.foot, measurement.point]);
    });
  }

  Future<void> _locatePolylineStationAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final baseline = geometry is Map<String, dynamic>
        ? cadStationBaselineFromGeometry(geometry)
        : null;
    if (hit == null || baseline == null) {
      _showViewerMessage(context.l10n.text('unsupportedStationBaseline'));
      return;
    }
    setState(() {
      _stationBaselineEntityId = hit.entityId;
      _stationBaseline = baseline;
      _stationMeasurement = null;
      _stationStakeoutMeasurement = null;
      _measurementPoints.clear();
      _measurement = null;
      _selectedEntityId = hit.entityId;
    });
    await _requestStationOffsetLocation();
  }

  Future<void> _requestStationOffsetLocation() async {
    final baseline = _stationBaseline;
    if (baseline == null) return;
    final zero = cadStationStakeoutMeasurement2D(baseline, 0, 0);
    if (zero == null) {
      _showViewerMessage(context.l10n.text('invalidStationMeasurement'));
      return;
    }
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final maximumStation = cadDrawingLengthToDisplayUnits(
      zero.totalLength,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    if (maximumStation == null) {
      _showViewerMessage(context.l10n.text('invalidStationMeasurement'));
      return;
    }
    final input = await showDialog<_CadStationOffsetInput>(
      context: context,
      builder: (_) => _StationOffsetLocationDialog(
        unitSymbol: _unitSymbol,
        totalLabel: _formatLinear(zero.totalLength),
        maximumStation: maximumStation,
      ),
    );
    if (input == null || !mounted) return;
    final station = cadDisplayLengthToDrawingUnits(
      input.station,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final signedOffset = cadDisplayLengthToDrawingUnits(
      input.signedOffset,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final measurement = station == null || signedOffset == null
        ? null
        : cadStationStakeoutMeasurement2D(baseline, station, signedOffset);
    if (measurement == null) {
      _showViewerMessage(
        context.l10n.text('stationOffsetOutOfRange', {
          'total': _formatLinear(zero.totalLength),
        }),
      );
      return;
    }
    Offset? centeredPan;
    if (!_viewportSize.isEmpty) {
      final candidate = CadViewTransform.panForAnchor(
        _document,
        _viewportSize,
        _zoom,
        measurement.targetPoint,
        _viewportSize.center(Offset.zero),
      );
      if (candidate.dx.isFinite && candidate.dy.isFinite) {
        centeredPan = candidate;
      }
    }
    setState(() {
      _stationStakeoutMeasurement = measurement;
      _stationMeasurement = null;
      _measurementPoints
        ..clear()
        ..addAll([measurement.basePoint, measurement.targetPoint]);
      _measurement = measurement.station;
      if (centeredPan != null) _pan = centeredPan;
    });
    _scheduleViewportRefresh();
  }

  Future<void> _requestPolarStakeoutLocation() async {
    final originWorld = _polarStakeoutOriginWorld;
    if (originWorld == null) return;
    final input = await showDialog<_CadPolarInput>(
      context: context,
      builder: (_) => _PolarStakeoutDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final distance = cadDisplayLengthToDrawingUnits(
      input.distance,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final frame = _localFrame2D;
    final originReference = frame?.worldToLocal(originWorld) ?? originWorld;
    final measurement = distance == null
        ? null
        : cadPolarStakeoutMeasurement2D(
            originReference,
            distance,
            input.azimuthDegrees,
          );
    final targetWorld = measurement == null
        ? null
        : frame?.localToWorld(measurement.target) ?? measurement.target;
    if (measurement == null ||
        targetWorld == null ||
        !targetWorld.dx.isFinite ||
        !targetWorld.dy.isFinite ||
        targetWorld == originWorld) {
      _showViewerMessage(context.l10n.text('invalidPolarStakeout'));
      return;
    }
    Offset? centeredPan;
    if (!_viewportSize.isEmpty) {
      final candidate = CadViewTransform.panForAnchor(
        _document,
        _viewportSize,
        _zoom,
        targetWorld,
        _viewportSize.center(Offset.zero),
      );
      if (candidate.dx.isFinite && candidate.dy.isFinite) {
        centeredPan = candidate;
      }
    }
    setState(() {
      _polarStakeoutMeasurement = measurement;
      _measurementPoints
        ..clear()
        ..addAll([originWorld, targetWorld]);
      _measurement = measurement.distance;
      if (centeredPan != null) _pan = centeredPan;
    });
    _scheduleViewportRefresh();
  }

  Future<void> _requestTwoDistanceLocation() async {
    if (_measurementPoints.length != 2) return;
    final firstReference = _measurementPoints[0];
    final secondReference = _measurementPoints[1];
    final input = await showDialog<_CadTwoDistanceInput>(
      context: context,
      builder: (_) => _TwoDistanceLocationDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final firstDistance = cadDisplayLengthToDrawingUnits(
      input.firstDistance,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final secondDistance = cadDisplayLengthToDrawingUnits(
      input.secondDistance,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final location = firstDistance == null || secondDistance == null
        ? null
        : cadTwoDistanceLocation2D(
            firstReference,
            secondReference,
            firstDistance,
            secondDistance,
          );
    if (location == null) {
      _showViewerMessage(context.l10n.text('twoDistanceNoSolution'));
      return;
    }
    final center = location.solutions.length == 1
        ? location.solutions.first
        : cadMidpoint2D(location.solutions.first, location.solutions.last);
    Offset? centeredPan;
    if (!_viewportSize.isEmpty) {
      final candidate = CadViewTransform.panForAnchor(
        _document,
        _viewportSize,
        _zoom,
        center,
        _viewportSize.center(Offset.zero),
      );
      if (candidate.dx.isFinite && candidate.dy.isFinite) {
        centeredPan = candidate;
      }
    }
    setState(() {
      _twoDistanceLocation = location;
      _measurement = location.firstDistance;
      if (centeredPan != null) _pan = centeredPan;
    });
    _scheduleViewportRefresh();
  }

  Future<void> _dividePolylineAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final baseline = geometry is Map<String, dynamic>
        ? cadStationBaselineFromGeometry(geometry)
        : null;
    if (hit == null || baseline == null) {
      _showViewerMessage(context.l10n.text('unsupportedStationBaseline'));
      return;
    }
    setState(() {
      _stationBaselineEntityId = hit.entityId;
      _stationBaseline = baseline;
      _stationMeasurement = null;
      _stationStakeoutMeasurement = null;
      _polylineDivisionMeasurement = null;
      _measurementPoints.clear();
      _measurement = null;
      _selectedEntityId = hit.entityId;
    });
    await _requestPolylineDivision();
  }

  Future<void> _requestPolylineDivision() async {
    final baseline = _stationBaseline;
    if (baseline == null) return;
    final divisions = await showDialog<int>(
      context: context,
      builder: (_) => const _PolylineDivisionDialog(),
    );
    if (divisions == null || !mounted) return;
    final measurement = cadStationDivisionMeasurement2D(baseline, divisions);
    if (measurement == null) {
      _showViewerMessage(context.l10n.text('invalidPolylineDivision'));
      return;
    }
    setState(() {
      _polylineDivisionMeasurement = measurement;
      _measurementPoints.clear();
      _measurement = measurement.intervalLength;
    });
  }

  Future<void> _measureLineIntersectionAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final segment = geometry is Map<String, dynamic>
        ? cadNearestLineSegmentFromGeometry(geometry, world)
        : null;
    if (hit == null || segment == null) {
      _showViewerMessage(context.l10n.text('unsupportedIntersectionSegment'));
      return;
    }

    final first = _intersectionFirstSegment;
    if (first == null || _lineIntersectionMeasurement != null) {
      setState(() {
        _intersectionFirstEntityId = hit.entityId;
        _intersectionFirstSegment = segment;
        _lineIntersectionMeasurement = null;
        _lineIntersectionEntityIds
          ..clear()
          ..add(hit.entityId);
        _measurementPoints
          ..clear()
          ..addAll([segment.start, segment.end]);
        _measurement = null;
      });
      return;
    }

    final measurement = cadLineIntersectionMeasurement2D(first, segment);
    if (measurement == null) {
      _showViewerMessage(context.l10n.text('parallelIntersectionSegments'));
      return;
    }
    setState(() {
      _lineIntersectionMeasurement = measurement;
      _lineIntersectionEntityIds.add(hit.entityId);
      _measurementPoints
        ..clear()
        ..addAll([
          first.start,
          first.end,
          segment.start,
          segment.end,
          measurement.intersection,
        ]);
      _measurement = measurement.includedAngleDegrees;
    });
  }

  Future<void> _measureParallelLineSpacingAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final segment = geometry is Map<String, dynamic>
        ? cadNearestLineSegmentFromGeometry(geometry, world)
        : null;
    if (hit == null || segment == null) {
      _showViewerMessage(context.l10n.text('unsupportedIntersectionSegment'));
      return;
    }

    final first = _intersectionFirstSegment;
    if (first == null || _parallelLineSpacingMeasurement != null) {
      setState(() {
        _intersectionFirstEntityId = hit.entityId;
        _intersectionFirstSegment = segment;
        _parallelLineSpacingMeasurement = null;
        _lineIntersectionMeasurement = null;
        _lineIntersectionEntityIds
          ..clear()
          ..add(hit.entityId);
        _measurementPoints
          ..clear()
          ..addAll([segment.start, segment.end]);
        _measurement = null;
      });
      return;
    }

    if (_intersectionFirstEntityId == hit.entityId &&
        first.segmentIndex == segment.segmentIndex) {
      _showViewerMessage(context.l10n.text('sameParallelSpacingSegment'));
      return;
    }
    final measurement = cadParallelLineSpacingMeasurement2D(first, segment);
    if (measurement == null) {
      _showViewerMessage(context.l10n.text('nonParallelSpacingSegments'));
      return;
    }
    setState(() {
      _parallelLineSpacingMeasurement = measurement;
      _lineIntersectionMeasurement = null;
      _lineIntersectionEntityIds.add(hit.entityId);
      _measurementPoints
        ..clear()
        ..addAll([
          first.start,
          first.end,
          segment.start,
          segment.end,
          measurement.firstFoot,
          measurement.secondFoot,
        ]);
      _measurement = measurement.spacing;
    });
  }

  Future<void> _measureSegmentClearanceAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final segment = geometry is Map<String, dynamic>
        ? cadNearestLineSegmentFromGeometry(geometry, world)
        : null;
    if (hit == null || segment == null) {
      _showViewerMessage(context.l10n.text('unsupportedIntersectionSegment'));
      return;
    }

    final first = _intersectionFirstSegment;
    if (first == null || _segmentClearanceMeasurement != null) {
      setState(() {
        _intersectionFirstEntityId = hit.entityId;
        _intersectionFirstSegment = segment;
        _segmentClearanceMeasurement = null;
        _lineIntersectionMeasurement = null;
        _parallelLineSpacingMeasurement = null;
        _lineIntersectionEntityIds
          ..clear()
          ..add(hit.entityId);
        _measurementPoints
          ..clear()
          ..addAll([segment.start, segment.end]);
        _measurement = null;
      });
      return;
    }

    if (_intersectionFirstEntityId == hit.entityId &&
        first.segmentIndex == segment.segmentIndex) {
      _showViewerMessage(context.l10n.text('sameClearanceSegment'));
      return;
    }
    final measurement = cadSegmentClearanceMeasurement2D(first, segment);
    if (measurement == null) {
      _showViewerMessage(context.l10n.text('invalidSegmentClearance'));
      return;
    }
    setState(() {
      _segmentClearanceMeasurement = measurement;
      _lineIntersectionMeasurement = null;
      _parallelLineSpacingMeasurement = null;
      _lineIntersectionEntityIds.add(hit.entityId);
      _measurementPoints
        ..clear()
        ..addAll([
          first.start,
          first.end,
          segment.start,
          segment.end,
          measurement.firstClosestPoint,
          measurement.secondClosestPoint,
        ]);
      _measurement = measurement.clearance;
    });
  }

  Future<bool> _measureClosedAreaAt(
    Offset world,
    CadViewTransform transform,
  ) async {
    final hit = await widget.engine.hitTest(
      widget.opened.sessionId,
      world.dx,
      world.dy,
      18 / transform.scale,
    );
    if (!mounted) return false;
    final entity = hit == null ? null : _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    final areaMeasurement = geometry is Map<String, dynamic>
        ? cadClosedEntityAreaMeasurement2D(geometry)
        : null;
    if (hit == null || areaMeasurement == null) {
      final previous = _measuredAreaEntityId;
      if (previous != null) {
        setState(() {
          if (_selectedEntityId == previous) _selectedEntityId = null;
          _measuredAreaEntityId = null;
          _measurementPerimeter = null;
          _measurementCentroid = null;
          _measurement = null;
          _areaBoundaryReportPoints.clear();
        });
      }
      return false;
    }
    final baseline = geometry is Map<String, dynamic>
        ? cadPolylineBaselineFromGeometry(geometry)
        : null;
    final boundaryEdges = baseline?.closed == true
        ? cadClosedBoundaryEdges2D(baseline!.points)
        : null;
    setState(() {
      _measurementPoints.clear();
      _areaBoundaryReportPoints
        ..clear()
        ..addAll(boundaryEdges?.map((edge) => edge.start) ?? const <Offset>[]);
      _areaPointIntersections.clear();
      _measurement = areaMeasurement.area;
      _measurementPerimeter = areaMeasurement.perimeter;
      _measurementCentroid = areaMeasurement.centroid;
      _measuredAreaEntityId = hit.entityId;
      _selectedEntityId = hit.entityId;
    });
    return true;
  }

  Map<String, dynamic>? _entityById(BigInt id) {
    for (final entity in _document.entities) {
      final value = entity['id'];
      if (value is int && BigInt.from(value) == id) return entity;
    }
    return null;
  }

  Future<void> _showEntityProperties(CadHit hit) async {
    final entity = _entityById(hit.entityId);
    final geometry = entity?['geometry'];
    if (entity == null || geometry is! Map<String, dynamic> || !mounted) return;
    final l10n = context.l10n;
    final metrics = cadEntityMetrics2D(geometry);
    final rows = <({String label, String value})>[
      (label: 'ID', value: hit.entityId.toString()),
      (label: l10n.text('propertyType'), value: metrics.kind.toUpperCase()),
    ];
    final layerId = entity['layer_id'];
    final layer = layerId is int
        ? _document.layers
              .where((item) => item.id == BigInt.from(layerId))
              .firstOrNull
        : null;
    rows.add((
      label: l10n.text('propertyLayer'),
      value: layer?.name ?? layerId?.toString() ?? '—',
    ));
    final counts = widget.engine.entityCountSummary(
      widget.opened.sessionId,
      hit.entityId,
    );
    if (counts != null &&
        counts.entityKind == metrics.kind &&
        (layerId is! int || counts.layerId == BigInt.from(layerId))) {
      rows.addAll([
        (
          label: l10n.text('propertySameTypeLayer'),
          value: counts.sameKindInLayer.toString(),
        ),
        (
          label: l10n.text('propertySameTypeDrawing'),
          value: counts.sameKindInDocument.toString(),
        ),
      ]);
      if (counts.sameKindLengthInLayer != null) {
        rows.add((
          label: l10n.text('propertySameTypeLengthLayer'),
          value: _formatLinear(counts.sameKindLengthInLayer!),
        ));
      }
      if (counts.sameKindLengthInDocument != null) {
        rows.add((
          label: l10n.text('propertySameTypeLengthDrawing'),
          value: _formatLinear(counts.sameKindLengthInDocument!),
        ));
      }
      if (metrics.area != null && counts.sameKindAreaInLayer != null) {
        rows.add((
          label: l10n.text('propertySameTypeAreaLayer'),
          value: _formatArea(counts.sameKindAreaInLayer!),
        ));
      }
      if (metrics.area != null && counts.sameKindAreaInDocument != null) {
        rows.add((
          label: l10n.text('propertySameTypeAreaDrawing'),
          value: _formatArea(counts.sameKindAreaInDocument!),
        ));
      }
    }
    void add(String key, String value) =>
        rows.add((label: l10n.text(key), value: value));
    if (metrics.start != null) {
      add('propertyStart', _formatPoint2(metrics.start!));
    }
    if (metrics.end != null) add('propertyEnd', _formatPoint2(metrics.end!));
    if (metrics.center != null) {
      add('propertyCenter', _formatPoint2(metrics.center!));
    }
    if (metrics.position != null) {
      add('propertyPosition', _formatPoint2(metrics.position!));
    }
    if (metrics.vertexCount != null) {
      add('propertyVertices', metrics.vertexCount.toString());
    }
    if (metrics.closed != null) {
      add(
        'propertyClosed',
        l10n.text(metrics.closed! ? 'valueYes' : 'valueNo'),
      );
    }
    if (metrics.bounds != null) {
      add('propertyExtentX', _formatLinear(metrics.bounds!.width));
      add('propertyExtentY', _formatLinear(metrics.bounds!.height));
    }
    if (metrics.length != null) {
      add('propertyLength', _formatLinear(metrics.length!));
    }
    if (metrics.radius != null) {
      add('propertyRadius', _formatLinear(metrics.radius!));
    }
    if (metrics.diameter != null) {
      add('propertyDiameter', _formatLinear(metrics.diameter!));
    }
    if (metrics.circumference != null) {
      add('propertyCircumference', _formatLinear(metrics.circumference!));
    }
    if (metrics.area != null) {
      add('propertyArea', _formatArea(metrics.area!));
    }
    if (metrics.sweepDegrees != null) {
      add(
        'propertySweep',
        '${_formatEngineeringValue(metrics.sweepDegrees!)}°',
      );
    }
    if (metrics.arcLength != null) {
      add('propertyArcLength', _formatLinear(metrics.arcLength!));
    }
    if (metrics.chordLength != null) {
      add('propertyChordLength', _formatLinear(metrics.chordLength!));
    }
    if (metrics.sagitta != null) {
      add('propertySagitta', _formatLinear(metrics.sagitta!));
    }
    if (metrics.sectorArea != null) {
      add('propertySectorArea', _formatArea(metrics.sectorArea!));
    }
    if (metrics.segmentArea != null) {
      add('propertySegmentArea', _formatArea(metrics.segmentArea!));
    }
    if (metrics.textHeight != null) {
      add('propertyHeight', _formatLinear(metrics.textHeight!));
    }
    if (metrics.content != null) add('propertyContent', metrics.content!);
    await _showPropertiesSheet(l10n.text('entityProperties'), rows);
  }

  Future<void> _showMeshProperties(CadMeshHit hit) async {
    final mesh = _meshForId(hit.meshId);
    if (mesh == null || !mounted) return;
    final l10n = context.l10n;
    final positions = mesh['positions'] as List<dynamic>? ?? const [];
    final indices = mesh['indices'] as List<dynamic>? ?? const [];
    final bounds = cadMeshBounds3D(mesh);
    final surfaceArea = (mesh['surface_area'] as num?)?.toDouble();
    final closedManifold = mesh['closed_manifold'] as bool?;
    final enclosedVolume = (mesh['enclosed_volume'] as num?)?.toDouble();
    final volumeCentroidJson = mesh['volume_centroid'];
    CadPoint3? volumeCentroid;
    if (volumeCentroidJson is Map<String, dynamic>) {
      final x = (volumeCentroidJson['x'] as num?)?.toDouble();
      final y = (volumeCentroidJson['y'] as num?)?.toDouble();
      final z = (volumeCentroidJson['z'] as num?)?.toDouble();
      if (x != null &&
          y != null &&
          z != null &&
          x.isFinite &&
          y.isFinite &&
          z.isFinite) {
        volumeCentroid = CadPoint3(x, y, z);
      }
    }
    final faceMetrics = cadMeshTriangleMetrics3D(mesh, hit.triangleIndex);
    final rows = <({String label, String value})>[
      (label: 'ID', value: hit.meshId.toString()),
      (
        label: l10n.text('propertyMesh'),
        value: mesh['name'] as String? ?? 'MESH',
      ),
      (label: l10n.text('propertyVertices'), value: '${positions.length}'),
      (label: l10n.text('propertyTriangles'), value: '${indices.length ~/ 3}'),
      (
        label: l10n.text('propertySelectedFace'),
        value: '${hit.triangleIndex + 1}',
      ),
      (
        label: l10n.text('propertyPosition'),
        value: _formatPoint3(hit.position),
      ),
    ];
    if (surfaceArea != null && surfaceArea.isFinite && surfaceArea >= 0) {
      rows.add((
        label: l10n.text('propertySurfaceArea'),
        value: _formatArea(surfaceArea),
      ));
    }
    if (closedManifold != null) {
      rows.add((
        label: l10n.text('propertyClosedManifold'),
        value: l10n.text(closedManifold ? 'valueYes' : 'valueNo'),
      ));
    }
    if (enclosedVolume != null &&
        enclosedVolume.isFinite &&
        enclosedVolume > 0) {
      rows.add((
        label: l10n.text('propertyEnclosedVolume'),
        value: _formatVolume(enclosedVolume),
      ));
    }
    if (volumeCentroid != null) {
      rows.add((
        label: l10n.text('propertyVolumeCentroid'),
        value: _formatCoordinateReferencePoint3(volumeCentroid),
      ));
    }
    if (faceMetrics != null) {
      final normal = faceMetrics.normal;
      final slope = faceMetrics.slope;
      rows.addAll([
        (
          label: l10n.text('propertyFaceArea'),
          value: _formatArea(faceMetrics.area),
        ),
        (
          label: l10n.text('propertyFacePerimeter'),
          value: _formatLinear(faceMetrics.perimeter),
        ),
        (
          label: l10n.text('propertyFaceEdges'),
          value:
              '${_formatLinear(faceMetrics.firstEdgeLength)} · '
              '${_formatLinear(faceMetrics.secondEdgeLength)} · '
              '${_formatLinear(faceMetrics.thirdEdgeLength)}',
        ),
        (
          label: l10n.text('propertyFaceCentroid'),
          value: _formatCoordinateReferencePoint3(faceMetrics.centroid),
        ),
        (
          label: l10n.text('propertyFaceNormal'),
          value: normal == null
              ? l10n.text('valueDegenerate')
              : 'X: ${_formatEngineeringValue(normal.x)} · '
                    'Y: ${_formatEngineeringValue(normal.y)} · '
                    'Z: ${_formatEngineeringValue(normal.z)}',
        ),
      ]);
      if (slope != null) {
        rows.addAll([
          (
            label: l10n.text('propertyFaceInclination'),
            value: '${_formatEngineeringValue(slope.inclinationDegrees)}°',
          ),
          (
            label: l10n.text('propertyFaceGrade'),
            value: slope.gradePercent == null
                ? '—'
                : '${_formatEngineeringValue(slope.gradePercent!)}%',
          ),
          (
            label: l10n.text('propertyFaceDownslope'),
            value: slope.downslopeAzimuthDegrees == null
                ? '—'
                : '${_formatEngineeringValue(slope.downslopeAzimuthDegrees!)}°',
          ),
        ]);
      }
    }
    if (bounds != null) {
      rows.addAll([
        (
          label: l10n.text('propertyExtentX'),
          value: _formatLinear(bounds.sizeX),
        ),
        (
          label: l10n.text('propertyExtentY'),
          value: _formatLinear(bounds.sizeY),
        ),
        (
          label: l10n.text('propertyExtentZ'),
          value: _formatLinear(bounds.sizeZ),
        ),
      ]);
    }
    final physicalVolume = enclosedVolume == null
        ? null
        : _physicalVolumeCubicMeters(enclosedVolume);
    await _showPropertiesSheet(
      l10n.text('entityProperties'),
      rows,
      actionLabel: physicalVolume == null ? null : l10n.text('massFromDensity'),
      actionIcon: Icons.scale_outlined,
      onAction: physicalVolume == null
          ? null
          : () => _requestMassFromVolume(enclosedVolume!, physicalVolume),
    );
  }

  Map<String, dynamic>? _meshForId(BigInt id) {
    for (final mesh in _document.meshes) {
      final meshId = mesh['id'];
      if (meshId is int && BigInt.from(meshId) == id) return mesh;
    }
    return null;
  }

  CadMeshTriangleMetrics3D? _meshFaceMetrics(CadMeshHit hit) {
    final mesh = _meshForId(hit.meshId);
    return mesh == null
        ? null
        : cadMeshTriangleMetrics3D(mesh, hit.triangleIndex);
  }

  Future<void> _showPropertiesSheet(
    String title,
    List<({String label, String value})> rows, {
    String? actionLabel,
    IconData actionIcon = Icons.table_view_outlined,
    VoidCallback? onAction,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final mediaQuery = MediaQuery.of(sheetContext);
        final availableHeight = math.max(
          0.0,
          mediaQuery.size.height -
              mediaQuery.viewInsets.bottom -
              mediaQuery.padding.vertical,
        );
        final height = math.min(480.0, availableHeight * 0.72);
        return SafeArea(
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.text('copyProperties'),
                        onPressed: () => unawaited(
                          _copyText(cadPropertiesClipboardText(title, rows)),
                        ),
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    key: const ValueKey('property_list'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return ListTile(
                        dense: true,
                        title: Text(row.label),
                        subtitle: SelectableText(row.value),
                      );
                    },
                  ),
                ),
                if (actionLabel != null && onAction != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const ValueKey('property_sheet_action'),
                        onPressed: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          Navigator.pop(sheetContext);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) onAction();
                          });
                        },
                        icon: Icon(actionIcon),
                        label: Text(actionLabel),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatPoint2(Offset point) =>
      'X: ${_formatLinear(point.dx)} · Y: ${_formatLinear(point.dy)}';

  String _formatPoint3(CadPoint3 point) =>
      'X: ${_formatLinear(point.x)} · '
      'Y: ${_formatLinear(point.y)} · Z: ${_formatLinear(point.z)}';

  String _formatCoordinateReferencePoint2(Offset point) {
    final frame = _localFrame2D;
    if (frame == null) return _formatPoint2(point);
    final relative = frame.worldToLocal(point);
    if (relative == null) return '—';
    return context.l10n.text('localCoordinateResult', {
      'x': _formatLinear(relative.dx),
      'y': _formatLinear(relative.dy),
    });
  }

  Offset? _coordinateReferenceValue2(Offset point) =>
      _localFrame2D?.worldToLocal(point) ?? point;

  CadSurveyDirection2D? _surveyDirectionInCoordinateReference(
    Offset start,
    Offset end,
  ) {
    final frame = _localFrame2D;
    if (frame == null) return cadSurveyDirection2D(start, end);
    final localStart = frame.worldToLocal(start);
    final localEnd = frame.worldToLocal(end);
    if (localStart == null || localEnd == null) return null;
    return cadSurveyDirection2D(localStart, localEnd);
  }

  String _displayCoordinateNumber(double value) {
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final converted = cadDrawingLengthToDisplayUnits(
      value,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    return converted == null ? '—' : _formatEngineeringValue(converted);
  }

  String _coordinateCollectionCsv() {
    final reference = _localFrame2D == null ? 'Drawing' : 'Local';
    final rows = <String>['Point,X,Y,Unit,Reference'];
    for (var index = 0; index < _coordinateCollectionPoints.length; index++) {
      final point = _coordinateReferenceValue2(
        _coordinateCollectionPoints[index],
      );
      if (point == null) continue;
      rows.add(
        'P${index + 1},${_displayCoordinateNumber(point.dx)},'
        '${_displayCoordinateNumber(point.dy)},$_unitSymbol,$reference',
      );
    }
    return rows.join('\n');
  }

  CadDivisionStakeoutReport2D? _activeDivisionStakeoutReport() {
    final baseline = _stationBaseline;
    final division = _polylineDivisionMeasurement;
    if (_tool != ViewerTool.dividePolyline ||
        baseline == null ||
        division == null) {
      return null;
    }
    final report = cadDivisionStakeoutReport2D(baseline, division.divisions);
    if (report == null ||
        (report.totalLength - division.totalLength).abs() >
            math.max(1.0, division.totalLength) * 1e-10 ||
        report.points.length != division.divisionPoints.length) {
      return null;
    }
    return report;
  }

  CadSurveyDirection2D? _surveyDirectionForWorldTangent(
    double worldDirectionDegrees,
  ) {
    if (!worldDirectionDegrees.isFinite) return null;
    var localDirection =
        worldDirectionDegrees - (_localFrame2D?.directionDegrees ?? 0);
    localDirection %= 360;
    if (localDirection < 0) localDirection += 360;
    final radians = localDirection * math.pi / 180;
    return cadSurveyDirection2D(
      Offset.zero,
      Offset(math.cos(radians), math.sin(radians)),
    );
  }

  String _divisionStakeoutCsv(CadDivisionStakeoutReport2D report) {
    final reference = _localFrame2D == null ? 'Drawing' : 'Local';
    final rows = <String>[
      'Point,Station,X,Y,Unit,TangentAzimuth_deg,TangentBearing,'
          'Element,Deflection_deg,LongChord,Reference',
    ];
    for (final row in report.points) {
      final point = _coordinateReferenceValue2(row.point);
      final direction = _surveyDirectionForWorldTangent(
        row.tangentDirectionDegrees,
      );
      if (point == null || direction == null) continue;
      final element = row.elementKind == CadStationElementKind2D.arc
          ? 'arc'
          : 'segment_${row.segmentIndex + 1}';
      rows.add(
        'P${row.index + 1},${_displayCoordinateNumber(row.station)},'
        '${_displayCoordinateNumber(point.dx)},'
        '${_displayCoordinateNumber(point.dy)},$_unitSymbol,'
        '${_formatEngineeringValue(direction.azimuthDegrees)},'
        '${_formatSurveyBearing(direction)},$element,'
        '${row.cumulativeDeflectionDegrees == null ? '' : _formatEngineeringValue(row.cumulativeDeflectionDegrees!)},'
        '${row.longChordFromStart == null ? '' : _displayCoordinateNumber(row.longChordFromStart!)},'
        '$reference',
      );
    }
    return rows.join('\n');
  }

  CadOpenTraverse2D? _activeCoordinateTraverse() {
    if (_coordinateCollectionPoints.length < 2) return null;
    final frame = _localFrame2D;
    if (frame == null) {
      return cadOpenTraverse2D(_coordinateCollectionPoints);
    }
    final localPoints = <Offset>[];
    for (final point in _coordinateCollectionPoints) {
      final local = frame.worldToLocal(point);
      if (local == null) return null;
      localPoints.add(local);
    }
    return cadOpenTraverse2D(localPoints);
  }

  String _traverseReportCsv(CadOpenTraverse2D traverse) {
    final reference = _localFrame2D == null ? 'Drawing' : 'Local';
    final rows = <String>[
      'Leg,From,To,Length,Unit,Azimuth_deg,Bearing,Reference',
    ];
    for (final leg in traverse.legs) {
      rows.add(
        'L${leg.index + 1},P${leg.index + 1},P${leg.index + 2},'
        '${_displayCoordinateNumber(leg.length)},$_unitSymbol,'
        '${_formatEngineeringValue(leg.direction.azimuthDegrees)},'
        '${_formatSurveyBearing(leg.direction)},$reference',
      );
    }
    return rows.join('\n');
  }

  List<CadBoundaryEdge2D>? _activeAreaBoundaryEdges() {
    final points = _measuredAreaEntityId == null
        ? _measurementPoints
        : _areaBoundaryReportPoints;
    if (_tool != ViewerTool.measureArea ||
        _measurement == null ||
        points.length < 3) {
      return null;
    }
    final frame = _localFrame2D;
    if (frame == null) {
      return cadClosedBoundaryEdges2D(points);
    }
    final localPoints = <Offset>[];
    for (final point in points) {
      final local = frame.worldToLocal(point);
      if (local == null) return null;
      localPoints.add(local);
    }
    return cadClosedBoundaryEdges2D(localPoints);
  }

  String _boundaryReportCsv(List<CadBoundaryEdge2D> edges) {
    final reference = _localFrame2D == null ? 'Drawing' : 'Local';
    final rows = <String>[
      'Edge,From,To,Length,Unit,Azimuth_deg,Bearing,'
          'InteriorAngle_deg,Deflection_deg,VertexType,Reference',
    ];
    for (final edge in edges) {
      final next = (edge.index + 1) % edges.length;
      rows.add(
        'E${edge.index + 1},P${edge.index + 1},P${next + 1},'
        '${_displayCoordinateNumber(edge.length)},$_unitSymbol,'
        '${_formatEngineeringValue(edge.direction.azimuthDegrees)},'
        '${_formatSurveyBearing(edge.direction)},'
        '${_formatEngineeringValue(edge.interiorAngleDegrees)},'
        '${_formatEngineeringValue(edge.deflectionAngleDegrees)},'
        '${_boundaryVertexKindCode(edge.vertexKind)},$reference',
      );
    }
    return rows.join('\n');
  }

  String _boundaryVertexKindCode(CadBoundaryVertexKind kind) => switch (kind) {
    CadBoundaryVertexKind.convex => 'convex',
    CadBoundaryVertexKind.concave => 'concave',
    CadBoundaryVertexKind.straight => 'straight',
  };

  String _boundaryVertexKindLabel(CadBoundaryVertexKind kind) =>
      context.l10n.text(switch (kind) {
        CadBoundaryVertexKind.convex => 'boundaryVertexConvex',
        CadBoundaryVertexKind.concave => 'boundaryVertexConcave',
        CadBoundaryVertexKind.straight => 'boundaryVertexStraight',
      });

  void _showBoundaryReport() {
    final edges = _activeAreaBoundaryEdges();
    if (edges == null) return;
    final csv = _boundaryReportCsv(edges);
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.text('boundaryReportTitle', {
                          'count': edges.length,
                        }),
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('copy_boundary_csv'),
                      tooltip: l10n.text('copyBoundaryCsv'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        unawaited(_copyText(csv));
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('boundary_report_list'),
                  itemCount: edges.length,
                  itemBuilder: (context, index) {
                    final edge = edges[index];
                    final next = (index + 1) % edges.length;
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        child: Text('${index + 1}'),
                      ),
                      title: Text('P${index + 1} → P${next + 1}'),
                      subtitle: Text(
                        l10n.text('boundaryEdgeValues', {
                          'length': _formatLinear(edge.length),
                          'azimuth': _formatEngineeringValue(
                            edge.direction.azimuthDegrees,
                          ),
                          'bearing': _formatSurveyBearing(edge.direction),
                          'interior': _formatEngineeringValue(
                            edge.interiorAngleDegrees,
                          ),
                          'deflection': _formatEngineeringValue(
                            edge.deflectionAngleDegrees,
                          ),
                          'vertexType': _boundaryVertexKindLabel(
                            edge.vertexKind,
                          ),
                        }),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(l10n.text('done')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDivisionStakeoutTable() {
    final report = _activeDivisionStakeoutReport();
    if (report == null) {
      _showViewerMessage(context.l10n.text('invalidPolylineDivision'));
      return;
    }
    final csv = _divisionStakeoutCsv(report);
    final l10n = context.l10n;
    final reference = _localFrame2D == null
        ? l10n.text('drawingOrigin')
        : l10n.text('localAxisValue', {
            'origin': _formatPoint2(_localFrame2D!.origin),
            'direction': _formatEngineeringValue(
              _localFrame2D!.directionDegrees,
            ),
          });
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.text('divisionTableTitle', {
                              'count': report.points.length,
                            }),
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            l10n.text('divisionTableSummary', {
                              'total': _formatLinear(report.totalLength),
                              'interval': _formatLinear(report.intervalLength),
                              'reference': reference,
                            }),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('copy_division_stakeout_csv'),
                      tooltip: l10n.text('copyDivisionCsv'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        unawaited(_copyText(csv));
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('division_stakeout_table_list'),
                  itemCount: report.points.length,
                  itemBuilder: (context, index) {
                    final row = report.points[index];
                    final direction = _surveyDirectionForWorldTangent(
                      row.tangentDirectionDegrees,
                    );
                    final element =
                        row.elementKind == CadStationElementKind2D.arc
                        ? l10n.text('stationElementArc')
                        : '${l10n.text('stationElementSegment')} '
                              '${row.segmentIndex + 1}';
                    final values = <String, Object>{
                      'station': _formatLinear(row.station),
                      'point': _formatCoordinateReferencePoint2(row.point),
                      'azimuth': direction == null
                          ? '—'
                          : '${_formatEngineeringValue(direction.azimuthDegrees)}°',
                      'bearing': _formatSurveyBearing(direction),
                      'element': element,
                    };
                    final base = l10n.text('divisionPointValues', values);
                    final deflection = row.cumulativeDeflectionDegrees;
                    final chord = row.longChordFromStart;
                    final detail = deflection == null || chord == null
                        ? base
                        : '$base\n${l10n.text('divisionCurvePointValues', {'deflection': _formatEngineeringValue(deflection), 'chord': _formatLinear(chord)})}';
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        child: Text('${row.index + 1}'),
                      ),
                      title: Text('P${row.index + 1}'),
                      subtitle: Text(detail),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(l10n.text('done')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCoordinateCollectionTable() {
    if (_coordinateCollectionPoints.isEmpty) return;
    final points = List<Offset>.of(_coordinateCollectionPoints);
    final csv = _coordinateCollectionCsv();
    final traverse = _activeCoordinateTraverse();
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.text('coordinateTableTitle', {
                              'count': points.length,
                            }),
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            _localFrame2D == null
                                ? l10n.text('drawingOrigin')
                                : l10n.text('localAxisValue', {
                                    'origin': _formatPoint2(
                                      _localFrame2D!.origin,
                                    ),
                                    'direction': _formatEngineeringValue(
                                      _localFrame2D!.directionDegrees,
                                    ),
                                  }),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(sheetContext).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (traverse != null)
                      IconButton(
                        key: const ValueKey('view_traverse_report'),
                        tooltip: l10n.text('viewTraverseReport'),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _showCoordinateTraverseReport();
                          });
                        },
                        icon: const Icon(Icons.route_outlined),
                      ),
                    IconButton(
                      key: const ValueKey('copy_coordinate_csv'),
                      tooltip: l10n.text('copyCoordinateCsv'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        unawaited(_copyText(csv));
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('coordinate_table_list'),
                  itemCount: points.length,
                  itemBuilder: (context, index) {
                    final point = _coordinateReferenceValue2(points[index]);
                    final x = point == null
                        ? '—'
                        : _displayCoordinateNumber(point.dx);
                    final y = point == null
                        ? '—'
                        : _displayCoordinateNumber(point.dy);
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        child: Text('${index + 1}'),
                      ),
                      title: Text('P${index + 1}'),
                      subtitle: Text('X: $x $_unitSymbol · Y: $y $_unitSymbol'),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(l10n.text('done')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCoordinateTraverseReport() {
    final traverse = _activeCoordinateTraverse();
    if (traverse == null) return;
    final csv = _traverseReportCsv(traverse);
    final l10n = context.l10n;
    final displacementDirection = traverse.displacementDirection;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.76,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.text('traverseReportTitle', {
                              'count': traverse.legs.length,
                            }),
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            l10n.text('traverseSummary', {
                              'total': _formatLinear(traverse.totalLength),
                              'last': traverse.legs.length + 1,
                              'displacement': _formatLinear(
                                traverse.displacement,
                              ),
                              'azimuth': displacementDirection == null
                                  ? '—'
                                  : '${_formatEngineeringValue(displacementDirection.azimuthDegrees)}°',
                              'bearing': _formatSurveyBearing(
                                displacementDirection,
                              ),
                            }),
                            style: Theme.of(sheetContext).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('copy_traverse_csv'),
                      tooltip: l10n.text('copyTraverseCsv'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        unawaited(_copyText(csv));
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('traverse_report_list'),
                  itemCount: traverse.legs.length,
                  itemBuilder: (context, index) {
                    final leg = traverse.legs[index];
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        child: Text('${index + 1}'),
                      ),
                      title: Text('P${index + 1} → P${index + 2}'),
                      subtitle: Text(
                        l10n.text('traverseLegValues', {
                          'length': _formatLinear(leg.length),
                          'azimuth': _formatEngineeringValue(
                            leg.direction.azimuthDegrees,
                          ),
                          'bearing': _formatSurveyBearing(leg.direction),
                        }),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('check_known_endpoint'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            unawaited(_requestTraverseClosureCheck());
                          }
                        });
                      },
                      icon: const Icon(Icons.rule_outlined),
                      label: Text(l10n.text('knownEndpointClosure')),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(l10n.text('done')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Offset? _referencePointFromDisplayCoordinate(_CadCoordinateInput input) {
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final x = cadDisplayLengthToDrawingUnits(
      input.x,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final y = cadDisplayLengthToDrawingUnits(
      input.y,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    if (x == null || y == null) return null;
    final point = Offset(x, y);
    return point.dx.isFinite && point.dy.isFinite ? point : null;
  }

  double? _activePlanAreaForVolume() {
    double? area;
    switch (_tool) {
      case ViewerTool.measureArea:
      case ViewerTool.measureRectangle:
      case ViewerTool.measureOrientedRectangle:
      case ViewerTool.measureEntityArea:
        area = _measurement;
        break;
      case ViewerTool.measureCircle3Point:
        area = _measurementPoints.length == 3
            ? cadThreePointCircleMeasurement2D(
                _measurementPoints[0],
                _measurementPoints[1],
                _measurementPoints[2],
              )?.area
            : null;
        break;
      default:
        area = null;
    }
    return area != null && area.isFinite && area > 0 ? area : null;
  }

  double? _activePlanPerimeterForHeight() {
    double? perimeter;
    switch (_tool) {
      case ViewerTool.measureArea:
        perimeter = _measurementPerimeter;
        if (perimeter == null &&
            _measurement != null &&
            _measurementPoints.length >= 3) {
          perimeter = polylineLength2D(_measurementPoints, closed: true);
        }
        break;
      case ViewerTool.measureRectangle:
      case ViewerTool.measureOrientedRectangle:
      case ViewerTool.measureCircle3Point:
      case ViewerTool.measureEntityArea:
        perimeter = _measurementPerimeter;
        break;
      default:
        perimeter = null;
    }
    return perimeter != null && perimeter.isFinite && perimeter > 0
        ? perimeter
        : null;
  }

  double? _activeLinearQuantityLength() {
    final perimeter = _activePlanPerimeterForHeight();
    if (perimeter != null) return perimeter;
    final length = switch (_tool) {
      ViewerTool.measurePath || ViewerTool.measureEntityLength => _measurement,
      _ => null,
    };
    return length != null && length.isFinite && length > 0 ? length : null;
  }

  List<Offset>? _sectionReferencePoints(Iterable<Offset> worldPoints) {
    final frame = _localFrame2D;
    if (frame == null) return List<Offset>.of(worldPoints);
    final result = <Offset>[];
    for (final point in worldPoints) {
      final local = frame.worldToLocal(point);
      if (local == null) return null;
      result.add(local);
    }
    return result;
  }

  CadSectionProperties2D? _activeSectionProperties() {
    switch (_tool) {
      case ViewerTool.measureArea:
        final entityId = _measuredAreaEntityId;
        if (entityId != null) {
          final geometry = _entityById(entityId)?['geometry'];
          if (geometry is! Map<String, dynamic>) return null;
          final metrics = cadEntityMetrics2D(geometry);
          if (metrics.kind == 'circle' &&
              metrics.center != null &&
              metrics.radius != null) {
            final center = _sectionReferencePoints([metrics.center!])?.first;
            return center == null
                ? null
                : cadCircleSectionProperties2D(center, metrics.radius!);
          }
          if (metrics.kind == 'polyline' && metrics.closed == true) {
            final baseline = cadPolylineBaselineFromGeometry(geometry);
            if (baseline == null || !baseline.closed) return null;
            final referencePoints = _sectionReferencePoints(baseline.points);
            return referencePoints == null
                ? null
                : cadPolygonSectionProperties2D(referencePoints);
          }
          return null;
        }
        final referencePoints = _sectionReferencePoints(_measurementPoints);
        return referencePoints == null
            ? null
            : cadPolygonSectionProperties2D(referencePoints);
      case ViewerTool.measureRectangle:
        if (_measurementPoints.length != 2) return null;
        final first = _measurementPoints[0];
        final second = _measurementPoints[1];
        final referencePoints = _sectionReferencePoints([
          first,
          Offset(second.dx, first.dy),
          second,
          Offset(first.dx, second.dy),
        ]);
        return referencePoints == null
            ? null
            : cadPolygonSectionProperties2D(referencePoints);
      case ViewerTool.measureOrientedRectangle:
        if (_measurementPoints.length != 3) return null;
        final rectangle = cadOrientedRectangleMeasurement2D(
          _measurementPoints[0],
          _measurementPoints[1],
          _measurementPoints[2],
        );
        final referencePoints = rectangle == null
            ? null
            : _sectionReferencePoints(rectangle.corners);
        return referencePoints == null
            ? null
            : cadPolygonSectionProperties2D(referencePoints);
      case ViewerTool.measureCircle3Point:
        if (_measurementPoints.length != 3) return null;
        final circle = cadThreePointCircleMeasurement2D(
          _measurementPoints[0],
          _measurementPoints[1],
          _measurementPoints[2],
        );
        if (circle == null) return null;
        final center = _sectionReferencePoints([circle.center])?.first;
        return center == null
            ? null
            : cadCircleSectionProperties2D(center, circle.radius);
      default:
        return null;
    }
  }

  Future<void> _showActiveSectionProperties() async {
    final properties = _activeSectionProperties();
    if (properties == null) {
      _showViewerMessage(context.l10n.text('sectionPropertiesUnavailable'));
      return;
    }
    final l10n = context.l10n;
    final frame = _localFrame2D;
    final reference = frame == null
        ? l10n.text('drawingOrigin')
        : l10n.text('localAxisValue', {
            'origin': _formatPoint2(frame.origin),
            'direction': _formatEngineeringValue(frame.directionDegrees),
          });
    final centroid = frame == null
        ? _formatPoint2(properties.centroid)
        : l10n.text('localCoordinateResult', {
            'x': _formatLinear(properties.centroid.dx),
            'y': _formatLinear(properties.centroid.dy),
          });
    await _showPropertiesSheet(l10n.text('sectionProperties'), [
      (label: l10n.text('coordinateReference'), value: reference),
      (label: l10n.text('propertyArea'), value: _formatArea(properties.area)),
      (label: l10n.text('sectionCentroid'), value: centroid),
      (
        label: 'Ix,c = ∫y² dA',
        value: _formatFourthPower(properties.centroidalMomentX),
      ),
      (
        label: 'Iy,c = ∫x² dA',
        value: _formatFourthPower(properties.centroidalMomentY),
      ),
      (
        label: 'Ixy,c = ∫xy dA',
        value: _formatFourthPower(properties.centroidalProductXY),
      ),
      (
        label: 'Jc = Ix,c + Iy,c',
        value: _formatFourthPower(properties.polarMoment),
      ),
      (
        label: 'Imax',
        value: _formatFourthPower(properties.principalMomentMaximum),
      ),
      (
        label: 'Imin',
        value: _formatFourthPower(properties.principalMomentMinimum),
      ),
      (
        label: l10n.text('sectionPrincipalAxisMaximum'),
        value: properties.principalAxisMaximumDegrees == null
            ? l10n.text('sectionPrincipalAxisUndefined')
            : '${_formatEngineeringValue(properties.principalAxisMaximumDegrees!)}°',
      ),
      (
        label: 'kx = √(Ix,c / A)',
        value: _formatLinear(properties.radiusOfGyrationX),
      ),
      (
        label: 'ky = √(Iy,c / A)',
        value: _formatLinear(properties.radiusOfGyrationY),
      ),
      (
        label: 'Sx(+Y) = Ix,c / c(+Y)',
        value: _formatCubic(properties.sectionModulusXPositiveY),
      ),
      (
        label: 'Sx(−Y) = Ix,c / c(−Y)',
        value: _formatCubic(properties.sectionModulusXNegativeY),
      ),
      (
        label: 'Sy(+X) = Iy,c / c(+X)',
        value: _formatCubic(properties.sectionModulusYPositiveX),
      ),
      (
        label: 'Sy(−X) = Iy,c / c(−X)',
        value: _formatCubic(properties.sectionModulusYNegativeX),
      ),
    ]);
  }

  Future<void> _requestCoverageQuantity(double area) async {
    final input = await showDialog<_CadCoverageInput>(
      context: context,
      builder: (_) => _CoverageQuantityDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final coveragePerUnit = cadDisplayAreaToDrawingUnits(
      input.coveragePerUnit,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result = coveragePerUnit == null
        ? null
        : cadCoverageQuantityMeasurement2D(
            area,
            coveragePerUnit,
            input.wastePercent,
          );
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidCoverageQuantity'));
      return;
    }
    final l10n = context.l10n;
    await _showPropertiesSheet(l10n.text('coverageQuantity'), [
      (label: l10n.text('coverageSourceArea'), value: _formatArea(result.area)),
      (
        label: l10n.text('coverageAreaPerUnit'),
        value: _formatArea(result.coveragePerUnit),
      ),
      (
        label: l10n.text('coverageWastePercent'),
        value: '${_formatEngineeringValue(result.wastePercent)}%',
      ),
      (
        label: l10n.text('coverageAdjustedArea'),
        value: _formatArea(result.adjustedArea),
      ),
      (
        label: l10n.text('coverageExactUnits'),
        value: _formatEngineeringValue(result.exactUnits),
      ),
      (label: l10n.text('coverageWholeUnits'), value: '${result.wholeUnits}'),
      (
        label: l10n.text('coverageProcuredArea'),
        value: _formatArea(result.procuredCoverageArea),
      ),
      (
        label: l10n.text('coverageSurplusArea'),
        value: _formatArea(result.surplusArea),
      ),
    ]);
  }

  Future<void> _requestLinearQuantity(double length) async {
    final input = await showDialog<_CadLinearQuantityInput>(
      context: context,
      builder: (_) => _LinearQuantityDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final lengthPerUnit = cadDisplayLengthToDrawingUnits(
      input.lengthPerUnit,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result = lengthPerUnit == null
        ? null
        : cadLinearQuantityMeasurement2D(
            length,
            lengthPerUnit,
            input.wastePercent,
          );
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidLinearQuantity'));
      return;
    }
    final l10n = context.l10n;
    await _showPropertiesSheet(l10n.text('linearQuantity'), [
      (
        label: l10n.text('linearSourceLength'),
        value: _formatLinear(result.length),
      ),
      (
        label: l10n.text('linearLengthPerUnit'),
        value: _formatLinear(result.lengthPerUnit),
      ),
      (
        label: l10n.text('coverageWastePercent'),
        value: '${_formatEngineeringValue(result.wastePercent)}%',
      ),
      (
        label: l10n.text('linearAdjustedLength'),
        value: _formatLinear(result.adjustedLength),
      ),
      (
        label: l10n.text('coverageExactUnits'),
        value: _formatEngineeringValue(result.exactUnits),
      ),
      (label: l10n.text('coverageWholeUnits'), value: '${result.wholeUnits}'),
      (
        label: l10n.text('linearProcuredLength'),
        value: _formatLinear(result.procuredLength),
      ),
      (
        label: l10n.text('linearSurplusLength'),
        value: _formatLinear(result.surplusLength),
      ),
      (
        label: l10n.text('linearQuantityBasis'),
        value: l10n.text('linearQuantityBasisValue'),
      ),
    ]);
  }

  Future<void> _requestPlanSlope(double horizontalRun) async {
    final enteredRise = await showDialog<double>(
      context: context,
      builder: (_) => _QuantityLengthDialog(
        unitSymbol: _unitSymbol,
        purpose: _QuantityLengthPurpose.planRise,
      ),
    );
    if (enteredRise == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final verticalRise = cadDisplayLengthToDrawingUnits(
      enteredRise,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result = verticalRise == null
        ? null
        : cadPlanSlopeMeasurement2D(horizontalRun, verticalRise);
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidPlanSlopeInput'));
      return;
    }
    final l10n = context.l10n;
    await _showPropertiesSheet(
      l10n.text('planSlope'),
      [
        (
          label: l10n.text('planSlopeHorizontalRun'),
          value: _formatLinear(result.horizontalRun),
        ),
        (
          label: l10n.text('planSlopeVerticalRise'),
          value: _formatLinear(result.verticalRise),
        ),
        (
          label: l10n.text('planSlopeLength'),
          value: _formatLinear(result.slopeLength),
        ),
        (
          label: l10n.text('planSlopeGrade'),
          value: _formatGradePercent(result.gradePercent),
        ),
        (
          label: l10n.text('planSlopeRatio'),
          value: _formatGradeRatio(result.slopeRatio),
        ),
        (
          label: l10n.text('planSlopeAngle'),
          value: '${_formatEngineeringValue(result.slopeAngleDegrees)}°',
        ),
      ],
      actionLabel: l10n.text('linearQuantity'),
      actionIcon: Icons.view_stream_outlined,
      onAction: () => _requestLinearQuantity(result.slopeLength),
    );
  }

  Future<void> _requestVolumeFromArea(double area) async {
    final enteredDepth = await showDialog<double>(
      context: context,
      builder: (_) => _QuantityLengthDialog(
        unitSymbol: _unitSymbol,
        purpose: _QuantityLengthPurpose.volumeDepth,
      ),
    );
    if (enteredDepth == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final depth = cadDisplayLengthToDrawingUnits(
      enteredDepth,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result = depth == null
        ? null
        : cadPrismaticVolumeMeasurement2D(area, depth);
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidVolumeDepth'));
      return;
    }
    final l10n = context.l10n;
    final physicalVolume = _physicalVolumeCubicMeters(result.volume);
    await _showPropertiesSheet(
      l10n.text('volumeFromArea'),
      [
        (label: l10n.text('volumeSourceArea'), value: _formatArea(result.area)),
        (label: l10n.text('volumeDepth'), value: _formatLinear(result.depth)),
        (label: l10n.text('volumeResult'), value: _formatVolume(result.volume)),
      ],
      actionLabel: physicalVolume == null ? null : l10n.text('massFromDensity'),
      actionIcon: Icons.scale_outlined,
      onAction: physicalVolume == null
          ? null
          : () => _requestMassFromVolume(result.volume, physicalVolume),
    );
  }

  Future<void> _requestAverageEndAreaVolume(double firstArea) async {
    final input = await showDialog<_CadAverageEndAreaInput>(
      context: context,
      builder: (_) => _AverageEndAreaVolumeDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final secondArea = cadDisplayAreaToDrawingUnits(
      input.secondArea,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final intervalLength = cadDisplayLengthToDrawingUnits(
      input.intervalLength,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result = secondArea == null || intervalLength == null
        ? null
        : cadAverageEndAreaVolumeMeasurement2D(
            firstArea,
            secondArea,
            intervalLength,
          );
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidAverageEndAreaInput'));
      return;
    }
    final l10n = context.l10n;
    final physicalVolume = _physicalVolumeCubicMeters(result.volume);
    await _showPropertiesSheet(
      l10n.text('averageEndAreaVolume'),
      [
        (
          label: l10n.text('firstEndArea'),
          value: _formatArea(result.firstArea),
        ),
        (
          label: l10n.text('secondEndArea'),
          value: _formatArea(result.secondArea),
        ),
        (
          label: l10n.text('sectionInterval'),
          value: _formatLinear(result.intervalLength),
        ),
        (label: l10n.text('meanEndArea'), value: _formatArea(result.meanArea)),
        (
          label: l10n.text('computedVolume'),
          value: _formatVolume(result.volume),
        ),
      ],
      actionLabel: physicalVolume == null ? null : l10n.text('massFromDensity'),
      actionIcon: Icons.scale_outlined,
      onAction: physicalVolume == null
          ? null
          : () => _requestMassFromVolume(result.volume, physicalVolume),
    );
  }

  Future<void> _requestPrismoidalVolume(double firstArea) async {
    final input = await showDialog<_CadPrismoidalInput>(
      context: context,
      builder: (_) => _PrismoidalVolumeDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final midpointArea = cadDisplayAreaToDrawingUnits(
      input.midpointArea,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final secondArea = cadDisplayAreaToDrawingUnits(
      input.secondArea,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final intervalLength = cadDisplayLengthToDrawingUnits(
      input.intervalLength,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result =
        midpointArea == null || secondArea == null || intervalLength == null
        ? null
        : cadPrismoidalVolumeMeasurement2D(
            firstArea,
            midpointArea,
            secondArea,
            intervalLength,
          );
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidPrismoidalInput'));
      return;
    }
    final l10n = context.l10n;
    final physicalVolume = _physicalVolumeCubicMeters(result.volume);
    await _showPropertiesSheet(
      l10n.text('prismoidalVolume'),
      [
        (
          label: l10n.text('firstEndArea'),
          value: _formatArea(result.firstArea),
        ),
        (
          label: l10n.text('midpointArea'),
          value: _formatArea(result.midpointArea),
        ),
        (
          label: l10n.text('secondEndArea'),
          value: _formatArea(result.secondArea),
        ),
        (
          label: l10n.text('sectionInterval'),
          value: _formatLinear(result.intervalLength),
        ),
        (
          label: l10n.text('prismoidalMeanArea'),
          value: _formatArea(result.weightedMeanArea),
        ),
        (
          label: l10n.text('computedVolume'),
          value: _formatVolume(result.volume),
        ),
      ],
      actionLabel: physicalVolume == null ? null : l10n.text('massFromDensity'),
      actionIcon: Icons.scale_outlined,
      onAction: physicalVolume == null
          ? null
          : () => _requestMassFromVolume(result.volume, physicalVolume),
    );
  }

  Future<void> _requestLateralAreaFromPerimeter(double perimeter) async {
    final enteredHeight = await showDialog<double>(
      context: context,
      builder: (_) => _QuantityLengthDialog(
        unitSymbol: _unitSymbol,
        purpose: _QuantityLengthPurpose.perimeterHeight,
      ),
    );
    if (enteredHeight == null || !mounted) return;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final height = cadDisplayLengthToDrawingUnits(
      enteredHeight,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    final result = height == null
        ? null
        : cadExtrudedPerimeterAreaMeasurement2D(perimeter, height);
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidLateralHeight'));
      return;
    }
    final l10n = context.l10n;
    await _showPropertiesSheet(
      l10n.text('lateralAreaFromPerimeter'),
      [
        (
          label: l10n.text('lateralSourcePerimeter'),
          value: _formatLinear(result.perimeter),
        ),
        (
          label: l10n.text('lateralHeight'),
          value: _formatLinear(result.height),
        ),
        (
          label: l10n.text('lateralAreaResult'),
          value: _formatArea(result.lateralArea),
        ),
      ],
      actionLabel: l10n.text('coverageQuantity'),
      actionIcon: Icons.grid_view_outlined,
      onAction: () => _requestCoverageQuantity(result.lateralArea),
    );
  }

  double? _physicalVolumeCubicMeters(double drawingVolume) {
    final source = _calibrationUnit ?? _sourceUnit;
    final calibration = _calibrationMetersPerDrawingUnit;
    if (calibration == null && source == null) return null;
    return cadDrawingVolumeToDisplayUnits(
      drawingVolume,
      source: source,
      display: cadEngineeringUnitById('m'),
      metersPerDrawingUnit: calibration,
    );
  }

  Future<void> _requestMassFromVolume(
    double drawingVolume,
    double volumeCubicMeters,
  ) async {
    final input = await showDialog<_CadDensityInput>(
      context: context,
      builder: (_) => const _DensityDialog(),
    );
    if (input == null || !mounted) return;
    final result = cadMaterialMassMeasurement(
      volumeCubicMeters,
      input.value,
      input.unit,
    );
    if (result == null) {
      _showViewerMessage(context.l10n.text('invalidDensity'));
      return;
    }
    final l10n = context.l10n;
    await _showPropertiesSheet(l10n.text('massFromDensity'), [
      (
        label: l10n.text('massSourceVolume'),
        value: _formatVolume(drawingVolume),
      ),
      (
        label: l10n.text('materialDensity'),
        value:
            '${_formatEngineeringValue(input.value)} '
            '${_densityUnitSymbol(input.unit)}',
      ),
      (
        label: l10n.text('materialMass'),
        value:
            '${_formatEngineeringValue(result.massKilograms)} kg · '
            '${_formatEngineeringValue(result.massTonnes)} t · '
            '${_formatEngineeringValue(result.massPounds)} lb',
      ),
    ]);
  }

  void _showEngineeringQuantityActions({
    required double? area,
    required double? perimeter,
    required double? linearLength,
    required bool sectionPropertiesAvailable,
  }) {
    if (area == null &&
        perimeter == null &&
        linearLength == null &&
        !sectionPropertiesAvailable) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.76,
          child: ListView(
            key: const ValueKey('engineering_quantity_list'),
            children: [
              ListTile(
                leading: const Icon(Icons.calculate_outlined),
                title: Text(
                  l10n.text('engineeringQuantities'),
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              if (linearLength != null)
                ListTile(
                  key: const ValueKey('quantity_linear_material'),
                  leading: const Icon(Icons.view_stream_outlined),
                  title: Text(l10n.text('linearQuantity')),
                  subtitle: Text(l10n.text('linearQuantityMenuHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        unawaited(_requestLinearQuantity(linearLength));
                      }
                    });
                  },
                ),
              if (area != null)
                ListTile(
                  key: const ValueKey('quantity_coverage'),
                  leading: const Icon(Icons.grid_view_outlined),
                  title: Text(l10n.text('coverageQuantity')),
                  subtitle: Text(l10n.text('coverageQuantityHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) unawaited(_requestCoverageQuantity(area));
                    });
                  },
                ),
              if (area != null)
                ListTile(
                  key: const ValueKey('quantity_volume'),
                  leading: const Icon(Icons.view_in_ar_outlined),
                  title: Text(l10n.text('volumeFromArea')),
                  subtitle: Text(l10n.text('volumeDepthHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) unawaited(_requestVolumeFromArea(area));
                    });
                  },
                ),
              if (area != null)
                ListTile(
                  key: const ValueKey('quantity_average_end_area'),
                  leading: const Icon(Icons.area_chart_outlined),
                  title: Text(l10n.text('averageEndAreaVolume')),
                  subtitle: Text(l10n.text('averageEndAreaHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        unawaited(_requestAverageEndAreaVolume(area));
                      }
                    });
                  },
                ),
              if (area != null)
                ListTile(
                  key: const ValueKey('quantity_prismoidal_volume'),
                  leading: const Icon(Icons.stacked_line_chart_outlined),
                  title: Text(l10n.text('prismoidalVolume')),
                  subtitle: Text(l10n.text('prismoidalVolumeHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        unawaited(_requestPrismoidalVolume(area));
                      }
                    });
                  },
                ),
              if (perimeter != null)
                ListTile(
                  key: const ValueKey('quantity_lateral_area'),
                  leading: const Icon(Icons.height),
                  title: Text(l10n.text('lateralAreaFromPerimeter')),
                  subtitle: Text(l10n.text('lateralHeightHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        unawaited(_requestLateralAreaFromPerimeter(perimeter));
                      }
                    });
                  },
                ),
              if (linearLength != null)
                ListTile(
                  key: const ValueKey('quantity_plan_slope'),
                  leading: const Icon(Icons.show_chart_outlined),
                  title: Text(l10n.text('planSlope')),
                  subtitle: Text(l10n.text('planSlopeHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) unawaited(_requestPlanSlope(linearLength));
                    });
                  },
                ),
              if (sectionPropertiesAvailable)
                ListTile(
                  key: const ValueKey('quantity_section_properties'),
                  leading: const Icon(Icons.analytics_outlined),
                  title: Text(l10n.text('sectionProperties')),
                  subtitle: Text(l10n.text('sectionPropertiesHint')),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) unawaited(_showActiveSectionProperties());
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _requestTraverseClosureCheck() async {
    final traverse = _activeCoordinateTraverse();
    if (traverse == null) return;
    final input = await showDialog<_CadCoordinateInput>(
      context: context,
      builder: (_) => _CoordinateLocationDialog(
        unitSymbol: _unitSymbol,
        knownEndpoint: true,
      ),
    );
    if (input == null || !mounted) return;
    final knownEndpoint = _referencePointFromDisplayCoordinate(input);
    final closure = knownEndpoint == null
        ? null
        : cadTraverseClosure2D(traverse, knownEndpoint);
    if (closure == null) {
      _showViewerMessage(context.l10n.text('invalidCoordinateValue'));
      return;
    }
    final l10n = context.l10n;
    final direction = closure.correctionDirection;
    final precision = closure.relativePrecision == double.infinity
        ? l10n.text('exactClosure')
        : '1:${_formatEngineeringValue(closure.relativePrecision)}';
    await _showPropertiesSheet(
      l10n.text('knownEndpointClosure'),
      [
        (
          label: l10n.text('closureObservedEndpoint', {
            'index': traverse.legs.length + 1,
          }),
          value: _formatPoint2(closure.observedEndpoint),
        ),
        (
          label: l10n.text('closureKnownEndpoint'),
          value: _formatPoint2(closure.knownEndpoint),
        ),
        (
          label: l10n.text('closureCorrection'),
          value:
              'ΔX: ${_formatLinear(closure.correction.dx)} · '
              'ΔY: ${_formatLinear(closure.correction.dy)}',
        ),
        (
          label: l10n.text('closureLinearMisclosure'),
          value: _formatLinear(closure.linearMisclosure),
        ),
        (label: l10n.text('closureRelativePrecision'), value: precision),
        (
          label: l10n.text('closureCorrectionDirection'),
          value: l10n.text('closureDirectionValue', {
            'azimuth': direction == null
                ? '—'
                : '${_formatEngineeringValue(direction.azimuthDegrees)}°',
            'bearing': _formatSurveyBearing(direction),
          }),
        ),
        (
          label: l10n.text('closureTraverseLength'),
          value: _formatLinear(traverse.totalLength),
        ),
      ],
      actionLabel: l10n.text('viewBowditchAdjustment'),
      actionIcon: Icons.auto_fix_high_outlined,
      onAction: () =>
          _showBowditchAdjustmentReport(traverse, closure.knownEndpoint),
    );
  }

  String _bowditchAdjustmentCsv(CadBowditchAdjustment2D adjustment) {
    final reference = _localFrame2D == null ? 'Drawing' : 'Local';
    final rows = <String>[
      'Point,CumulativeLength,ObservedX,ObservedY,CorrectionX,CorrectionY,'
          'AdjustedX,AdjustedY,Unit,Reference,Method',
    ];
    for (final point in adjustment.points) {
      rows.add(
        'P${point.index + 1},'
        '${_displayCoordinateNumber(point.cumulativeLength)},'
        '${_displayCoordinateNumber(point.observed.dx)},'
        '${_displayCoordinateNumber(point.observed.dy)},'
        '${_displayCoordinateNumber(point.correction.dx)},'
        '${_displayCoordinateNumber(point.correction.dy)},'
        '${_displayCoordinateNumber(point.adjusted.dx)},'
        '${_displayCoordinateNumber(point.adjusted.dy)},'
        '$_unitSymbol,$reference,Bowditch',
      );
    }
    return rows.join('\n');
  }

  void _showBowditchAdjustmentReport(
    CadOpenTraverse2D traverse,
    Offset knownEndpoint,
  ) {
    final adjustment = cadBowditchAdjustment2D(traverse, knownEndpoint);
    if (adjustment == null) return;
    final csv = _bowditchAdjustmentCsv(adjustment);
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.82,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.text('bowditchReportTitle', {
                              'count': adjustment.points.length,
                            }),
                            style: Theme.of(sheetContext).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            l10n.text('bowditchMethodHint'),
                            style: Theme.of(sheetContext).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('copy_bowditch_csv'),
                      tooltip: l10n.text('copyBowditchCsv'),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        unawaited(_copyText(csv));
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('bowditch_report_list'),
                  itemCount: adjustment.points.length,
                  itemBuilder: (context, index) {
                    final point = adjustment.points[index];
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                        radius: 16,
                        child: Text('${point.index + 1}'),
                      ),
                      title: Text('P${point.index + 1}'),
                      subtitle: Text(
                        l10n.text('bowditchPointValues', {
                          'cumulative': _formatLinear(point.cumulativeLength),
                          'observed': _formatPoint2(point.observed),
                          'dx': _formatLinear(point.correction.dx),
                          'dy': _formatLinear(point.correction.dy),
                          'adjusted': _formatPoint2(point.adjusted),
                        }),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: Text(l10n.text('done')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCoordinateReferencePoint3(CadPoint3 point) {
    final origin = _localOrigin3D;
    if (origin == null) return _formatPoint3(point);
    final relative = point - origin;
    return context.l10n.text('localCoordinate3DResult', {
      'x': _formatLinear(relative.x),
      'y': _formatLinear(relative.y),
      'z': _formatLinear(relative.z),
    });
  }

  Future<void> _copyText(String value) async {
    final l10n = context.l10n;
    final copiedMessage = l10n.text('copiedToClipboard');
    String feedback;
    try {
      await Clipboard.setData(ClipboardData(text: value));
      feedback = copiedMessage;
    } catch (error) {
      feedback = l10n.text('copyFailed', {'error': error});
    }
    if (!mounted) return;
    _showViewerMessage(feedback);
  }

  bool _isMeasurementTool(ViewerTool tool) =>
      tool == ViewerTool.measureCoordinate ||
      tool == ViewerTool.collectCoordinates ||
      tool == ViewerTool.locatePolarPoint ||
      tool == ViewerTool.locateTwoDistances ||
      tool == ViewerTool.measure ||
      tool == ViewerTool.measurePath ||
      tool == ViewerTool.measureEntityLength ||
      tool == ViewerTool.measureEntityArea ||
      tool == ViewerTool.measureAngle ||
      tool == ViewerTool.measureFaceAngle ||
      tool == ViewerTool.measureRadius ||
      tool == ViewerTool.measureRadialClearance ||
      tool == ViewerTool.measureCircle3Point ||
      tool == ViewerTool.measureArc3Point ||
      tool == ViewerTool.measurePointLineOffset ||
      tool == ViewerTool.measurePolylineStation ||
      tool == ViewerTool.locatePolylineStation ||
      tool == ViewerTool.dividePolyline ||
      tool == ViewerTool.measureLineIntersection ||
      tool == ViewerTool.measureParallelLineSpacing ||
      tool == ViewerTool.measureSegmentClearance ||
      tool == ViewerTool.measureArea ||
      tool == ViewerTool.measureRectangle ||
      tool == ViewerTool.measureOrientedRectangle ||
      tool == ViewerTool.calibrateScale ||
      tool == ViewerTool.setCoordinateOrigin ||
      tool == ViewerTool.setCoordinateAxis;

  Future<void> _showMeasurementTools() async {
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<ViewerTool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _measurementUnitTile(sheetContext),
              _scaleCalibrationTile(sheetContext),
              _coordinateReferenceTile(sheetContext),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.my_location),
                title: Text(l10n.text('measureCoordinate')),
                trailing: _tool == ViewerTool.measureCoordinate
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureCoordinate),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.straighten),
                title: Text(l10n.text('measureDistance')),
                trailing: _tool == ViewerTool.measure
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, ViewerTool.measure),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.timeline),
                title: Text(l10n.text('measurePath')),
                trailing: _tool == ViewerTool.measurePath
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measurePath),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.architecture),
                title: Text(l10n.text('measureAngle')),
                trailing: _tool == ViewerTool.measureAngle
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureAngle),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.radio_button_checked),
                title: Text(l10n.text('measureRadius')),
                trailing: _tool == ViewerTool.measureRadius
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureRadius),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.square_foot),
                title: Text(l10n.text('measureArea')),
                trailing: _tool == ViewerTool.measureArea
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureArea),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.adjust),
                title: Text(l10n.text('measureRadialClearance')),
                subtitle: Text(l10n.text('measureRadialClearanceHint')),
                trailing: _tool == ViewerTool.measureRadialClearance
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measureRadialClearance,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.crop_square),
                title: Text(l10n.text('measureRectangle')),
                subtitle: Text(l10n.text('measureRectangleHint')),
                trailing: _tool == ViewerTool.measureRectangle
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureRectangle),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.crop_rotate),
                title: Text(l10n.text('measureOrientedRectangle')),
                subtitle: Text(l10n.text('measureOrientedRectangleHint')),
                trailing: _tool == ViewerTool.measureOrientedRectangle
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measureOrientedRectangle,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.circle_outlined),
                title: Text(l10n.text('measureCircle3Point')),
                subtitle: Text(l10n.text('measureCircle3PointHint')),
                trailing: _tool == ViewerTool.measureCircle3Point
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureCircle3Point),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.rotate_right),
                title: Text(l10n.text('measureArc3Point')),
                subtitle: Text(l10n.text('measureArc3PointHint')),
                trailing: _tool == ViewerTool.measureArc3Point
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureArc3Point),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.vertical_align_center),
                title: Text(l10n.text('measurePointLineOffset')),
                subtitle: Text(l10n.text('measurePointLineOffsetHint')),
                trailing: _tool == ViewerTool.measurePointLineOffset
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measurePointLineOffset,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.alt_route),
                title: Text(l10n.text('measurePolylineStation')),
                subtitle: Text(l10n.text('measurePolylineStationHint')),
                trailing: _tool == ViewerTool.measurePolylineStation
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measurePolylineStation,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.edit_location_alt_outlined),
                title: Text(l10n.text('locatePolylineStation')),
                subtitle: Text(l10n.text('locatePolylineStationHint')),
                trailing: _tool == ViewerTool.locatePolylineStation
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.locatePolylineStation,
                ),
              ),
              ListTile(
                key: const ValueKey('locate_polar_point_tool'),
                dense: true,
                leading: const Icon(Icons.assistant_navigation),
                title: Text(l10n.text('locatePolarPoint')),
                subtitle: Text(l10n.text('locatePolarPointHint')),
                trailing: _tool == ViewerTool.locatePolarPoint
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.locatePolarPoint),
              ),
              ListTile(
                key: const ValueKey('locate_two_distances_tool'),
                dense: true,
                leading: const Icon(Icons.control_point_duplicate_outlined),
                title: Text(l10n.text('locateTwoDistances')),
                subtitle: Text(l10n.text('locateTwoDistancesHint')),
                trailing: _tool == ViewerTool.locateTwoDistances
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.locateTwoDistances),
              ),
              ListTile(
                key: const ValueKey('divide_polyline_tool'),
                dense: true,
                leading: const Icon(Icons.linear_scale),
                title: Text(l10n.text('dividePolyline')),
                subtitle: Text(l10n.text('dividePolylineHint')),
                trailing: _tool == ViewerTool.dividePolyline
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.dividePolyline),
              ),
              ListTile(
                key: const ValueKey('collect_coordinates_tool'),
                dense: true,
                leading: const Icon(Icons.pin_drop_outlined),
                title: Text(l10n.text('collectCoordinates')),
                subtitle: Text(l10n.text('collectCoordinatesHint')),
                trailing: _tool == ViewerTool.collectCoordinates
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.collectCoordinates),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.call_split),
                title: Text(l10n.text('measureLineIntersection')),
                subtitle: Text(l10n.text('measureLineIntersectionHint')),
                trailing: _tool == ViewerTool.measureLineIntersection
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measureLineIntersection,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.space_bar),
                title: Text(l10n.text('measureParallelSpacing')),
                subtitle: Text(l10n.text('measureParallelSpacingHint')),
                trailing: _tool == ViewerTool.measureParallelLineSpacing
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measureParallelLineSpacing,
                ),
              ),
              ListTile(
                key: const ValueKey('measure_segment_clearance_tool'),
                dense: true,
                leading: const Icon(Icons.compare_arrows),
                title: Text(l10n.text('measureSegmentClearance')),
                subtitle: Text(l10n.text('measureSegmentClearanceHint')),
                trailing: _tool == ViewerTool.measureSegmentClearance
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(
                  sheetContext,
                  ViewerTool.measureSegmentClearance,
                ),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.functions),
                title: Text(l10n.text('measureEntityLength')),
                subtitle: Text(l10n.text('measureEntityLengthHint')),
                trailing: _tool == ViewerTool.measureEntityLength
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureEntityLength),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.playlist_add_check_circle_outlined),
                title: Text(l10n.text('measureEntityArea')),
                subtitle: Text(l10n.text('measureEntityAreaHint')),
                trailing: _tool == ViewerTool.measureEntityArea
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureEntityArea),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) _activateTool(selected);
  }

  Future<void> _show3DMeasurementTools() async {
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<ViewerTool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _measurementUnitTile(sheetContext),
              _scaleCalibrationTile(sheetContext),
              _coordinateReferenceTile(sheetContext),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.my_location),
                title: Text(l10n.text('measureCoordinate')),
                trailing: _tool == ViewerTool.measureCoordinate
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureCoordinate),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.straighten),
                title: Text(l10n.text('measureDistance')),
                trailing: _tool == ViewerTool.measure
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, ViewerTool.measure),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.architecture),
                title: Text(l10n.text('measureAngle')),
                trailing: _tool == ViewerTool.measureAngle
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureAngle),
              ),
              ListTile(
                key: const ValueKey('measure_face_angle'),
                dense: true,
                leading: const Icon(Icons.view_in_ar_outlined),
                title: Text(l10n.text('measureFaceAngle')),
                subtitle: Text(l10n.text('measureFaceAngleHint')),
                trailing: _tool == ViewerTool.measureFaceAngle
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.pop(sheetContext, ViewerTool.measureFaceAngle),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) _activateTool(selected);
  }

  Widget _measurementUnitTile(BuildContext sheetContext) {
    final l10n = context.l10n;
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.scale_outlined),
      title: Text(l10n.text('measurementUnit')),
      subtitle: Text(
        _calibrationMetersPerDrawingUnit != null && source != null
            ? l10n.text('calibratedUnitDisplay', {
                'value': _formatCalibrationScale(source),
                'display': display!.symbol,
              })
            : source == null
            ? l10n.text('drawingUnitsUnknown')
            : l10n.text('unitSourceDisplay', {
                'source': source.symbol,
                'display': display!.symbol,
              }),
      ),
      trailing: source == null ? null : const Icon(Icons.chevron_right),
      onTap: source == null
          ? null
          : () {
              Navigator.pop(sheetContext);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(_showDisplayUnitPicker());
              });
            },
    );
  }

  Widget _scaleCalibrationTile(BuildContext sheetContext) {
    final l10n = context.l10n;
    final calibrationUnit = _calibrationUnit;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.tune),
      title: Text(l10n.text('scaleCalibration')),
      subtitle: Text(
        _calibrationMetersPerDrawingUnit == null || calibrationUnit == null
            ? l10n.text('scaleCalibrationUnset')
            : l10n.text('scaleCalibrationValue', {
                'value': _formatCalibrationScale(calibrationUnit),
              }),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.pop(sheetContext);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showScaleCalibrationPicker());
        });
      },
    );
  }

  Future<void> _showScaleCalibrationPicker() async {
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const ValueKey('calibrate_scale'),
                leading: const Icon(Icons.straighten),
                title: Text(l10n.text('calibrateScale')),
                subtitle: Text(l10n.text('calibrateScaleHint')),
                onTap: () => Navigator.pop(sheetContext, 'calibrate'),
              ),
              if (_calibrationMetersPerDrawingUnit != null)
                ListTile(
                  key: const ValueKey('reset_scale_calibration'),
                  leading: const Icon(Icons.restart_alt),
                  title: Text(l10n.text('resetScaleCalibration')),
                  onTap: () => Navigator.pop(sheetContext, 'reset'),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == 'calibrate') {
      _activateTool(ViewerTool.calibrateScale);
      return;
    }
    setState(() {
      _calibrationMetersPerDrawingUnit = null;
      _calibrationUnit = null;
      _displayUnit = _sourceUnit;
      _measurement = null;
    });
    _showViewerMessage(l10n.text('scaleCalibrationReset'));
  }

  Widget _coordinateReferenceTile(BuildContext sheetContext) {
    final l10n = context.l10n;
    final value = switch (_document.sceneKind) {
      'two_d' when _localFrame2D != null => l10n.text('localAxisValue', {
        'origin': _formatPoint2(_localFrame2D!.origin),
        'direction': _formatEngineeringValue(_localFrame2D!.directionDegrees),
      }),
      'three_d' when _localOrigin3D != null => l10n.text('localOriginValue', {
        'value': _formatPoint3(_localOrigin3D!),
      }),
      _ => null,
    };
    return ListTile(
      dense: true,
      leading: const Icon(Icons.gps_fixed),
      title: Text(l10n.text('coordinateReference')),
      subtitle: Text(
        value ?? l10n.text('drawingOrigin'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.pop(sheetContext);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_showCoordinateReferencePicker());
        });
      },
    );
  }

  Future<void> _showCoordinateReferencePicker() async {
    final l10n = context.l10n;
    final hasLocalOrigin = _document.sceneKind == 'three_d'
        ? _localOrigin3D != null
        : _localOrigin2D != null;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              key: const ValueKey('set_local_origin'),
              leading: const Icon(Icons.add_location_alt_outlined),
              title: Text(l10n.text('setLocalOrigin')),
              subtitle: Text(l10n.text('setLocalOriginHint')),
              onTap: () => Navigator.pop(sheetContext, 'set'),
            ),
            if (_document.sceneKind == 'two_d')
              ListTile(
                key: const ValueKey('set_local_axis'),
                leading: const Icon(Icons.rotate_90_degrees_ccw),
                title: Text(l10n.text('setLocalAxis')),
                subtitle: Text(l10n.text('setLocalAxisHint')),
                onTap: () => Navigator.pop(sheetContext, 'axis'),
              ),
            if (_document.sceneKind == 'two_d')
              ListTile(
                key: const ValueKey('locate_coordinate'),
                leading: const Icon(Icons.gps_fixed),
                title: Text(l10n.text('locateCoordinate')),
                subtitle: Text(l10n.text('locateCoordinateHint')),
                onTap: () => Navigator.pop(sheetContext, 'locate'),
              ),
            if (hasLocalOrigin)
              ListTile(
                key: const ValueKey('use_drawing_origin'),
                leading: const Icon(Icons.restart_alt),
                title: Text(l10n.text('useDrawingOrigin')),
                onTap: () => Navigator.pop(sheetContext, 'reset'),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == 'set') {
      _activateTool(ViewerTool.setCoordinateOrigin);
    } else if (selected == 'axis') {
      _activateTool(ViewerTool.setCoordinateAxis);
    } else if (selected == 'locate') {
      await _requestCoordinateLocation();
    } else if (selected == 'reset') {
      setState(() {
        if (_document.sceneKind == 'three_d') {
          _localOrigin3D = null;
        } else {
          _localFrame2D = null;
        }
      });
    }
  }

  Future<void> _requestCoordinateLocation() async {
    final input = await showDialog<_CadCoordinateInput>(
      context: context,
      builder: (_) => _CoordinateLocationDialog(unitSymbol: _unitSymbol),
    );
    if (input == null || !mounted) return;
    final referencePoint = _referencePointFromDisplayCoordinate(input);
    final frame = _localFrame2D;
    final world = referencePoint == null
        ? null
        : frame == null
        ? referencePoint
        : frame.localToWorld(referencePoint);
    if (world == null || !world.dx.isFinite || !world.dy.isFinite) {
      _showViewerMessage(context.l10n.text('invalidCoordinateValue'));
      return;
    }
    Offset? centeredPan;
    if (!_viewportSize.isEmpty) {
      final candidate = CadViewTransform.panForAnchor(
        _document,
        _viewportSize,
        _zoom,
        world,
        _viewportSize.center(Offset.zero),
      );
      if (candidate.dx.isFinite && candidate.dy.isFinite) {
        centeredPan = candidate;
      }
    }
    _activateTool(ViewerTool.measureCoordinate);
    setState(() {
      _measurementPoints.add(world);
      if (centeredPan != null) _pan = centeredPan;
    });
    _scheduleViewportRefresh();
    _showViewerMessage(context.l10n.text('coordinateLocated'));
  }

  void _showLocalOriginSetMessage() {
    _showViewerMessage(context.l10n.text('localOriginSet'));
  }

  void _showViewerMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            12,
            0,
            12,
            _viewerChromeVisible ? 132 : 76,
          ),
          duration: const Duration(milliseconds: 1600),
        ),
      );
  }

  Future<void> _showDisplayUnitPicker() async {
    final source = _calibrationUnit ?? _sourceUnit;
    if (source == null) return;
    final choices = <CadEngineeringUnit>[source];
    for (final id in cadCommonDisplayUnitIds) {
      final candidate = cadEngineeringUnitById(id)!;
      if (candidate.id != source.id) choices.add(candidate);
    }
    final selected = await showModalBottomSheet<CadEngineeringUnit>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.scale_outlined),
                title: Text(context.l10n.text('selectDisplayUnit')),
                subtitle: Text(
                  _calibrationMetersPerDrawingUnit == null
                      ? context.l10n.text('sourceUnitValue', {
                          'source': source.symbol,
                        })
                      : context.l10n.text('scaleCalibrationValue', {
                          'value': _formatCalibrationScale(source),
                        }),
                ),
              ),
              const Divider(height: 1),
              for (final unit in choices)
                ListTile(
                  key: ValueKey('display_unit_${unit.id}'),
                  dense: true,
                  title: Text(unit.symbol),
                  trailing: (_displayUnit ?? source).id == unit.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, unit),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _displayUnit = selected);
    }
  }

  Future<void> _requestScaleCalibration(double drawingDistance) async {
    if (!drawingDistance.isFinite || drawingDistance <= 0 || !mounted) {
      _showViewerMessage(context.l10n.text('invalidCalibrationDistance'));
      _clearMeasurementPoints();
      return;
    }
    final l10n = context.l10n;
    final selectedUnit =
        _calibrationUnit ??
        _displayUnit ??
        _sourceUnit ??
        cadEngineeringUnitById('mm')!;
    final calibrationUnits = <CadEngineeringUnit>[selectedUnit];
    for (final id in cadCommonDisplayUnitIds) {
      final unit = cadEngineeringUnitById(id)!;
      if (calibrationUnits.every((candidate) => candidate.id != unit.id)) {
        calibrationUnits.add(unit);
      }
    }
    final input = await showDialog<_CadCalibrationInput>(
      context: context,
      builder: (_) => _ScaleCalibrationDialog(
        drawingDistance: drawingDistance,
        initialUnit: selectedUnit,
        units: calibrationUnits,
      ),
    );
    if (!mounted) return;
    if (input == null) {
      _clearMeasurementPoints();
      return;
    }
    final metersPerDrawingUnit = cadCalibrationMetersPerDrawingUnit(
      drawingDistance: drawingDistance,
      knownLength: input.length,
      knownUnit: input.unit,
    );
    if (metersPerDrawingUnit == null) {
      _showViewerMessage(l10n.text('invalidKnownLength'));
      _clearMeasurementPoints();
      return;
    }
    setState(() {
      _calibrationMetersPerDrawingUnit = metersPerDrawingUnit;
      _calibrationUnit = input.unit;
      _displayUnit = input.unit;
      _tool = ViewerTool.measure;
      _measurement = drawingDistance;
    });
    _showViewerMessage(
      l10n.text('calibrationApplied', {
        'value': _formatCalibrationScale(input.unit),
      }),
    );
  }

  String _formatCalibrationScale(CadEngineeringUnit unit) {
    final metersPerDrawingUnit = _calibrationMetersPerDrawingUnit;
    if (metersPerDrawingUnit == null) return '—';
    final value = metersPerDrawingUnit / unit.metersPerUnit;
    final magnitude = value.abs();
    final formatted = magnitude != 0 && (magnitude < 0.001 || magnitude >= 1e9)
        ? value.toStringAsExponential(3)
        : formatEngineeringValue(value, widget.decimalPlaces.clamp(3, 6));
    return '$formatted ${unit.symbol}';
  }

  Future<void> _showStandardViews() async {
    final l10n = context.l10n;
    final selected = await showModalBottomSheet<CadStandardView>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l10n.text('standardViewsTitle'),
                  style: Theme.of(sheetContext).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 12),
              GridView.count(
                shrinkWrap: true,
                primary: false,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                childAspectRatio: 2.45,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final view in CadStandardView.values)
                    _StandardViewTile(
                      key: ValueKey('standard_view_${view.name}'),
                      icon: _standardViewIcon(view),
                      label: _standardViewLabel(l10n, view),
                      selected: _matchesStandardView(view),
                      onTap: () => Navigator.pop(sheetContext, view),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final orientation = cadStandardViewOrientation(selected);
    setState(() {
      _yaw = orientation.yaw;
      _pitch = orientation.pitch;
    });
  }

  bool _matchesStandardView(CadStandardView view) {
    final orientation = cadStandardViewOrientation(view);
    return (_yaw - orientation.yaw).abs() <= 1e-9 &&
        (_pitch - orientation.pitch).abs() <= 1e-9;
  }

  String _standardViewLabel(AppLocalizations l10n, CadStandardView view) =>
      switch (view) {
        CadStandardView.isometric => l10n.text('viewIsometric'),
        CadStandardView.front => l10n.text('viewFront'),
        CadStandardView.top => l10n.text('viewTop'),
        CadStandardView.right => l10n.text('viewRight'),
      };

  IconData _standardViewIcon(CadStandardView view) => switch (view) {
    CadStandardView.isometric => Icons.view_in_ar_outlined,
    CadStandardView.front => Icons.crop_square,
    CadStandardView.top => Icons.grid_4x4,
    CadStandardView.right => Icons.view_sidebar_outlined,
  };

  void _activateTool(ViewerTool tool) {
    _cancelPrecisionPick();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      if (_selectedEntityId == _measuredAreaEntityId) {
        _selectedEntityId = null;
      }
      if (_selectedEntityId == _stationBaselineEntityId) {
        _selectedEntityId = null;
      }
      if (_lineIntersectionEntityIds.contains(_selectedEntityId)) {
        _selectedEntityId = null;
      }
      if (tool == ViewerTool.measureRadialClearance) {
        _selectedEntityId = null;
        _hit = null;
      }
      _tool = tool;
      _measurementPoints.clear();
      _coordinateCollectionPoints.clear();
      _areaBoundaryReportPoints.clear();
      _areaPointIntersections.clear();
      _lengthEntityMeasurements.clear();
      _areaEntityMeasurements.clear();
      _subtractedAreaEntityIds.clear();
      _areaTakeoffSubtractMode = false;
      _stationBaselineEntityId = null;
      _stationBaseline = null;
      _stationMeasurement = null;
      _stationStakeoutMeasurement = null;
      _polylineDivisionMeasurement = null;
      _polarStakeoutOriginWorld = null;
      _polarStakeoutMeasurement = null;
      _twoDistanceLocation = null;
      _intersectionFirstEntityId = null;
      _intersectionFirstSegment = null;
      _lineIntersectionMeasurement = null;
      _parallelLineSpacingMeasurement = null;
      _segmentClearanceMeasurement = null;
      _lineIntersectionEntityIds.clear();
      _radialClearanceFirstEntityId = null;
      _radialClearanceFirst = null;
      _radialClearanceMeasurement = null;
      _radialClearanceEntityIds.clear();
      _measurement3DPoints.clear();
      _measurement3DFaces.clear();
      _faceRelationMeasurement = null;
      _measurement = null;
      _measurementPerimeter = null;
      _measurementCentroid = null;
      _measuredAreaEntityId = null;
    });
  }

  void _undoMeasurementPoint() {
    if (_tool == ViewerTool.measureArea && _measuredAreaEntityId != null) {
      setState(() {
        if (_selectedEntityId == _measuredAreaEntityId) {
          _selectedEntityId = null;
        }
        _measurementPoints.clear();
        _areaBoundaryReportPoints.clear();
        _measurement = null;
        _measurementPerimeter = null;
        _measurementCentroid = null;
        _measuredAreaEntityId = null;
      });
      return;
    }
    if (_tool == ViewerTool.collectCoordinates) {
      if (_coordinateCollectionPoints.isEmpty) return;
      setState(() {
        _coordinateCollectionPoints.removeLast();
        _measurement = _coordinateCollectionPoints.isEmpty
            ? null
            : _coordinateCollectionPoints.length.toDouble();
      });
      return;
    }
    if (_tool == ViewerTool.dividePolyline) {
      setState(() {
        if (_polylineDivisionMeasurement != null) {
          _polylineDivisionMeasurement = null;
          _measurement = null;
        } else {
          if (_selectedEntityId == _stationBaselineEntityId) {
            _selectedEntityId = null;
          }
          _stationBaselineEntityId = null;
          _stationBaseline = null;
        }
      });
      return;
    }
    if (_tool == ViewerTool.locatePolarPoint) {
      setState(() {
        if (_polarStakeoutMeasurement != null) {
          _polarStakeoutMeasurement = null;
          _measurement = null;
          _measurementPoints
            ..clear()
            ..add(_polarStakeoutOriginWorld!);
        } else {
          _polarStakeoutOriginWorld = null;
          _measurementPoints.clear();
        }
      });
      return;
    }
    if (_tool == ViewerTool.locateTwoDistances) {
      setState(() {
        if (_twoDistanceLocation != null) {
          _twoDistanceLocation = null;
          _measurement = null;
        } else if (_measurementPoints.isNotEmpty) {
          _measurementPoints.removeLast();
        }
      });
      return;
    }
    if (_tool == ViewerTool.measureEntityLength) {
      if (_lengthEntityMeasurements.isEmpty) return;
      setState(() {
        _lengthEntityMeasurements.remove(_lengthEntityMeasurements.keys.last);
        _measurement = _selectedEntityLengthTotal();
      });
      return;
    }
    if (_tool == ViewerTool.measureEntityArea) {
      if (_areaEntityMeasurements.isEmpty) return;
      setState(() {
        final removed = _areaEntityMeasurements.keys.last;
        _areaEntityMeasurements.remove(removed);
        _subtractedAreaEntityIds.remove(removed);
        _updateAreaTakeoffTotals();
      });
      return;
    }
    if (_tool == ViewerTool.measurePolylineStation) {
      setState(() {
        if (_stationMeasurement != null) {
          _stationMeasurement = null;
          _measurement = null;
          _measurementPoints.clear();
        } else {
          if (_selectedEntityId == _stationBaselineEntityId) {
            _selectedEntityId = null;
          }
          _stationBaselineEntityId = null;
          _stationBaseline = null;
        }
      });
      return;
    }
    if (_tool == ViewerTool.locatePolylineStation) {
      setState(() {
        if (_stationStakeoutMeasurement != null) {
          _stationStakeoutMeasurement = null;
          _measurement = null;
          _measurementPoints.clear();
        } else {
          if (_selectedEntityId == _stationBaselineEntityId) {
            _selectedEntityId = null;
          }
          _stationBaselineEntityId = null;
          _stationBaseline = null;
        }
      });
      return;
    }
    if (_tool == ViewerTool.measureLineIntersection ||
        _tool == ViewerTool.measureParallelLineSpacing ||
        _tool == ViewerTool.measureSegmentClearance) {
      setState(() {
        final first = _intersectionFirstSegment;
        final firstEntityId = _intersectionFirstEntityId;
        final hasResult =
            _lineIntersectionMeasurement != null ||
            _parallelLineSpacingMeasurement != null ||
            _segmentClearanceMeasurement != null;
        if (hasResult && first != null && firstEntityId != null) {
          _lineIntersectionMeasurement = null;
          _parallelLineSpacingMeasurement = null;
          _segmentClearanceMeasurement = null;
          _lineIntersectionEntityIds
            ..clear()
            ..add(firstEntityId);
          _measurementPoints
            ..clear()
            ..addAll([first.start, first.end]);
          _measurement = null;
        } else {
          _intersectionFirstEntityId = null;
          _intersectionFirstSegment = null;
          _parallelLineSpacingMeasurement = null;
          _segmentClearanceMeasurement = null;
          _lineIntersectionEntityIds.clear();
          _measurementPoints.clear();
          _measurement = null;
        }
      });
      return;
    }
    if (_tool == ViewerTool.measureRadialClearance) {
      setState(() {
        final first = _radialClearanceFirst;
        final firstEntityId = _radialClearanceFirstEntityId;
        if (_radialClearanceMeasurement != null &&
            first != null &&
            firstEntityId != null) {
          _radialClearanceMeasurement = null;
          _radialClearanceEntityIds
            ..clear()
            ..add(firstEntityId);
          _measurementPoints
            ..clear()
            ..add(first.center);
        } else {
          _radialClearanceFirstEntityId = null;
          _radialClearanceFirst = null;
          _radialClearanceMeasurement = null;
          _radialClearanceEntityIds.clear();
          _measurementPoints.clear();
        }
        _measurement = null;
      });
      return;
    }
    if (_document.sceneKind == 'three_d') {
      if (_measurement3DPoints.isEmpty) return;
      setState(() {
        _measurement3DPoints.removeLast();
        if (_tool == ViewerTool.measureFaceAngle &&
            _measurement3DFaces.isNotEmpty) {
          _measurement3DFaces.removeLast();
        }
        _faceRelationMeasurement = null;
        _measurement = null;
      });
      return;
    }
    if (_measurementPoints.isEmpty) return;
    setState(() {
      _measurementPoints.removeLast();
      if (_tool == ViewerTool.measureArea &&
          _areaPointIntersections.isNotEmpty) {
        _areaPointIntersections.removeLast();
      }
      _measurementPerimeter = null;
      _measuredAreaEntityId = null;
      _measurement = switch (_tool) {
        ViewerTool.measureArea when _measurementPoints.length >= 3 =>
          widget.engine.measureArea(_measurementPoints),
        ViewerTool.measurePath when _measurementPoints.length >= 2 =>
          widget.engine.measurePath(_measurementPoints),
        _ => null,
      };
      _measurementCentroid =
          _tool == ViewerTool.measureArea && _measurement != null
          ? cadPolygonCentroid2D(_measurementPoints)
          : null;
    });
  }

  void _clearMeasurementPoints() {
    setState(() {
      if (_selectedEntityId == _measuredAreaEntityId) {
        _selectedEntityId = null;
      }
      if (_selectedEntityId == _stationBaselineEntityId) {
        _selectedEntityId = null;
      }
      if (_lineIntersectionEntityIds.contains(_selectedEntityId)) {
        _selectedEntityId = null;
      }
      _measurementPoints.clear();
      _coordinateCollectionPoints.clear();
      _areaBoundaryReportPoints.clear();
      _areaPointIntersections.clear();
      _lengthEntityMeasurements.clear();
      _areaEntityMeasurements.clear();
      _subtractedAreaEntityIds.clear();
      _areaTakeoffSubtractMode = false;
      _stationBaselineEntityId = null;
      _stationBaseline = null;
      _stationMeasurement = null;
      _stationStakeoutMeasurement = null;
      _polylineDivisionMeasurement = null;
      _polarStakeoutOriginWorld = null;
      _polarStakeoutMeasurement = null;
      _twoDistanceLocation = null;
      _intersectionFirstEntityId = null;
      _intersectionFirstSegment = null;
      _lineIntersectionMeasurement = null;
      _parallelLineSpacingMeasurement = null;
      _segmentClearanceMeasurement = null;
      _lineIntersectionEntityIds.clear();
      _radialClearanceFirstEntityId = null;
      _radialClearanceFirst = null;
      _radialClearanceMeasurement = null;
      _radialClearanceEntityIds.clear();
      _measurement3DPoints.clear();
      _measurement3DFaces.clear();
      _faceRelationMeasurement = null;
      _measurement = null;
      _measurementPerimeter = null;
      _measurementCentroid = null;
      _measuredAreaEntityId = null;
    });
  }

  Future<void> _addAnnotation(Offset world) async {
    final value = await _requestAnnotationValue();
    if (value == null || !mounted) return;
    final annotations = await widget.engine.addTextAnnotation(
      widget.opened.sessionId,
      value,
      world.dx,
      world.dy,
      _selectedEntityId,
    );
    if (mounted) setState(() => _annotations = annotations);
  }

  Future<void> _addAnnotation3D(CadMeshHit hit) async {
    final value = await _requestAnnotationValue();
    if (value == null || !mounted) return;
    final annotations = await widget.engine.addTextAnnotation3D(
      widget.opened.sessionId,
      value,
      hit.position.x,
      hit.position.y,
      hit.position.z,
      hit.meshId,
    );
    if (mounted) setState(() => _annotations = annotations);
  }

  Future<String?> _requestAnnotationValue() async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => const _AnnotationEditorDialog(),
    );
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> _exportAnnotations() async {
    final l10n = context.l10n;
    try {
      final json = await widget.engine.exportAnnotations(
        widget.opened.sessionId,
      );
      final uri = await FilePicker.saveFile(
        dialogTitle: l10n.text('exportDialog'),
        fileName: '${widget.opened.displayName}.cadnote.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
        mimeType: 'application/json',
      );
      if (uri == null) return;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(l10n.text('exported'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.text('exportFailed', {'error': error}))),
        );
      }
    }
  }

  Future<void> _exportImage() async {
    if (!_canExportImage) return;
    final frames = _sheetFrames;
    if (frames.isNotEmpty) return _exportSheetImages(frames);
    final l10n = context.l10n;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    setState(() => _exportingImage = true);
    try {
      // Fetch the current retained batch before readback, rather than exporting
      // a stale guard band immediately after a pan/zoom gesture.
      await _refreshViewport(propagateFailure: true);
      if (!mounted) return;
      final bytes = await captureViewportPng(
        _imageCaptureKey,
        devicePixelRatio: pixelRatio,
      );
      if (!mounted) return;
      final uri = await FilePicker.saveFile(
        dialogTitle: l10n.text('exportImage'),
        fileName: imageExportFileName(widget.opened.displayName),
        bytes: bytes,
        mimeType: 'image/png',
      );
      if (uri != null && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.text('imageExported'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.text('exportFailed', {'error': error})),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _exportingImage = false);
    }
  }

  /// Renders one detected sheet from a batch loaded for exactly its border.
  Future<ui.Image> _renderSheet(CadDrawingFrame frame) async {
    final batch = await widget.engine.loadViewport(
      widget.opened.sessionId,
      frame.bounds,
    );
    return renderSheetImage(batch, frame.bounds, annotations: _annotations);
  }

  /// Captures the visible viewport as an image (the existing PNG path).
  Future<ui.Image> _captureCurrentView(double pixelRatio) async {
    await _refreshViewport(propagateFailure: true);
    final png = await captureViewportPng(
      _imageCaptureKey,
      devicePixelRatio: pixelRatio,
    );
    final codec = await ui.instantiateImageCodec(png);
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _exportSheetImages(List<CadDrawingFrame> frames) async {
    final l10n = context.l10n;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final selection = await showDialog<List<int>>(
      context: context,
      builder: (context) => _SheetChoiceDialog(frames: frames),
    );
    if (selection == null || selection.isEmpty || !mounted) return;
    setState(() => _exportingImage = true);
    var saved = 0;
    try {
      for (final index in selection) {
        late final Uint8List bytes;
        late final String fileName;
        if (index < 0) {
          await _refreshViewport(propagateFailure: true);
          if (!mounted) return;
          bytes = await captureViewportPng(
            _imageCaptureKey,
            devicePixelRatio: pixelRatio,
          );
          fileName = imageExportFileName(widget.opened.displayName);
        } else {
          final frame = frames[index];
          final image = await _renderSheet(frame);
          try {
            bytes = await encodePng(image);
          } finally {
            image.dispose();
          }
          fileName = sheetExportFileName(
            widget.opened.displayName,
            index + 1,
            frame.paper,
            'png',
          );
        }
        if (!mounted) return;
        final uri = await FilePicker.saveFile(
          dialogTitle: l10n.text('exportImage'),
          fileName: fileName,
          bytes: bytes,
          mimeType: 'image/png',
        );
        // Cancelling one save dialog stops the remaining sheets.
        if (uri == null) break;
        saved++;
      }
      if (saved > 0 && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                saved == 1
                    ? l10n.text('imageExported')
                    : l10n.text('imagesExported', {'count': saved}),
              ),
            ),
          );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.text('exportFailed', {'error': error})),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _exportingImage = false);
    }
  }

  /// One page per detected sheet (sized to its paper), or the current view.
  Future<void> _exportPdf() async {
    if (!_canExportPdf) return;
    final l10n = context.l10n;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    setState(() => _exportingImage = true);
    try {
      final pages = <PdfRasterPage>[];
      final frames = _sheetFrames;
      if (frames.isEmpty) {
        final image = await _captureCurrentView(pixelRatio);
        try {
          final size = sheetPageSizePoints(
            Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
          );
          pages.add(
            await PdfRasterPage.fromImage(
              image,
              widthPoints: size.width,
              heightPoints: size.height,
            ),
          );
        } finally {
          image.dispose();
        }
      } else {
        for (final frame in frames) {
          final image = await _renderSheet(frame);
          try {
            final size = sheetPageSizePoints(frame.bounds, scale: frame.scale);
            pages.add(
              await PdfRasterPage.fromImage(
                image,
                widthPoints: size.width,
                heightPoints: size.height,
              ),
            );
          } finally {
            image.dispose();
          }
          if (!mounted) return;
        }
      }
      if (!mounted) return;
      final uri = await FilePicker.saveFile(
        dialogTitle: l10n.text('exportPdf'),
        fileName: documentExportFileName(widget.opened.displayName, 'pdf'),
        bytes: buildRasterPdf(pages),
        mimeType: 'application/pdf',
      );
      if (uri != null && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(l10n.text('pdfExported'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.text('exportFailed', {'error': error})),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _exportingImage = false);
    }
  }

  void _showAnnotations() {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, modalSetState) => SafeArea(
          child: SizedBox(
            height: 420,
            child: _annotations.isEmpty
                ? Center(child: Text(l10n.text('noAnnotations')))
                : ListView(
                    children: [
                      ListTile(
                        title: Text(
                          l10n.text('annotationManager'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          l10n.text('annotationCount', {
                            'count': _annotations.length,
                          }),
                        ),
                      ),
                      for (final annotation in _annotations)
                        ListTile(
                          leading: Icon(
                            annotation.is3D
                                ? Icons.view_in_ar_outlined
                                : Icons.location_on_outlined,
                            color: const Color(0xffffcc00),
                          ),
                          title: Text(
                            annotation.value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            l10n.text(
                              annotation.is3D ? 'anchor3d' : 'anchor2d',
                            ),
                          ),
                          trailing: IconButton(
                            tooltip: l10n.text('deleteAnnotation'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(
                                    l10n.text('deleteAnnotationQuestion'),
                                  ),
                                  content: Text(annotation.value),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: Text(l10n.text('cancel')),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: Text(l10n.text('delete')),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true || !mounted) return;
                              final annotations = await widget.engine
                                  .deleteAnnotation(
                                    widget.opened.sessionId,
                                    annotation.id,
                                  );
                              if (!mounted) return;
                              setState(() => _annotations = annotations);
                              modalSetState(() {});
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _setLayer(CadLayerModel layer, bool visible) async {
    await _setLayerVisibilities({layer.id: visible});
  }

  Future<void> _setLayerVisibilities(Map<BigInt, bool> changes) async {
    if (_visibilityUpdating || changes.isEmpty) return;
    setState(() => _visibilityUpdating = true);
    try {
      final updated = await widget.engine.setVisibilities(
        widget.opened.sessionId,
        changes,
      );
      if (!mounted) return;
      // Preserve the retained viewport entities while immediately applying the
      // authoritative native layer states. Hidden geometry disappears at once;
      // newly shown geometry arrives in the single exact viewport refresh.
      setState(() => _document = _document.withLayerStateFrom(updated));
      await _refreshViewport();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.l10n.text('layerVisibilityFailed', {'error': error}),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _visibilityUpdating = false);
    }
  }

  Future<void> _isolateLayer(CadLayerModel layer) => _setLayerVisibilities({
    for (final candidate in _document.layers)
      candidate.id: candidate.id == layer.id,
  });

  Future<void> _showAllLayers() => _setLayerVisibilities({
    for (final layer in _document.layers) layer.id: true,
  });

  Future<void> _setAssembly(CadAssemblyNode node, bool visible) async {
    final updated = await widget.engine.setVisibility(
      widget.opened.sessionId,
      node.id,
      visible,
    );
    if (mounted) setState(() => _document = updated);
  }

  void _showLayers() {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, modalSetState) {
          final layers = _document.layers;
          final roots = _document.assemblyRoots;
          if (layers.isEmpty && roots.isEmpty) {
            return SizedBox(
              height: 180,
              child: Center(child: Text(l10n.text('noLayers'))),
            );
          }
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  title: Text(
                    l10n.text(layers.isNotEmpty ? 'layers' : 'assemblyTree'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  trailing: layers.isEmpty
                      ? null
                      : TextButton(
                          onPressed:
                              _visibilityUpdating ||
                                  layers.every((layer) => layer.visible)
                              ? null
                              : () async {
                                  await _showAllLayers();
                                  if (context.mounted) modalSetState(() {});
                                },
                          child: Text(l10n.text('showAllLayers')),
                        ),
                ),
                for (final layer in layers)
                  ListTile(
                    leading: Icon(Icons.layers, color: layer.color),
                    title: Text(
                      layer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _visibilityUpdating
                        ? null
                        : () async {
                            await _setLayer(layer, !layer.visible);
                            if (context.mounted) modalSetState(() {});
                          },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: l10n.text('isolateLayer'),
                          onPressed: _visibilityUpdating
                              ? null
                              : () async {
                                  await _isolateLayer(layer);
                                  if (context.mounted) modalSetState(() {});
                                },
                          icon: const Icon(Icons.filter_center_focus),
                        ),
                        Switch(
                          value: layer.visible,
                          onChanged: _visibilityUpdating
                              ? null
                              : (value) async {
                                  await _setLayer(layer, value);
                                  if (context.mounted) modalSetState(() {});
                                },
                        ),
                      ],
                    ),
                  ),
                for (final root in roots) _assemblyTile(root, modalSetState),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _assemblyTile(CadAssemblyNode node, StateSetter modalSetState) {
    if (node.children.isEmpty) {
      return SwitchListTile(
        value: node.visible,
        secondary: const Icon(Icons.view_in_ar_outlined),
        title: Text(node.name),
        subtitle: Text(
          context.l10n.text('meshCount', {'count': node.meshIds.length}),
        ),
        onChanged: (value) async {
          await _setAssembly(node, value);
          modalSetState(() {});
        },
      );
    }
    return ExpansionTile(
      leading: const Icon(Icons.account_tree_outlined),
      title: Text(node.name),
      trailing: Switch(
        value: node.visible,
        onChanged: (value) async {
          await _setAssembly(node, value);
          modalSetState(() {});
        },
      ),
      children: [
        for (final child in node.children)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: _assemblyTile(child, modalSetState),
          ),
      ],
    );
  }

  List<({String label, String value})> _documentOverviewRows() {
    final l10n = context.l10n;
    final rows = <({String label, String value})>[
      (
        label: l10n.text('overviewFormat'),
        value: widget.opened.formatId.toUpperCase(),
      ),
      (
        label: l10n.text('overviewScene'),
        value: _sceneLabel(widget.opened.sceneKind),
      ),
    ];
    if (_document.sceneKind == 'paged') return rows;

    rows.addAll([
      (
        label: l10n.text('overviewSourceUnit'),
        value: _sourceUnit?.symbol ?? l10n.text('valueNotSpecified'),
      ),
      (label: l10n.text('overviewDisplayUnit'), value: _unitSymbol),
      (
        label: l10n.text('overviewScale'),
        value:
            _calibrationMetersPerDrawingUnit != null && _calibrationUnit != null
            ? l10n.text('scaleCalibrationValue', {
                'value': _formatCalibrationScale(_calibrationUnit!),
              })
            : l10n.text('overviewOriginalScale'),
      ),
    ]);

    if (_document.sceneKind == 'two_d') {
      rows.addAll([
        (
          label: l10n.text('overviewEntities'),
          value: widget.opened.totalEntityCount.toString(),
        ),
        (
          label: l10n.text('overviewLayers'),
          value: _document.layers.length.toString(),
        ),
      ]);
      final bounds = _document.bounds2D;
      if (bounds != null) {
        rows.addAll([
          (
            label: l10n.text('overviewBoundsMin'),
            value: _formatPoint2(bounds.topLeft),
          ),
          (
            label: l10n.text('overviewBoundsMax'),
            value: _formatPoint2(bounds.bottomRight),
          ),
          (
            label: l10n.text('propertyExtentX'),
            value: _formatLinear(bounds.width),
          ),
          (
            label: l10n.text('propertyExtentY'),
            value: _formatLinear(bounds.height),
          ),
        ]);
      }
      return [
        ...rows,
        (label: l10n.text('fileName'), value: widget.opened.displayName),
        (label: l10n.text('filePath'), value: widget.opened.sourcePath),
      ];
    }

    if (_document.sceneKind == 'three_d') {
      var vertexCount = 0;
      var triangleCount = 0;
      final surfaceAreas = <double>[];
      for (final mesh in _document.meshes) {
        vertexCount += (mesh['positions'] as List<dynamic>? ?? const []).length;
        triangleCount +=
            (mesh['indices'] as List<dynamic>? ?? const []).length ~/ 3;
        final surfaceArea = (mesh['surface_area'] as num?)?.toDouble();
        if (surfaceArea != null && surfaceArea.isFinite && surfaceArea >= 0) {
          surfaceAreas.add(surfaceArea);
        }
      }
      rows.addAll([
        (
          label: l10n.text('overviewMeshes'),
          value: _document.meshes.length.toString(),
        ),
        (
          label: l10n.text('overviewAssemblyNodes'),
          value: _assemblyNodeCount().toString(),
        ),
        (label: l10n.text('propertyVertices'), value: vertexCount.toString()),
        (
          label: l10n.text('propertyTriangles'),
          value: triangleCount.toString(),
        ),
      ]);
      if (surfaceAreas.length == _document.meshes.length) {
        final totalSurfaceArea = _compensatedTotal(surfaceAreas);
        if (totalSurfaceArea != null && totalSurfaceArea.isFinite) {
          rows.add((
            label: l10n.text('overviewSurfaceArea'),
            value: _formatArea(totalSurfaceArea),
          ));
        }
      }
      final bounds = _sceneBounds3D();
      if (bounds != null) {
        rows.addAll([
          (
            label: l10n.text('overviewBoundsMin'),
            value: _formatPoint3(
              CadPoint3(bounds.minX, bounds.minY, bounds.minZ),
            ),
          ),
          (
            label: l10n.text('overviewBoundsMax'),
            value: _formatPoint3(
              CadPoint3(bounds.maxX, bounds.maxY, bounds.maxZ),
            ),
          ),
          (
            label: l10n.text('propertyExtentX'),
            value: _formatLinear(bounds.sizeX),
          ),
          (
            label: l10n.text('propertyExtentY'),
            value: _formatLinear(bounds.sizeY),
          ),
          (
            label: l10n.text('propertyExtentZ'),
            value: _formatLinear(bounds.sizeZ),
          ),
        ]);
      }
    }
    return [
      ...rows,
      (label: l10n.text('fileName'), value: widget.opened.displayName),
      (label: l10n.text('filePath'), value: widget.opened.sourcePath),
    ];
  }

  int _assemblyNodeCount() {
    int count(CadAssemblyNode node) =>
        1 + node.children.fold(0, (sum, child) => sum + count(child));
    return _document.assemblyRoots.fold(0, (sum, root) => sum + count(root));
  }

  CadBounds3D? _sceneBounds3D() {
    final bounds = _document.scene['bounds'] as Map<String, dynamic>?;
    final min = bounds?['min'] as Map<String, dynamic>?;
    final max = bounds?['max'] as Map<String, dynamic>?;
    final values = [
      (min?['x'] as num?)?.toDouble(),
      (min?['y'] as num?)?.toDouble(),
      (min?['z'] as num?)?.toDouble(),
      (max?['x'] as num?)?.toDouble(),
      (max?['y'] as num?)?.toDouble(),
      (max?['z'] as num?)?.toDouble(),
    ];
    if (values.any((value) => value == null || !value.isFinite)) return null;
    return CadBounds3D(
      minX: values[0]!,
      minY: values[1]!,
      minZ: values[2]!,
      maxX: values[3]!,
      maxY: values[4]!,
      maxZ: values[5]!,
    );
  }

  void _showDocumentOverview() {
    final l10n = context.l10n;
    final rows = _documentOverviewRows();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final height = math.min(
          620.0,
          MediaQuery.sizeOf(sheetContext).height * 0.82,
        );
        return SafeArea(
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.analytics_outlined),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.text('documentOverview'),
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.text('copyProperties'),
                        onPressed: () => unawaited(
                          _copyText(
                            cadPropertiesClipboardText(
                              l10n.text('documentOverview'),
                              rows,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.copy_all_outlined),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    key: const ValueKey('document_overview_list'),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final row in rows)
                        ListTile(
                          dense: true,
                          title: Text(row.label),
                          subtitle: SelectableText(row.value),
                        ),
                      const Divider(),
                      ListTile(
                        title: Text(
                          l10n.text('documentDiagnostics'),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          l10n.text('diagnosticCount', {
                            'count': _document.diagnostics.length,
                          }),
                        ),
                      ),
                      if (_document.diagnostics.isEmpty)
                        ListTile(
                          leading: const Icon(
                            Icons.check_circle,
                            color: Color(0xff73d13d),
                          ),
                          title: Text(l10n.text('noCompatibilityIssues')),
                        ),
                      for (final diagnostic in _document.diagnostics)
                        ListTile(
                          leading: const Icon(
                            Icons.warning_amber,
                            color: Color(0xffffc53d),
                          ),
                          title: Text(diagnostic['code'] as String),
                          subtitle: Text(diagnostic['message'] as String),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final areaBoundaryEdges = _activeAreaBoundaryEdges();
    final areaBoundaryPoints = _measuredAreaEntityId == null
        ? _measurementPoints
        : _areaBoundaryReportPoints;
    final volumeArea = _activePlanAreaForVolume();
    final lateralPerimeter = _activePlanPerimeterForHeight();
    final linearQuantityLength = _activeLinearQuantityLength();
    final compactTopBar =
        MediaQuery.sizeOf(context).width < 900 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final annotationsAvailable =
        DistributionConfig.fullFeatures && widget.opened.formatId != 'pdf';
    final editingMultiPointMeasurement =
        ((_tool == ViewerTool.measureArea ||
                _tool == ViewerTool.measureRectangle ||
                _tool == ViewerTool.measureOrientedRectangle ||
                _tool == ViewerTool.measureCircle3Point ||
                _tool == ViewerTool.measureArc3Point ||
                _tool == ViewerTool.measurePointLineOffset ||
                _tool == ViewerTool.measurePath ||
                _tool == ViewerTool.setCoordinateAxis ||
                _tool == ViewerTool.calibrateScale) &&
            _measurementPoints.isNotEmpty) ||
        (_tool == ViewerTool.measureArea &&
            _areaBoundaryReportPoints.isNotEmpty) ||
        (_tool == ViewerTool.measureArea && _measurement != null) ||
        (_tool == ViewerTool.measureEntityLength &&
            _lengthEntityMeasurements.isNotEmpty) ||
        (_tool == ViewerTool.measureEntityArea &&
            _areaEntityMeasurements.isNotEmpty) ||
        (_tool == ViewerTool.measurePolylineStation &&
            _stationBaseline != null) ||
        (_tool == ViewerTool.locatePolylineStation &&
            _stationBaseline != null) ||
        (_tool == ViewerTool.dividePolyline && _stationBaseline != null) ||
        (_tool == ViewerTool.locatePolarPoint &&
            _polarStakeoutOriginWorld != null) ||
        (_tool == ViewerTool.locateTwoDistances &&
            _measurementPoints.isNotEmpty) ||
        (_tool == ViewerTool.collectCoordinates &&
            _coordinateCollectionPoints.isNotEmpty) ||
        (_tool == ViewerTool.measureLineIntersection &&
            _intersectionFirstSegment != null) ||
        (_tool == ViewerTool.measureParallelLineSpacing &&
            _intersectionFirstSegment != null) ||
        (_tool == ViewerTool.measureSegmentClearance &&
            _intersectionFirstSegment != null) ||
        (_tool == ViewerTool.measureRadialClearance &&
            _radialClearanceFirst != null) ||
        (_document.sceneKind == 'three_d' &&
            (_tool == ViewerTool.measure ||
                _tool == ViewerTool.measureAngle ||
                _tool == ViewerTool.measureFaceAngle ||
                _tool == ViewerTool.calibrateScale) &&
            _measurement3DPoints.isNotEmpty);
    final hasMeasurementResult =
        _measurement != null ||
        (_tool == ViewerTool.measureCoordinate &&
            (_document.sceneKind == 'three_d'
                ? _measurement3DPoints.isNotEmpty
                : _measurementPoints.isNotEmpty));
    return Scaffold(
      appBar: _viewerChromeVisible
          ? AppBar(
              titleSpacing: 4,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => showDocumentDetails(
                      context,
                      widget.opened.displayName,
                      widget.opened.sourcePath,
                    ),
                    child: Text(
                      widget.opened.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${widget.opened.formatId.toUpperCase()} · '
                    '${_sceneLabel(widget.opened.sceneKind)}'
                    '${_document.sceneKind == 'paged' ? '' : ' · $_unitSymbol'}',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
              actions: [
                if (!compactTopBar && annotationsAvailable) ...[
                  IconButton(
                    tooltip: l10n.text('annotations'),
                    onPressed: _showAnnotations,
                    icon: Badge(
                      isLabelVisible: _annotations.isNotEmpty,
                      label: Text('${_annotations.length}'),
                      child: const Icon(Icons.comment_outlined),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.text('exportAnnotations'),
                    onPressed: _exportAnnotations,
                    icon: const Icon(Icons.file_download_outlined),
                  ),
                ],
                IconButton(
                  tooltip: l10n.text('fitView'),
                  onPressed: _resetView,
                  icon: const Icon(Icons.fit_screen),
                ),
                if (compactTopBar)
                  PopupMenuButton<_ViewerMenuAction>(
                    key: const ValueKey('viewer_more_actions'),
                    tooltip: MaterialLocalizations.of(context)
                        .moreButtonTooltip,
                    onSelected: _handleViewerMenuAction,
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: _ViewerMenuAction.exportImage,
                        enabled: _canExportImage,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: _exportingImage
                              ? const SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.image_outlined),
                          title: Text(l10n.text('exportImage')),
                        ),
                      ),
                      if (widget.opened.formatId != 'pdf')
                        PopupMenuItem(
                          value: _ViewerMenuAction.exportPdf,
                          enabled: _canExportPdf,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.picture_as_pdf_outlined),
                            title: Text(l10n.text('exportPdf')),
                          ),
                        ),
                      if (annotationsAvailable)
                        PopupMenuItem(
                          value: _ViewerMenuAction.annotations,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.comment_outlined),
                            title: Text(l10n.text('annotations')),
                          ),
                        ),
                      if (annotationsAvailable)
                        PopupMenuItem(
                          value: _ViewerMenuAction.exportAnnotations,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.file_download_outlined),
                            title: Text(l10n.text('exportAnnotations')),
                          ),
                        ),
                      PopupMenuItem(
                        value: _ViewerMenuAction.layers,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.layers_outlined),
                          title: Text(l10n.text('layersAssembly')),
                        ),
                      ),
                      PopupMenuItem(
                        value: _ViewerMenuAction.overview,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.info_outline),
                          title: Text(l10n.text('documentOverview')),
                        ),
                      ),
                    ],
                  )
                else ...[
                  IconButton(
                    tooltip: l10n.text('exportImage'),
                    onPressed: _canExportImage ? _exportImage : null,
                    icon: _exportingImage
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image_outlined),
                  ),
                  if (widget.opened.formatId != 'pdf')
                    IconButton(
                      tooltip: l10n.text('exportPdf'),
                      onPressed: _canExportPdf ? _exportPdf : null,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                    ),
                  IconButton(
                    tooltip: l10n.text('layersAssembly'),
                    onPressed: _showLayers,
                    icon: const Icon(Icons.layers_outlined),
                  ),
                  IconButton(
                    tooltip: l10n.text('documentOverview'),
                    onPressed: _showDocumentOverview,
                    icon: const Icon(Icons.info_outline),
                  ),
                ],
                IconButton(
                  tooltip: l10n.text('enterFullscreen'),
                  onPressed: _toggleViewerChrome,
                  icon: const Icon(Icons.fullscreen),
                ),
              ],
            )
          : null,
      floatingActionButton: _viewerChromeVisible
          ? null
          : FloatingActionButton.small(
              heroTag: 'viewer_controls',
              tooltip: l10n.text('showControls'),
              onPressed: _toggleViewerChrome,
              backgroundColor: const Color(0xdd111923),
              child: const Icon(Icons.fullscreen_exit),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endTop,
      body: Column(
        children: [
          Expanded(
            child: widget.opened.formatId == 'pdf'
                ? PdfDocumentViewport(
                    path: widget.opened.sourcePath,
                    captureKey: _imageCaptureKey,
                    onExportReadyChanged: (ready) {
                      if (mounted && ready != _pdfExportReady) {
                        setState(() => _pdfExportReady = ready);
                      }
                    },
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      final viewportChanged = size != _viewportSize;
                      _viewportSize = size;
                      if (_document.sceneKind == 'two_d' &&
                          (!_initialViewportRequested || viewportChanged)) {
                        _initialViewportRequested = true;
                        _scheduleViewportRefresh();
                      }
                      return Listener(
                        onPointerDown: (_) {
                          _activePointers++;
                          if (_activePointers > 1) {
                            setState(_cancelPrecisionPick);
                          }
                        },
                        onPointerUp: (_) =>
                            _activePointers = math.max(0, _activePointers - 1),
                        onPointerCancel: (_) {
                          _activePointers = math.max(0, _activePointers - 1);
                          setState(_cancelPrecisionPick);
                        },
                        child: GestureDetector(
                          onLongPressStart: _canPrecisionPick
                              ? (details) => _previewPrecisionPick(
                                  details.localPosition,
                                  size,
                                )
                              : null,
                          onLongPressMoveUpdate: _canPrecisionPick
                              ? (details) {
                                  if (_precisionPosition != null) {
                                    unawaited(
                                      _previewPrecisionPick(
                                        details.localPosition,
                                        size,
                                      ),
                                    );
                                  }
                                }
                              : null,
                          onLongPressEnd: _canPrecisionPick
                              ? (details) => _finishPrecisionPick(
                                  details.localPosition,
                                  size,
                                )
                              : null,
                          onLongPressCancel: () =>
                              setState(_cancelPrecisionPick),
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (details) =>
                              _onScaleStart(details, size),
                          onScaleUpdate: (details) =>
                              _onScaleUpdate(details, size),
                          onScaleEnd: _onScaleEnd,
                          onTapUp: (details) =>
                              _onTap(details.localPosition, size),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              RepaintBoundary(
                                key: _imageCaptureKey,
                                child: CustomPaint(
                                  painter: CadScenePainter(
                                    document: _document,
                                    zoom: _zoom,
                                    pan: _pan,
                                    annotations: _annotations,
                                    selectedEntityId: _selectedEntityId,
                                    selectedEntityIds: {
                                      ..._lengthEntityMeasurements.keys,
                                      ..._areaEntityMeasurements.keys,
                                      ..._lineIntersectionEntityIds,
                                      ..._radialClearanceEntityIds,
                                    },
                                    subtractedEntityIds: Set.of(
                                      _subtractedAreaEntityIds,
                                    ),
                                    measurementPoints: List.of(
                                      _measurementPoints,
                                    ),
                                    measurementIntersectionPoints: [
                                      if (_tool ==
                                              ViewerTool
                                                  .locatePolylineStation &&
                                          _stationStakeoutMeasurement != null)
                                        _stationStakeoutMeasurement!
                                            .targetPoint,
                                      if (_tool ==
                                              ViewerTool.locatePolarPoint &&
                                          _polarStakeoutMeasurement != null &&
                                          _measurementPoints.length == 2)
                                        _measurementPoints.last,
                                      if (_tool ==
                                              ViewerTool.locateTwoDistances &&
                                          _twoDistanceLocation != null)
                                        ..._twoDistanceLocation!.solutions,
                                      if (_tool == ViewerTool.dividePolyline &&
                                          _polylineDivisionMeasurement != null)
                                        ..._polylineDivisionMeasurement!
                                            .divisionPoints,
                                      for (
                                        var index = 0;
                                        index < _measurementPoints.length &&
                                            index <
                                                _areaPointIntersections.length;
                                        index++
                                      )
                                        if (_areaPointIntersections[index])
                                          _measurementPoints[index],
                                    ],
                                    indexedMeasurementPoints:
                                        _tool == ViewerTool.collectCoordinates
                                        ? List.of(_coordinateCollectionPoints)
                                        : areaBoundaryEdges != null
                                        ? List.of(areaBoundaryPoints)
                                        : const [],
                                    measurementCentroid: switch (_tool) {
                                      ViewerTool.measureArea =>
                                        _measurementCentroid,
                                      ViewerTool.measureRectangle
                                          when _measurementPoints.length == 2 =>
                                        cadRectangleMeasurement2D(
                                          _measurementPoints[0],
                                          _measurementPoints[1],
                                        )?.center,
                                      ViewerTool.measureOrientedRectangle
                                          when _measurementPoints.length == 3 =>
                                        cadOrientedRectangleMeasurement2D(
                                          _measurementPoints[0],
                                          _measurementPoints[1],
                                          _measurementPoints[2],
                                        )?.center,
                                      _ => null,
                                    },
                                    measurementClosed:
                                        _tool == ViewerTool.measureArea,
                                    measurementRectangle:
                                        _tool == ViewerTool.measureRectangle,
                                    measurementOrientedRectangle:
                                        _tool ==
                                        ViewerTool.measureOrientedRectangle,
                                    measurementCircle3Point:
                                        _tool == ViewerTool.measureCircle3Point,
                                    measurementArc3Point:
                                        _tool == ViewerTool.measureArc3Point,
                                    measurementPointLineOffset:
                                        _tool ==
                                        ViewerTool.measurePointLineOffset,
                                    measurementLineIntersection:
                                        _tool ==
                                        ViewerTool.measureLineIntersection,
                                    measurementParallelLineSpacing:
                                        _tool ==
                                        ViewerTool.measureParallelLineSpacing,
                                    measurementSegmentClearance:
                                        _tool ==
                                        ViewerTool.measureSegmentClearance,
                                    measurementMidpoint:
                                        _tool == ViewerTool.measure,
                                    measurementAngle:
                                        _tool == ViewerTool.measureAngle,
                                    yaw: _yaw,
                                    pitch: _pitch,
                                    selectedMeshId: _selectedMeshId,
                                    measurement3DPoints: List.of(
                                      _measurement3DPoints,
                                    ),
                                    measurement3DFaces: [
                                      for (final face in _measurement3DFaces)
                                        face.hit,
                                    ],
                                    measurement3DAngle:
                                        _document.sceneKind == 'three_d' &&
                                        _tool == ViewerTool.measureAngle,
                                    coordinateOrigin2D: _localOrigin2D,
                                    coordinateXAxis2D: _localFrame2D?.xAxis,
                                    coordinateOrigin3D: _localOrigin3D,
                                  ),
                                ),
                              ),
                              if (_document.sceneKind == 'two_d' &&
                                  _document.bounds2D == null)
                                Center(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 420,
                                    ),
                                    child: Card(
                                      margin: const EdgeInsets.all(24),
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.warning_amber_rounded,
                                              color: Color(0xffffb74d),
                                              size: 36,
                                            ),
                                            const SizedBox(height: 12),
                                            Text(
                                              l10n.text('noVisibleGeometry'),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              _emptySceneDiagnostic(),
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned(
                                left: 12,
                                right: 12,
                                top: 12,
                                child: Align(
                                  alignment: Alignment.topLeft,
                                  child: _StatusPill(
                                    text: _precisionPosition != null
                                        ? l10n.text('precisionPickRelease')
                                        : _statusText(),
                                    hint: _canPrecisionPick
                                        ? l10n.text('precisionPickHint')
                                        : null,
                                    icon: switch (_tool) {
                                      ViewerTool.measure => Icons.straighten,
                                      ViewerTool.measureCoordinate =>
                                        Icons.my_location,
                                      ViewerTool.collectCoordinates =>
                                        Icons.pin_drop_outlined,
                                      ViewerTool.locatePolarPoint =>
                                        Icons.assistant_navigation,
                                      ViewerTool.locateTwoDistances =>
                                        Icons.control_point_duplicate_outlined,
                                      ViewerTool.measurePath => Icons.timeline,
                                      ViewerTool.measureEntityLength =>
                                        Icons.functions,
                                      ViewerTool.measureEntityArea =>
                                        Icons
                                            .playlist_add_check_circle_outlined,
                                      ViewerTool.measureAngle =>
                                        Icons.architecture,
                                      ViewerTool.measureFaceAngle =>
                                        Icons.view_in_ar_outlined,
                                      ViewerTool.measureRadius =>
                                        Icons.radio_button_checked,
                                      ViewerTool.measureRadialClearance =>
                                        Icons.adjust,
                                      ViewerTool.measureCircle3Point =>
                                        Icons.circle_outlined,
                                      ViewerTool.measureArc3Point =>
                                        Icons.rotate_right,
                                      ViewerTool.measurePointLineOffset =>
                                        Icons.vertical_align_center,
                                      ViewerTool.measurePolylineStation =>
                                        Icons.alt_route,
                                      ViewerTool.locatePolylineStation =>
                                        Icons.edit_location_alt_outlined,
                                      ViewerTool.dividePolyline =>
                                        Icons.linear_scale,
                                      ViewerTool.measureLineIntersection =>
                                        Icons.call_split,
                                      ViewerTool.measureParallelLineSpacing =>
                                        Icons.space_bar,
                                      ViewerTool.measureSegmentClearance =>
                                        Icons.compare_arrows,
                                      ViewerTool.measureArea =>
                                        Icons.square_foot,
                                      ViewerTool.measureRectangle =>
                                        Icons.crop_square,
                                      ViewerTool.measureOrientedRectangle =>
                                        Icons.crop_rotate,
                                      ViewerTool.calibrateScale => Icons.tune,
                                      ViewerTool.setCoordinateOrigin =>
                                        Icons.add_location_alt_outlined,
                                      ViewerTool.setCoordinateAxis =>
                                        Icons.rotate_90_degrees_ccw,
                                      _ => Icons.touch_app,
                                    },
                                  ),
                                ),
                              ),
                              if (hasMeasurementResult)
                                Positioned(
                                  left: 12,
                                  right: 12,
                                  bottom: editingMultiPointMeasurement
                                      ? 64
                                      : 12,
                                  child: Align(
                                    alignment: Alignment.bottomLeft,
                                    child: _StatusPill(
                                      text: _measurementResultText(),
                                      icon: switch (_tool) {
                                        ViewerTool.measurePath =>
                                          Icons.timeline,
                                        ViewerTool.measureEntityLength =>
                                          Icons.functions,
                                        ViewerTool.measureEntityArea =>
                                          Icons
                                              .playlist_add_check_circle_outlined,
                                        ViewerTool.measureCoordinate =>
                                          Icons.my_location,
                                        ViewerTool.collectCoordinates =>
                                          Icons.pin_drop_outlined,
                                        ViewerTool.locatePolarPoint =>
                                          Icons.assistant_navigation,
                                        ViewerTool.locateTwoDistances =>
                                          Icons
                                              .control_point_duplicate_outlined,
                                        ViewerTool.measureAngle =>
                                          Icons.architecture,
                                        ViewerTool.measureFaceAngle =>
                                          Icons.view_in_ar_outlined,
                                        ViewerTool.measureRadius =>
                                          Icons.radio_button_checked,
                                        ViewerTool.measureRadialClearance =>
                                          Icons.adjust,
                                        ViewerTool.measureCircle3Point =>
                                          Icons.circle_outlined,
                                        ViewerTool.measureArc3Point =>
                                          Icons.rotate_right,
                                        ViewerTool.measurePointLineOffset =>
                                          Icons.vertical_align_center,
                                        ViewerTool.measurePolylineStation =>
                                          Icons.alt_route,
                                        ViewerTool.locatePolylineStation =>
                                          Icons.edit_location_alt_outlined,
                                        ViewerTool.dividePolyline =>
                                          Icons.linear_scale,
                                        ViewerTool.measureLineIntersection =>
                                          Icons.call_split,
                                        ViewerTool.measureParallelLineSpacing =>
                                          Icons.space_bar,
                                        ViewerTool.measureSegmentClearance =>
                                          Icons.compare_arrows,
                                        ViewerTool.measureArea =>
                                          Icons.square_foot,
                                        ViewerTool.measureRectangle =>
                                          Icons.crop_square,
                                        ViewerTool.measureOrientedRectangle =>
                                          Icons.crop_rotate,
                                        _ => Icons.straighten,
                                      },
                                      accent: true,
                                      expand: true,
                                      copyTooltip: l10n.text(
                                        _tool == ViewerTool.collectCoordinates
                                            ? 'copyCoordinateCsv'
                                            : 'copyMeasurement',
                                      ),
                                      onCopy: () => unawaited(
                                        _copyText(
                                          _tool == ViewerTool.collectCoordinates
                                              ? _coordinateCollectionCsv()
                                              : _measurementResultText(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (editingMultiPointMeasurement)
                                Positioned(
                                  left: 12,
                                  right: 12,
                                  bottom: 12,
                                  child: Align(
                                    alignment: Alignment.bottomRight,
                                    child: SingleChildScrollView(
                                      key: const ValueKey(
                                        'measurement_overlay_actions',
                                      ),
                                      scrollDirection: Axis.horizontal,
                                      reverse: true,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (_tool ==
                                                  ViewerTool
                                                      .locatePolylineStation &&
                                              _stationBaseline != null) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'enterAnotherStationOffset',
                                              ),
                                              icon: Icons
                                                  .edit_location_alt_outlined,
                                              onPressed: () => unawaited(
                                                _requestStationOffsetLocation(),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (_tool ==
                                                  ViewerTool.locatePolarPoint &&
                                              _polarStakeoutOriginWorld !=
                                                  null) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'enterAnotherPolarStakeout',
                                              ),
                                              icon: Icons.assistant_navigation,
                                              onPressed: () => unawaited(
                                                _requestPolarStakeoutLocation(),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (_tool ==
                                                  ViewerTool
                                                      .locateTwoDistances &&
                                              _measurementPoints.length ==
                                                  2) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'enterAnotherTwoDistancePair',
                                              ),
                                              icon: Icons
                                                  .control_point_duplicate_outlined,
                                              onPressed: () => unawaited(
                                                _requestTwoDistanceLocation(),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (_tool ==
                                                  ViewerTool.dividePolyline &&
                                              _stationBaseline != null) ...[
                                            if (_polylineDivisionMeasurement !=
                                                null) ...[
                                              _OverlayActionButton(
                                                tooltip: l10n.text(
                                                  'viewDivisionTable',
                                                ),
                                                icon: Icons.table_rows_outlined,
                                                onPressed:
                                                    _showDivisionStakeoutTable,
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'enterAnotherDivisionCount',
                                              ),
                                              icon: Icons.linear_scale,
                                              onPressed: () => unawaited(
                                                _requestPolylineDivision(),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (_tool ==
                                                  ViewerTool
                                                      .collectCoordinates &&
                                              _coordinateCollectionPoints
                                                  .isNotEmpty) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'viewCoordinateTable',
                                              ),
                                              icon: Icons.table_rows_outlined,
                                              onPressed:
                                                  _showCoordinateCollectionTable,
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (_tool == ViewerTool.measureArea &&
                                              areaBoundaryEdges != null) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'viewBoundaryReport',
                                              ),
                                              icon: Icons.list_alt_outlined,
                                              onPressed: _showBoundaryReport,
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (volumeArea != null ||
                                              lateralPerimeter != null ||
                                              linearQuantityLength != null) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                'engineeringQuantities',
                                              ),
                                              icon: Icons.calculate_outlined,
                                              onPressed: () =>
                                                  _showEngineeringQuantityActions(
                                                    area: volumeArea,
                                                    perimeter: lateralPerimeter,
                                                    linearLength:
                                                        linearQuantityLength,
                                                    sectionPropertiesAvailable:
                                                        volumeArea != null &&
                                                        _tool !=
                                                            ViewerTool
                                                                .measureEntityArea,
                                                  ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          if (_tool ==
                                              ViewerTool.measureEntityArea) ...[
                                            _OverlayActionButton(
                                              tooltip: l10n.text(
                                                _areaTakeoffSubtractMode
                                                    ? 'switchToAreaAdd'
                                                    : 'switchToAreaSubtract',
                                              ),
                                              icon: _areaTakeoffSubtractMode
                                                  ? Icons.remove_circle_outline
                                                  : Icons.add_circle_outline,
                                              color: _areaTakeoffSubtractMode
                                                  ? const Color(0xffff6b6b)
                                                  : const Color(0xffffd666),
                                              onPressed: _toggleAreaTakeoffMode,
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          _OverlayActionButton(
                                            tooltip: l10n.text(
                                              _tool ==
                                                          ViewerTool
                                                              .measureEntityLength ||
                                                      _tool ==
                                                          ViewerTool
                                                              .measureEntityArea
                                                  ? 'undoLastEntity'
                                                  : 'undoLastPoint',
                                            ),
                                            icon: Icons.undo,
                                            onPressed: _undoMeasurementPoint,
                                          ),
                                          const SizedBox(width: 8),
                                          _OverlayActionButton(
                                            tooltip: l10n.text(
                                              _tool ==
                                                          ViewerTool
                                                              .measureEntityLength ||
                                                      _tool ==
                                                          ViewerTool
                                                              .measureEntityArea
                                                  ? 'clearEntitySelection'
                                                  : 'clearMeasurement',
                                            ),
                                            icon: Icons.delete_sweep_outlined,
                                            onPressed: _clearMeasurementPoints,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (_precisionPosition != null)
                                _buildPrecisionLoupe(size),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_viewerChromeVisible && widget.opened.formatId != 'pdf')
            Container(
              decoration: const BoxDecoration(
                color: Color(0xff0e1720),
                border: Border(top: BorderSide(color: Colors.white10)),
              ),
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  height: 56,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Expanded(
                        child: _ToolButton(
                          icon: Icons.pan_tool_outlined,
                          label: l10n.text('browse'),
                          selected: _tool == ViewerTool.pan,
                          onTap: () => _activateTool(ViewerTool.pan),
                        ),
                      ),
                      if (_document.sceneKind == 'three_d')
                        Expanded(
                          child: _ToolButton(
                            icon: Icons.view_in_ar_outlined,
                            label: l10n.text('standardViews'),
                            selected: false,
                            onTap: () => unawaited(_showStandardViews()),
                          ),
                        ),
                      if (DistributionConfig.fullFeatures)
                        Expanded(
                          child: _ToolButton(
                            icon: Icons.mode_comment_outlined,
                            label: l10n.text('annotate'),
                            selected: _tool == ViewerTool.annotate,
                            onTap: () => _activateTool(ViewerTool.annotate),
                          ),
                        ),
                      Expanded(
                        child: _ToolButton(
                          icon: Icons.near_me_outlined,
                          label: l10n.text('select'),
                          selected: _tool == ViewerTool.select,
                          onTap: () => _activateTool(ViewerTool.select),
                        ),
                      ),
                      if (DistributionConfig.fullFeatures)
                        Expanded(
                          child: _ToolButton(
                            icon: Icons.straighten,
                            label: l10n.text('measure'),
                            selected: _isMeasurementTool(_tool),
                            onTap: () => _document.sceneKind == 'three_d'
                                ? unawaited(_show3DMeasurementTools())
                                : unawaited(_showMeasurementTools()),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _statusText() {
    final l10n = context.l10n;
    if (_tool == ViewerTool.calibrateScale) {
      final count = _document.sceneKind == 'three_d'
          ? _measurement3DPoints.length
          : _measurementPoints.length;
      return l10n.text(
        count == 0 ? 'selectCalibrationStart' : 'selectCalibrationEnd',
      );
    }
    if (_tool == ViewerTool.setCoordinateOrigin) {
      return l10n.text('selectLocalOrigin');
    }
    if (_tool == ViewerTool.setCoordinateAxis) {
      return l10n.text(
        _measurementPoints.isEmpty
            ? 'selectLocalAxisOrigin'
            : 'selectLocalAxisDirection',
      );
    }
    if (_tool == ViewerTool.measureArea) {
      if (_measuredAreaEntityId != null) {
        return l10n.text('selectAnotherAreaBoundary');
      }
      if (_measurementPoints.length >= 3 && _measurement == null) {
        return l10n.text('invalidAreaBoundary');
      }
      return l10n.text(
        _measurementPoints.length < 3 ? 'selectAreaPoints' : 'addAreaPoint',
        {'count': _measurementPoints.length},
      );
    }
    if (_tool == ViewerTool.measureRectangle) {
      if (_measurementPoints.length == 2 && _measurement == null) {
        return l10n.text('invalidRectangle');
      }
      return l10n.text(switch (_measurementPoints.length) {
        0 => 'selectRectangleFirst',
        1 => 'selectRectangleSecond',
        _ => 'selectAnotherRectangle',
      });
    }
    if (_tool == ViewerTool.measureCoordinate) {
      return l10n.text('selectCoordinatePoint');
    }
    if (_tool == ViewerTool.collectCoordinates) {
      return l10n.text('collectCoordinatePrompt', {
        'count': _coordinateCollectionPoints.length,
        'maximum': _maximumCoordinateCollectionPoints,
      });
    }
    if (_tool == ViewerTool.locatePolarPoint) {
      if (_polarStakeoutOriginWorld == null) {
        return l10n.text('selectPolarStakeoutOrigin');
      }
      return l10n.text(
        _polarStakeoutMeasurement == null
            ? 'enterPolarStakeoutPrompt'
            : 'locateAnotherPolarStakeoutPrompt',
      );
    }
    if (_tool == ViewerTool.locateTwoDistances) {
      return l10n.text(switch (_measurementPoints.length) {
        0 => 'selectFirstTwoDistanceReference',
        1 => 'selectSecondTwoDistanceReference',
        _ when _twoDistanceLocation == null => 'enterTwoDistancePrompt',
        _ => 'locateAnotherTwoDistancePrompt',
      });
    }
    if (_tool == ViewerTool.measurePath) {
      return l10n.text(
        _measurementPoints.length < 2 ? 'selectPathPoints' : 'addPathPoint',
        {'count': _measurementPoints.length},
      );
    }
    if (_tool == ViewerTool.measureEntityLength) {
      return l10n.text('selectLengthEntities', {
        'count': _lengthEntityMeasurements.length,
      });
    }
    if (_tool == ViewerTool.measureEntityArea) {
      return l10n.text('selectAreaEntities', {
        'count': _areaEntityMeasurements.length,
        'mode': l10n.text(
          _areaTakeoffSubtractMode
              ? 'areaTakeoffModeSubtract'
              : 'areaTakeoffModeAdd',
        ),
      });
    }
    if (_tool == ViewerTool.measureCircle3Point) {
      return l10n.text(switch (_measurementPoints.length) {
        0 => 'selectCircleFirstPoint',
        1 => 'selectCircleSecondPoint',
        2 => 'selectCircleThirdPoint',
        _ => 'selectAnotherThreePointCircle',
      });
    }
    if (_tool == ViewerTool.measureArc3Point) {
      return l10n.text(switch (_measurementPoints.length) {
        0 => 'selectArcStartPoint',
        1 => 'selectArcMiddlePoint',
        2 => 'selectArcEndPoint',
        _ => 'selectAnotherThreePointArc',
      });
    }
    if (_tool == ViewerTool.measurePointLineOffset) {
      return l10n.text(switch (_measurementPoints.length) {
        0 => 'selectBaselineFirstPoint',
        1 => 'selectBaselineSecondPoint',
        2 => 'selectOffsetPoint',
        _ => 'selectAnotherPointLineOffset',
      });
    }
    if (_tool == ViewerTool.measurePolylineStation) {
      if (_stationBaseline == null) {
        return l10n.text('selectStationBaseline');
      }
      return l10n.text(
        _stationMeasurement == null
            ? 'selectStationPoint'
            : 'selectAnotherStationPoint',
      );
    }
    if (_tool == ViewerTool.locatePolylineStation) {
      if (_stationBaseline == null) {
        return l10n.text('selectStakeoutBaseline');
      }
      return l10n.text(
        _stationStakeoutMeasurement == null
            ? 'enterStationOffsetPrompt'
            : 'locateAnotherStationOffsetPrompt',
      );
    }
    if (_tool == ViewerTool.dividePolyline) {
      if (_stationBaseline == null) {
        return l10n.text('selectDivisionBaseline');
      }
      return l10n.text(
        _polylineDivisionMeasurement == null
            ? 'enterDivisionCountPrompt'
            : 'divideAnotherPrompt',
      );
    }
    if (_tool == ViewerTool.measureLineIntersection) {
      if (_intersectionFirstSegment == null ||
          _lineIntersectionMeasurement != null) {
        return l10n.text(
          _lineIntersectionMeasurement == null
              ? 'selectFirstIntersectionSegment'
              : 'selectAnotherIntersectionSegment',
        );
      }
      return l10n.text('selectSecondIntersectionSegment');
    }
    if (_tool == ViewerTool.measureParallelLineSpacing) {
      if (_intersectionFirstSegment == null ||
          _parallelLineSpacingMeasurement != null) {
        return l10n.text(
          _parallelLineSpacingMeasurement == null
              ? 'selectFirstParallelSegment'
              : 'selectAnotherParallelSegment',
        );
      }
      return l10n.text('selectSecondParallelSegment');
    }
    if (_tool == ViewerTool.measureSegmentClearance) {
      if (_intersectionFirstSegment == null ||
          _segmentClearanceMeasurement != null) {
        return l10n.text(
          _segmentClearanceMeasurement == null
              ? 'selectFirstClearanceSegment'
              : 'selectAnotherClearanceSegment',
        );
      }
      return l10n.text('selectSecondClearanceSegment');
    }
    if (_tool == ViewerTool.measureOrientedRectangle) {
      if (_measurementPoints.length == 3 && _measurement == null) {
        return l10n.text('invalidOrientedRectangle');
      }
      return l10n.text(switch (_measurementPoints.length) {
        0 => 'selectOrientedRectangleFirst',
        1 => 'selectOrientedRectangleSecond',
        2 => 'selectOrientedRectangleThird',
        _ => 'selectAnotherOrientedRectangle',
      });
    }
    if (_tool == ViewerTool.measureFaceAngle) {
      return l10n.text(switch (_measurement3DFaces.length) {
        0 => 'selectFirstFace',
        1 => 'selectSecondFace',
        _ => 'selectAnotherFacePair',
      });
    }
    if (_tool == ViewerTool.measureAngle) {
      final count = _document.sceneKind == 'three_d'
          ? _measurement3DPoints.length
          : _measurementPoints.length;
      return switch (count) {
        0 => l10n.text('selectAngleVertex'),
        1 => l10n.text('selectAngleFirstRay'),
        _ => l10n.text('selectAngleSecondRay'),
      };
    }
    if (_tool == ViewerTool.measureRadius) {
      return l10n.text('selectCircleArc');
    }
    if (_tool == ViewerTool.measureRadialClearance) {
      if (_radialClearanceFirst == null ||
          _radialClearanceMeasurement != null) {
        return l10n.text(
          _radialClearanceMeasurement == null
              ? 'selectFirstRadialEntity'
              : 'selectAnotherRadialPair',
        );
      }
      return l10n.text('selectSecondRadialEntity');
    }
    if (_tool == ViewerTool.measure) {
      final count = _document.sceneKind == 'three_d'
          ? _measurement3DPoints.length
          : _measurementPoints.length;
      return l10n.text(count == 0 ? 'selectStart' : 'selectEnd');
    }
    if (_tool == ViewerTool.annotate) return l10n.text('tapToAnnotate');
    if (_hit != null) return '${_hit!.entityKind} #${_hit!.entityId}';
    if (_document.sceneKind == 'three_d') {
      if (_meshHit != null) {
        return l10n.text('meshHit', {
          'mesh': _meshHit!.meshId,
          'face': _meshHit!.triangleIndex + 1,
        });
      }
      return l10n.text('threeDStatus', {'count': _document.meshes.length});
    }
    return l10n.text('entityCount', {'count': _document.entities.length});
  }

  void _handleViewerMenuAction(_ViewerMenuAction action) {
    switch (action) {
      case _ViewerMenuAction.annotations:
        _showAnnotations();
        return;
      case _ViewerMenuAction.exportAnnotations:
        unawaited(_exportAnnotations());
        return;
      case _ViewerMenuAction.exportImage:
        unawaited(_exportImage());
        return;
      case _ViewerMenuAction.exportPdf:
        unawaited(_exportPdf());
        return;
      case _ViewerMenuAction.layers:
        _showLayers();
        return;
      case _ViewerMenuAction.overview:
        _showDocumentOverview();
        return;
    }
  }

  String _measurementResultText() {
    if (_tool == ViewerTool.measureCoordinate) {
      if (_document.sceneKind == 'three_d') {
        final point = _measurement3DPoints.single;
        final origin = _localOrigin3D;
        if (origin == null) return _formatPoint3(point);
        final relative = point - origin;
        return context.l10n.text('localCoordinate3DResult', {
          'x': _formatLinear(relative.x),
          'y': _formatLinear(relative.y),
          'z': _formatLinear(relative.z),
        });
      }
      final point = _measurementPoints.single;
      return _localFrame2D == null
          ? context.l10n.text('coordinateResult', {
              'x': _formatLinear(point.dx),
              'y': _formatLinear(point.dy),
            })
          : _formatCoordinateReferencePoint2(point);
    }
    final rawValue = _measurement!;
    return switch (_tool) {
      ViewerTool.measureArea => _areaMeasurementResultText(rawValue),
      ViewerTool.measureRectangle => _rectangleMeasurementResultText(),
      ViewerTool.measureOrientedRectangle =>
        _orientedRectangleMeasurementResultText(),
      ViewerTool.measurePath => context.l10n.text('pathResult', {
        'value': _formatLinear(rawValue),
      }),
      ViewerTool.measureEntityLength => context.l10n.text(
        'entityLengthResult',
        {
          'count': _lengthEntityMeasurements.length,
          'value': _formatLinear(rawValue),
        },
      ),
      ViewerTool.measureEntityArea => context.l10n.text('entityAreaResult', {
        'count': _areaEntityMeasurements.length,
        'net': _formatArea(rawValue),
        'added': _formatArea(_areaTakeoffAddedTotal()),
        'deducted': _formatArea(_areaTakeoffDeductedTotal()),
        'perimeter': _formatLinear(_measurementPerimeter!),
      }),
      ViewerTool.collectCoordinates => _coordinateCollectionResultText(),
      ViewerTool.measureAngle when _document.sceneKind == 'two_d' =>
        _triangleMeasurementResultText(),
      ViewerTool.measureAngle => context.l10n.text('angleResult', {
        'value': _formatEngineeringValue(rawValue),
      }),
      ViewerTool.measureFaceAngle => _faceRelationResultText(rawValue),
      ViewerTool.measureRadius => _radialMeasurementResultText(rawValue),
      ViewerTool.measureRadialClearance => _radialClearanceResultText(),
      ViewerTool.measureCircle3Point => _threePointCircleResultText(),
      ViewerTool.measureArc3Point => _threePointArcResultText(),
      ViewerTool.measurePointLineOffset => _pointLineOffsetResultText(),
      ViewerTool.measurePolylineStation => _polylineStationResultText(),
      ViewerTool.locatePolylineStation => _stationStakeoutResultText(),
      ViewerTool.locatePolarPoint => _polarStakeoutResultText(),
      ViewerTool.locateTwoDistances => _twoDistanceResultText(),
      ViewerTool.dividePolyline => _polylineDivisionResultText(),
      ViewerTool.measureLineIntersection => _lineIntersectionResultText(),
      ViewerTool.measureParallelLineSpacing => _parallelLineSpacingResultText(),
      ViewerTool.measureSegmentClearance => _segmentClearanceResultText(),
      ViewerTool.measure
          when _document.sceneKind == 'two_d' &&
              _measurementPoints.length == 2 =>
        _distance2DResultText(rawValue),
      ViewerTool.measure
          when _document.sceneKind == 'three_d' &&
              _measurement3DPoints.length == 2 =>
        _distance3DResultText(_formatLinear(rawValue)),
      _ => _formatEngineeringValue(rawValue),
    };
  }

  String _faceRelationResultText(double angle) {
    final separation = _faceRelationMeasurement?.parallelSeparation;
    if (separation == null) {
      return context.l10n.text('faceAngleResult', {
        'value': _formatEngineeringValue(angle),
      });
    }
    return context.l10n.text('parallelFaceRelationResult', {
      'value': _formatEngineeringValue(angle),
      'spacing': _formatLinear(separation),
    });
  }

  String _areaMeasurementResultText(double area) {
    final perimeter =
        _measurementPerimeter ??
        widget.engine.measurePath(_measurementPoints, closed: true);
    final shape = cadPlanarShapeMetrics2D(area, perimeter);
    return context.l10n.text('areaResult', {
      'value': _formatArea(area),
      'perimeter': _formatLinear(perimeter),
      'centroid': _measurementCentroid == null
          ? '—'
          : _formatCoordinateReferencePoint2(_measurementCentroid!),
      'equivalentDiameter': shape == null
          ? '—'
          : _formatLinear(shape.equivalentCircleDiameter),
      'hydraulicRadius': shape == null
          ? '—'
          : _formatLinear(shape.hydraulicRadius),
      'hydraulicDiameter': shape == null
          ? '—'
          : _formatLinear(shape.hydraulicDiameter),
      'compactness': shape == null
          ? '—'
          : _formatEngineeringValue(shape.compactness),
    });
  }

  String _coordinateCollectionResultText() {
    final index = _coordinateCollectionPoints.length;
    final latest = _coordinateCollectionPoints.last;
    return context.l10n.text('coordinateCollectionResult', {
      'count': index,
      'maximum': _maximumCoordinateCollectionPoints,
      'index': index,
      'point': _formatCoordinateReferencePoint2(latest),
    });
  }

  String _polarStakeoutResultText() {
    final measurement = _polarStakeoutMeasurement!;
    return context.l10n.text('polarStakeoutResult', {
      'distance': _formatLinear(measurement.distance),
      'azimuth': _formatEngineeringValue(measurement.azimuthDegrees),
      'dx': _formatLinear(measurement.deltaX),
      'dy': _formatLinear(measurement.deltaY),
      'origin': _formatCoordinateReferencePoint2(_measurementPoints.first),
      'target': _formatCoordinateReferencePoint2(_measurementPoints.last),
    });
  }

  String _twoDistanceResultText() {
    final location = _twoDistanceLocation!;
    final values = {
      'baseline': _formatLinear(location.baselineLength),
      'first': _formatLinear(location.firstDistance),
      'second': _formatLinear(location.secondDistance),
      'referenceA': _formatCoordinateReferencePoint2(location.firstReference),
      'referenceB': _formatCoordinateReferencePoint2(location.secondReference),
      'left': _formatCoordinateReferencePoint2(location.solutions.first),
      'right': location.solutions.length == 2
          ? _formatCoordinateReferencePoint2(location.solutions.last)
          : '—',
    };
    return context.l10n.text(
      location.solutions.length == 1
          ? 'twoDistanceTangentResult'
          : 'twoDistanceDoubleResult',
      values,
    );
  }

  String _polylineDivisionResultText() {
    final measurement = _polylineDivisionMeasurement!;
    return context.l10n.text('polylineDivisionResult', {
      'divisions': measurement.divisions,
      'points': measurement.divisionPoints.length,
      'total': _formatLinear(measurement.totalLength),
      'interval': _formatLinear(measurement.intervalLength),
    });
  }

  String _rectangleMeasurementResultText() {
    final rectangle = cadRectangleMeasurement2D(
      _measurementPoints[0],
      _measurementPoints[1],
    )!;
    return context.l10n.text('rectangleResult', {
      'width': _formatLinear(rectangle.width),
      'height': _formatLinear(rectangle.height),
      'diagonal': _formatLinear(rectangle.diagonal),
      'center': _formatCoordinateReferencePoint2(rectangle.center),
      'area': _formatArea(rectangle.area),
      'perimeter': _formatLinear(rectangle.perimeter),
    });
  }

  String _orientedRectangleMeasurementResultText() {
    final rectangle = cadOrientedRectangleMeasurement2D(
      _measurementPoints[0],
      _measurementPoints[1],
      _measurementPoints[2],
    )!;
    return context.l10n.text('orientedRectangleResult', {
      'width': _formatLinear(rectangle.width),
      'height': _formatLinear(rectangle.height),
      'direction': _formatEngineeringValue(rectangle.directionDegrees),
      'diagonal': _formatLinear(rectangle.diagonal),
      'center': _formatCoordinateReferencePoint2(rectangle.center),
      'area': _formatArea(rectangle.area),
      'perimeter': _formatLinear(rectangle.perimeter),
    });
  }

  String _threePointCircleResultText() {
    final circle = cadThreePointCircleMeasurement2D(
      _measurementPoints[0],
      _measurementPoints[1],
      _measurementPoints[2],
    )!;
    return context.l10n.text('threePointCircleResult', {
      'center': _formatPoint2(circle.center),
      'radius': _formatLinear(circle.radius),
      'diameter': _formatLinear(circle.diameter),
      'circumference': _formatLinear(circle.circumference),
      'area': _formatArea(circle.area),
    });
  }

  String _threePointArcResultText() {
    final arc = cadThreePointArcMeasurement2D(
      _measurementPoints[0],
      _measurementPoints[1],
      _measurementPoints[2],
    )!;
    final result = context.l10n.text('threePointArcResult', {
      'center': _formatCoordinateReferencePoint2(arc.center),
      'radius': _formatLinear(arc.radius),
      'diameter': _formatLinear(arc.diameter),
      'angle': _formatEngineeringValue(arc.sweepDegrees),
      'length': _formatLinear(arc.arcLength),
      'chord': _formatLinear(arc.chordLength),
      'direction': context.l10n.text(
        arc.counterClockwise
            ? 'arcDirectionCounterClockwise'
            : 'arcDirectionClockwise',
      ),
    });
    final areas = context.l10n.text('arcAreaResult', {
      'sector': _formatArea(arc.sectorArea),
      'segment': _formatArea(arc.segmentArea),
    });
    final chord = _arcChordResultText(
      arc.sagitta,
      _measurementPoints.first,
      _measurementPoints.last,
    );
    final simpleCurve = _simpleCircularCurveResultText(
      center: arc.center,
      start: _measurementPoints.first,
      end: _measurementPoints.last,
      radius: arc.radius,
      sweepRadians: arc.sweepRadians,
      counterClockwise: arc.counterClockwise,
    );
    return [result, ?simpleCurve, areas, chord].join('\n');
  }

  String _arcChordResultText(
    double? sagitta,
    Offset? chordStart,
    Offset? chordEnd,
  ) {
    if (sagitta == null) {
      return context.l10n.text('arcChordUndefinedFullCircle');
    }
    final direction = chordStart == null || chordEnd == null
        ? null
        : _surveyDirectionInCoordinateReference(chordStart, chordEnd);
    return context.l10n.text('arcChordResult', {
      'sagitta': _formatLinear(sagitta),
      'azimuth': direction == null
          ? '—'
          : '${_formatEngineeringValue(direction.azimuthDegrees)}°',
      'bearing': _formatSurveyBearing(direction),
    });
  }

  String? _simpleCircularCurveResultText({
    required Offset center,
    required Offset start,
    required Offset end,
    required double radius,
    required double sweepRadians,
    required bool counterClockwise,
  }) {
    final curve = cadSimpleCircularCurve2D(
      center: center,
      start: start,
      end: end,
      radius: radius,
      sweepRadians: sweepRadians,
      counterClockwise: counterClockwise,
    );
    if (curve == null) return null;
    final incoming = _surveyDirectionInCoordinateReference(
      start,
      curve.tangentIntersection,
    );
    final outgoing = _surveyDirectionInCoordinateReference(
      curve.tangentIntersection,
      end,
    );
    if (incoming == null || outgoing == null) return null;
    return context.l10n.text('simpleCircularCurveResult', {
      'tangent': _formatLinear(curve.tangentLength),
      'external': _formatLinear(curve.externalDistance),
      'ordinate': _formatLinear(curve.middleOrdinate),
      'pi': _formatCoordinateReferencePoint2(curve.tangentIntersection),
      'incomingAzimuth': '${_formatEngineeringValue(incoming.azimuthDegrees)}°',
      'incomingBearing': _formatSurveyBearing(incoming),
      'outgoingAzimuth': '${_formatEngineeringValue(outgoing.azimuthDegrees)}°',
      'outgoingBearing': _formatSurveyBearing(outgoing),
    });
  }

  String _radialMeasurementResultText(double radius) {
    final selected = _selectedEntityId;
    final entity = selected == null ? null : _entityById(selected);
    final geometry = entity?['geometry'];
    final radial = geometry is Map<String, dynamic>
        ? cadRadialEntityMeasurement2D(geometry)
        : null;
    if (radial == null) {
      return context.l10n.text('radiusResult', {
        'radius': _formatLinear(radius),
        'diameter': _formatLinear(radius * 2),
      });
    }
    if (radial.kind == 'circle') {
      return context.l10n.text('threePointCircleResult', {
        'center': _formatCoordinateReferencePoint2(radial.center),
        'radius': _formatLinear(radial.radius),
        'diameter': _formatLinear(radial.diameter),
        'circumference': _formatLinear(radial.circumference!),
        'area': _formatArea(radial.area!),
      });
    }
    final result = context.l10n.text('arcRadiusResult', {
      'center': _formatCoordinateReferencePoint2(radial.center),
      'radius': _formatLinear(radial.radius),
      'diameter': _formatLinear(radial.diameter),
      'sweep': _formatEngineeringValue(radial.sweepDegrees!),
      'arcLength': _formatLinear(radial.arcLength!),
      'chord': _formatLinear(radial.chordLength!),
    });
    final sectorArea = radial.sectorArea;
    final segmentArea = radial.segmentArea;
    if (sectorArea == null || segmentArea == null) return result;
    final areas = context.l10n.text('arcAreaResult', {
      'sector': _formatArea(sectorArea),
      'segment': _formatArea(segmentArea),
    });
    final chord = _arcChordResultText(
      radial.sagitta,
      radial.chordStart,
      radial.chordEnd,
    );
    final start = radial.chordStart;
    final end = radial.chordEnd;
    final sweepDegrees = radial.sweepDegrees;
    final simpleCurve = start == null || end == null || sweepDegrees == null
        ? null
        : _simpleCircularCurveResultText(
            center: radial.center,
            start: start,
            end: end,
            radius: radial.radius,
            sweepRadians: sweepDegrees * math.pi / 180,
            counterClockwise: true,
          );
    return [result, ?simpleCurve, areas, chord].join('\n');
  }

  String _radialClearanceResultText() {
    final measurement = _radialClearanceMeasurement!;
    final relation = context.l10n.text(switch (measurement.relation) {
      CadRadialClearanceRelation2D.separate => 'radialClearanceSeparate',
      CadRadialClearanceRelation2D.tangent => 'radialClearanceTangent',
      CadRadialClearanceRelation2D.overlap => 'radialClearanceOverlap',
    });
    final direction = measurement.directionDegrees;
    return context.l10n.text('radialClearanceResult', {
      'centerDistance': _formatLinear(measurement.centerDistance),
      'clearance': _formatLinear(measurement.signedClearance),
      'relation': relation,
      'firstRadius': _formatLinear(measurement.first.radius),
      'secondRadius': _formatLinear(measurement.second.radius),
      'direction': direction == null
          ? '—'
          : '${_formatEngineeringValue(direction)}°',
    });
  }

  String _pointLineOffsetResultText() {
    final offset = cadPointLineMeasurement2D(
      _measurementPoints[0],
      _measurementPoints[1],
      _measurementPoints[2],
    )!;
    return context.l10n.text('pointLineOffsetResult', {
      'distance': _formatLinear(offset.perpendicularDistance),
      'offset': _formatLinear(offset.signedOffset),
      'station': _formatLinear(offset.station),
      'direction': _formatEngineeringValue(offset.directionDegrees),
      'foot': _formatPoint2(offset.foot),
    });
  }

  String _polylineStationResultText() {
    final measurement = _stationMeasurement!;
    return context.l10n.text('polylineStationResult', {
      'station': _formatLinear(measurement.station),
      'total': _formatLinear(measurement.totalLength),
      'remaining': _formatLinear(measurement.remainingLength),
      'offset': _formatLinear(measurement.signedOffset),
      'distance': _formatLinear(measurement.perpendicularDistance),
      'element': context.l10n.text(
        measurement.elementKind == CadStationElementKind2D.arc
            ? 'stationElementArc'
            : 'stationElementSegment',
      ),
      'segment': measurement.segmentIndex + 1,
      'direction': _formatEngineeringValue(measurement.directionDegrees),
      'foot': _formatCoordinateReferencePoint2(measurement.foot),
      'point': _formatCoordinateReferencePoint2(measurement.point),
    });
  }

  String _stationStakeoutResultText() {
    final measurement = _stationStakeoutMeasurement!;
    return context.l10n.text('stationStakeoutResult', {
      'station': _formatLinear(measurement.station),
      'total': _formatLinear(measurement.totalLength),
      'remaining': _formatLinear(measurement.remainingLength),
      'offset': _formatLinear(measurement.signedOffset),
      'element': context.l10n.text(
        measurement.elementKind == CadStationElementKind2D.arc
            ? 'stationElementArc'
            : 'stationElementSegment',
      ),
      'segment': measurement.segmentIndex + 1,
      'direction': _formatEngineeringValue(measurement.directionDegrees),
      'base': _formatCoordinateReferencePoint2(measurement.basePoint),
      'target': _formatCoordinateReferencePoint2(measurement.targetPoint),
    });
  }

  String _lineIntersectionResultText() {
    final measurement = _lineIntersectionMeasurement!;
    final firstExtended = measurement.firstExtensionLength > 0;
    final secondExtended = measurement.secondExtensionLength > 0;
    final location = context.l10n.text(switch ((
      firstExtended,
      secondExtended,
    )) {
      (false, false) => 'intersectionOnBothSegments',
      (true, false) => 'intersectionExtendsFirst',
      (false, true) => 'intersectionExtendsSecond',
      (true, true) => 'intersectionExtendsBoth',
    });
    return context.l10n.text('lineIntersectionResult', {
      'point': _formatCoordinateReferencePoint2(measurement.intersection),
      'angle': _formatEngineeringValue(measurement.includedAngleDegrees),
      'firstDirection': _formatEngineeringValue(
        measurement.first.directionDegrees,
      ),
      'secondDirection': _formatEngineeringValue(
        measurement.second.directionDegrees,
      ),
      'firstExtension': _formatLinear(measurement.firstExtensionLength),
      'secondExtension': _formatLinear(measurement.secondExtensionLength),
      'firstSegment': measurement.first.segmentIndex + 1,
      'secondSegment': measurement.second.segmentIndex + 1,
      'location': location,
    });
  }

  String _parallelLineSpacingResultText() {
    final measurement = _parallelLineSpacingMeasurement!;
    return context.l10n.text('parallelSpacingResult', {
      'spacing': _formatLinear(measurement.spacing),
      'direction': _formatEngineeringValue(measurement.directionDegrees),
      'firstSegment': measurement.first.segmentIndex + 1,
      'secondSegment': measurement.second.segmentIndex + 1,
    });
  }

  String _segmentClearanceResultText() {
    final measurement = _segmentClearanceMeasurement!;
    final direction = _surveyDirectionInCoordinateReference(
      measurement.firstClosestPoint,
      measurement.secondClosestPoint,
    );
    return context.l10n.text('segmentClearanceResult', {
      'clearance': _formatLinear(measurement.clearance),
      'firstPoint': _formatCoordinateReferencePoint2(
        measurement.firstClosestPoint,
      ),
      'secondPoint': _formatCoordinateReferencePoint2(
        measurement.secondClosestPoint,
      ),
      'azimuth': direction == null
          ? '—'
          : '${_formatEngineeringValue(direction.azimuthDegrees)}°',
      'bearing': _formatSurveyBearing(direction),
      'firstSegment': measurement.first.segmentIndex + 1,
      'secondSegment': measurement.second.segmentIndex + 1,
      'state': context.l10n.text(
        measurement.intersects
            ? 'segmentClearanceIntersecting'
            : 'segmentClearanceSeparated',
      ),
    });
  }

  String _triangleMeasurementResultText() {
    final triangle = cadTriangleMeasurement2D(
      _measurementPoints[0],
      _measurementPoints[1],
      _measurementPoints[2],
    )!;
    return context.l10n.text('triangleResult', {
      'angleA': '${_formatEngineeringValue(triangle.angleDegrees)}°',
      'angleB': triangle.firstRayPointAngleDegrees == null
          ? '—'
          : '${_formatEngineeringValue(triangle.firstRayPointAngleDegrees!)}°',
      'angleC': triangle.secondRayPointAngleDegrees == null
          ? '—'
          : '${_formatEngineeringValue(triangle.secondRayPointAngleDegrees!)}°',
      'first': _formatLinear(triangle.firstRayLength),
      'second': _formatLinear(triangle.secondRayLength),
      'opposite': _formatLinear(triangle.oppositeLength),
      'area': _formatArea(triangle.area),
      'perimeter': _formatLinear(triangle.perimeter),
      'height': triangle.altitudeFromVertex == null
          ? '—'
          : _formatLinear(triangle.altitudeFromVertex!),
      'inradius': triangle.inradius == null
          ? '—'
          : _formatLinear(triangle.inradius!),
      'circumradius': triangle.circumradius == null
          ? '—'
          : _formatLinear(triangle.circumradius!),
    });
  }

  String _formatEngineeringValue(double value) =>
      formatEngineeringValue(value, widget.decimalPlaces);

  String get _unitSymbol =>
      (_displayUnit ?? _calibrationUnit ?? _sourceUnit)?.symbol ?? 'DU';

  String _formatLinear(double value) {
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final calibration = _calibrationMetersPerDrawingUnit;
    final converted = calibration != null && display != null
        ? convertCalibratedCadLength(value, calibration, display)
        : source == null || display == null
        ? value
        : convertCadLength(value, source, display);
    return '${_formatEngineeringValue(converted)} ${display?.symbol ?? 'DU'}';
  }

  String _formatArea(double value) {
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final calibration = _calibrationMetersPerDrawingUnit;
    final converted = calibration != null && display != null
        ? convertCalibratedCadArea(value, calibration, display)
        : source == null || display == null
        ? value
        : convertCadArea(value, source, display);
    return '${_formatEngineeringValue(converted)} ${display?.symbol ?? 'DU'}²';
  }

  String _formatVolume(double value) => _formatCubic(value);

  String _formatCubic(double value) {
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final converted = cadDrawingVolumeToDisplayUnits(
      value,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    if (converted == null) return '—';
    return '${_formatEngineeringValue(converted)} ${display?.symbol ?? 'DU'}³';
  }

  String _formatFourthPower(double value) {
    final source = _calibrationUnit ?? _sourceUnit;
    final display = _displayUnit ?? source;
    final converted = cadDrawingFourthPowerToDisplayUnits(
      value,
      source: source,
      display: display,
      metersPerDrawingUnit: _calibrationMetersPerDrawingUnit,
    );
    if (converted == null) return '—';
    return '${_formatEngineeringValue(converted)} '
        '${display?.symbol ?? 'DU'}⁴';
  }

  String _distance2DResultText(double distance) {
    final first = _measurementPoints[0];
    final second = _measurementPoints[1];
    final delta = measurementDelta2D(first, second);
    final grade = cadGrade2D(first, second);
    final surveyDirection = cadSurveyDirection2D(first, second);
    return context.l10n.text('distanceResult', {
      'value': _formatLinear(distance),
      'dx': _formatLinear(delta.dx),
      'dy': _formatLinear(delta.dy),
      'angle': switch (directionDegrees2D(first, second)) {
        final angle? => '${_formatEngineeringValue(angle)}°',
        null => '—',
      },
      'grade': _formatGradePercent(grade.percent),
      'ratio': _formatGradeRatio(grade.ratio),
      'azimuth': surveyDirection == null
          ? '—'
          : '${_formatEngineeringValue(surveyDirection.azimuthDegrees)}°',
      'bearing': _formatSurveyBearing(surveyDirection),
      'midpoint': _formatCoordinateReferencePoint2(
        cadMidpoint2D(first, second),
      ),
    });
  }

  String _formatGradePercent(double? percent) {
    if (percent == null || percent.isNaN) return '—';
    if (percent == double.infinity) return '∞%';
    if (percent == double.negativeInfinity) return '−∞%';
    return '${_formatEngineeringValue(percent)}%';
  }

  String _formatGradeRatio(double? ratio) {
    if (ratio == null || ratio.isNaN) return '—';
    if (ratio == double.infinity) return '1:∞';
    return '1:${_formatEngineeringValue(ratio)}';
  }

  String _formatSurveyBearing(CadSurveyDirection2D? direction) {
    if (direction == null) return '—';
    final cardinal = direction.cardinal;
    if (cardinal != null) return _cardinalLetter(cardinal);
    final from = direction.bearingFrom;
    final angle = direction.bearingDegrees;
    final to = direction.bearingTo;
    if (from == null || angle == null || to == null) return '—';
    return '${_cardinalLetter(from)} '
        '${_formatEngineeringValue(angle)}° '
        '${_cardinalLetter(to)}';
  }

  String _cardinalLetter(CadCardinalDirection direction) => switch (direction) {
    CadCardinalDirection.north => 'N',
    CadCardinalDirection.east => 'E',
    CadCardinalDirection.south => 'S',
    CadCardinalDirection.west => 'W',
  };

  String _distance3DResultText(String distance) {
    final first = _measurement3DPoints[0];
    final second = _measurement3DPoints[1];
    final grade = cadGrade3D(first, second);
    final horizontalDirection = grade.horizontalDirection;
    return context.l10n.text('distance3DResult', {
      'value': distance,
      'horizontal': _formatLinear(grade.horizontalDistance),
      'dx': _formatLinear(second.x - first.x),
      'dy': _formatLinear(second.y - first.y),
      'dz': _formatLinear(grade.deltaZ),
      'grade': _formatGradePercent(grade.percent),
      'ratio': _formatGradeRatio(grade.ratio),
      'slopeAngle': grade.slopeAngleDegrees == null
          ? '—'
          : '${_formatEngineeringValue(grade.slopeAngleDegrees!)}°',
      'azimuth': horizontalDirection == null
          ? '—'
          : '${_formatEngineeringValue(horizontalDirection.azimuthDegrees)}°',
      'bearing': _formatSurveyBearing(horizontalDirection),
      'midpoint': _formatCoordinateReferencePoint3(
        cadMidpoint3D(first, second),
      ),
    });
  }

  String _emptySceneDiagnostic() {
    for (final diagnostic in _document.diagnostics.reversed) {
      if (diagnostic['severity'] == 'error') {
        return diagnostic['message'] as String;
      }
    }
    return context.l10n.text('emptySceneFallback');
  }

  String _sceneLabel(String value) => switch (value) {
    'two_d' => context.l10n.text('scene2d'),
    'three_d' => context.l10n.text('scene3d'),
    _ => context.l10n.text('pagedDocument'),
  };
}

class _StandardViewTile extends StatelessWidget {
  const _StandardViewTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? const Color(0xff53d4ff).withValues(alpha: 0.12)
        : const Color(0xff131e29),
    shape: RoundedRectangleBorder(
      side: BorderSide(
        color: selected ? const Color(0xff53d4ff) : Colors.white12,
      ),
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xff53d4ff)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (selected) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.check_circle,
                size: 16,
                color: Color(0xff53d4ff),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xff53d4ff).withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? const Color(0xff53d4ff) : Colors.white54,
            ),
            const SizedBox(height: 1),
            SizedBox(
              height: 13,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1,
                    color: selected ? const Color(0xff53d4ff) : Colors.white54,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.text,
    required this.icon,
    this.accent = false,
    this.expand = false,
    this.copyTooltip,
    this.hint,
    this.onCopy,
  });

  final String text;
  final String? hint;
  final IconData icon;
  final bool accent;
  final bool expand;
  final String? copyTooltip;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: expand ? double.infinity : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xdd111923),
          border: Border.all(
            color: accent ? const Color(0xff53d4ff) : Colors.white12,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: const Color(0xff53d4ff)),
              const SizedBox(width: 7),
              Flexible(
                fit: expand ? FlexFit.tight : FlexFit.loose,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text,
                      maxLines: 10,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (hint != null)
                      Text(
                        hint!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                  ],
                ),
              ),
              if (onCopy != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: copyTooltip,
                  onPressed: onCopy,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  icon: const Icon(
                    Icons.content_copy,
                    size: 16,
                    color: Color(0xff53d4ff),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OverlayActionButton extends StatelessWidget {
  const _OverlayActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color = const Color(0xff53d4ff),
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xdd111923),
    shape: const CircleBorder(side: BorderSide(color: Colors.white12)),
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: color),
    ),
  );
}

class _PolylineDivisionDialog extends StatefulWidget {
  const _PolylineDivisionDialog();

  @override
  State<_PolylineDivisionDialog> createState() =>
      _PolylineDivisionDialogState();
}

class _PolylineDivisionDialogState extends State<_PolylineDivisionDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final divisions = int.tryParse(_controller.text.trim());
    if (divisions == null ||
        divisions < 2 ||
        divisions > cadMaximumPolylineDivisions) {
      setState(
        () => _errorText = context.l10n.text('invalidDivisionCount', {
          'maximum': cadMaximumPolylineDivisions,
        }),
      );
      return;
    }
    Navigator.pop(context, divisions);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.text('polylineDivisionTitle')),
      content: TextField(
        key: const ValueKey('polyline_division_count'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: l10n.text('divisionCountInput'),
          helperText: l10n.text('divisionCountHint', {
            'maximum': cadMaximumPolylineDivisions,
          }),
          errorText: _errorText,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('apply_polyline_division'),
          onPressed: _save,
          child: Text(l10n.text('done')),
        ),
      ],
    );
  }
}

class _PolarStakeoutDialog extends StatefulWidget {
  const _PolarStakeoutDialog({required this.unitSymbol});

  final String unitSymbol;

  @override
  State<_PolarStakeoutDialog> createState() => _PolarStakeoutDialogState();
}

class _PolarStakeoutDialogState extends State<_PolarStakeoutDialog> {
  final TextEditingController _distanceController = TextEditingController();
  final TextEditingController _azimuthController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _distanceController.dispose();
    _azimuthController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final distance = _parse(_distanceController.text);
    final azimuth = _parse(_azimuthController.text);
    if (distance == null ||
        distance <= 0 ||
        azimuth == null ||
        azimuth < 0 ||
        azimuth >= 360) {
      setState(() => _errorText = context.l10n.text('invalidPolarStakeout'));
      return;
    }
    Navigator.pop(context, _CadPolarInput(distance, azimuth));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inputFormatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      title: Text(l10n.text('polarStakeoutTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.text('polarAzimuthHint')),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('polar_stakeout_distance'),
              controller: _distanceController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.next,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText:
                    '${l10n.text('distanceInput')} (${widget.unitSymbol})',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('polar_stakeout_azimuth'),
              controller: _azimuthController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText: l10n.text('azimuthInput'),
                suffixText: '°',
                errorText: _errorText,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('apply_polar_stakeout'),
          onPressed: _save,
          child: Text(l10n.text('locate')),
        ),
      ],
    );
  }
}

class _TwoDistanceLocationDialog extends StatefulWidget {
  const _TwoDistanceLocationDialog({required this.unitSymbol});

  final String unitSymbol;

  @override
  State<_TwoDistanceLocationDialog> createState() =>
      _TwoDistanceLocationDialogState();
}

class _TwoDistanceLocationDialogState
    extends State<_TwoDistanceLocationDialog> {
  final TextEditingController _firstController = TextEditingController();
  final TextEditingController _secondController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _firstController.dispose();
    _secondController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final first = _parse(_firstController.text);
    final second = _parse(_secondController.text);
    if (first == null || first <= 0 || second == null || second <= 0) {
      setState(() => _errorText = context.l10n.text('invalidTwoDistances'));
      return;
    }
    Navigator.pop(context, _CadTwoDistanceInput(first, second));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inputFormatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      title: Text(l10n.text('twoDistanceTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('two_distance_first'),
              controller: _firstController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.next,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText:
                    '${l10n.text('firstReferenceDistance')} (${widget.unitSymbol})',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('two_distance_second'),
              controller: _secondController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText:
                    '${l10n.text('secondReferenceDistance')} (${widget.unitSymbol})',
                errorText: _errorText,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('apply_two_distance_location'),
          onPressed: _save,
          child: Text(l10n.text('locate')),
        ),
      ],
    );
  }
}

class _StationOffsetLocationDialog extends StatefulWidget {
  const _StationOffsetLocationDialog({
    required this.unitSymbol,
    required this.totalLabel,
    required this.maximumStation,
  });

  final String unitSymbol;
  final String totalLabel;
  final double maximumStation;

  @override
  State<_StationOffsetLocationDialog> createState() =>
      _StationOffsetLocationDialogState();
}

class _StationOffsetLocationDialogState
    extends State<_StationOffsetLocationDialog> {
  final TextEditingController _stationController = TextEditingController();
  final TextEditingController _offsetController = TextEditingController(
    text: '0',
  );
  String? _errorText;

  @override
  void dispose() {
    _stationController.dispose();
    _offsetController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final station = _parse(_stationController.text);
    final offset = _parse(_offsetController.text);
    if (station == null || station < 0 || offset == null) {
      setState(() => _errorText = context.l10n.text('invalidStationOffset'));
      return;
    }
    final tolerance = math.max(1.0, widget.maximumStation) * 1e-12;
    if (station > widget.maximumStation + tolerance) {
      setState(
        () => _errorText = context.l10n.text('stationOffsetOutOfRange', {
          'total': widget.totalLabel,
        }),
      );
      return;
    }
    Navigator.pop(context, _CadStationOffsetInput(station, offset));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inputFormatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      title: Text(l10n.text('stationOffsetLocationTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.text('stationOffsetBaselineTotal', {
                'total': widget.totalLabel,
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('station_offset_station'),
              controller: _stationController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.next,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText:
                    '${l10n.text('stationInput')} (${widget.unitSymbol})',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('station_offset_offset'),
              controller: _offsetController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              textInputAction: TextInputAction.done,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText:
                    '${l10n.text('signedOffsetInput')} (${widget.unitSymbol})',
                helperText: l10n.text('leftPositiveOffsetHint'),
                errorText: _errorText,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('apply_station_offset_location'),
          onPressed: _save,
          child: Text(l10n.text('locate')),
        ),
      ],
    );
  }
}

class _DensityDialog extends StatefulWidget {
  const _DensityDialog();

  @override
  State<_DensityDialog> createState() => _DensityDialogState();
}

class _DensityDialogState extends State<_DensityDialog> {
  final TextEditingController _controller = TextEditingController();
  CadDensityUnit _unit = CadDensityUnit.kilogramsPerCubicMeter;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) {
      setState(() => _errorText = context.l10n.text('invalidDensity'));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context, _CadDensityInput(value, _unit));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.text('massFromDensity')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.text('densityHint')),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('density_value'),
                  controller: _controller,
                  // Let the user select a unit before opening the keyboard.
                  // This keeps every control reachable on compact phones.
                  autofocus: false,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
                  ],
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.text('densityInput'),
                    errorText: _errorText,
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 92,
                child: DropdownButtonFormField<CadDensityUnit>(
                  key: const ValueKey('density_unit'),
                  initialValue: _unit,
                  isExpanded: true,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.text('densityUnit'),
                  ),
                  items: [
                    for (final unit in CadDensityUnit.values)
                      DropdownMenuItem(
                        value: unit,
                        child: Text(
                          _densityUnitSymbol(unit),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _unit = value);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('calculate_mass'),
          onPressed: _save,
          child: Text(l10n.text('calculateMass')),
        ),
      ],
    );
  }
}

class _AverageEndAreaVolumeDialog extends StatefulWidget {
  const _AverageEndAreaVolumeDialog({required this.unitSymbol});

  final String unitSymbol;

  @override
  State<_AverageEndAreaVolumeDialog> createState() =>
      _AverageEndAreaVolumeDialogState();
}

class _AverageEndAreaVolumeDialogState
    extends State<_AverageEndAreaVolumeDialog> {
  final TextEditingController _areaController = TextEditingController();
  final TextEditingController _intervalController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _areaController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  void _save() {
    final secondArea = double.tryParse(
      _areaController.text.trim().replaceAll(',', '.'),
    );
    final interval = double.tryParse(
      _intervalController.text.trim().replaceAll(',', '.'),
    );
    if (secondArea == null ||
        interval == null ||
        !secondArea.isFinite ||
        !interval.isFinite ||
        secondArea < 0 ||
        interval <= 0) {
      setState(
        () => _errorText = context.l10n.text('invalidAverageEndAreaInput'),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context, _CadAverageEndAreaInput(secondArea, interval));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final formatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.text('averageEndAreaVolume')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.text('averageEndAreaHint')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('average_end_second_area'),
            controller: _areaController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('secondEndAreaInput', {
                'unit': widget.unitSymbol,
              }),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('average_end_interval'),
            controller: _intervalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('sectionIntervalInput', {
                'unit': widget.unitSymbol,
              }),
              errorText: _errorText,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('calculate_average_end_area'),
          onPressed: _save,
          child: Text(l10n.text('calculateVolume')),
        ),
      ],
    );
  }
}

class _PrismoidalVolumeDialog extends StatefulWidget {
  const _PrismoidalVolumeDialog({required this.unitSymbol});

  final String unitSymbol;

  @override
  State<_PrismoidalVolumeDialog> createState() =>
      _PrismoidalVolumeDialogState();
}

class _PrismoidalVolumeDialogState extends State<_PrismoidalVolumeDialog> {
  final TextEditingController _midpointAreaController = TextEditingController();
  final TextEditingController _secondAreaController = TextEditingController();
  final TextEditingController _intervalController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _midpointAreaController.dispose();
    _secondAreaController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final midpointArea = _parse(_midpointAreaController.text);
    final secondArea = _parse(_secondAreaController.text);
    final interval = _parse(_intervalController.text);
    if (midpointArea == null ||
        secondArea == null ||
        interval == null ||
        midpointArea < 0 ||
        secondArea < 0 ||
        interval <= 0) {
      setState(() => _errorText = context.l10n.text('invalidPrismoidalInput'));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(
      context,
      _CadPrismoidalInput(midpointArea, secondArea, interval),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final formatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.text('prismoidalVolume')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.text('prismoidalVolumeHint')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('prismoidal_midpoint_area'),
            controller: _midpointAreaController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('midpointAreaInput', {
                'unit': widget.unitSymbol,
              }),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('prismoidal_second_area'),
            controller: _secondAreaController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('secondEndAreaInput', {
                'unit': widget.unitSymbol,
              }),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('prismoidal_interval'),
            controller: _intervalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('sectionIntervalInput', {
                'unit': widget.unitSymbol,
              }),
              errorText: _errorText,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('calculate_prismoidal_volume'),
          onPressed: _save,
          child: Text(l10n.text('calculateVolume')),
        ),
      ],
    );
  }
}

class _CoverageQuantityDialog extends StatefulWidget {
  const _CoverageQuantityDialog({required this.unitSymbol});

  final String unitSymbol;

  @override
  State<_CoverageQuantityDialog> createState() =>
      _CoverageQuantityDialogState();
}

class _CoverageQuantityDialogState extends State<_CoverageQuantityDialog> {
  final TextEditingController _coverageController = TextEditingController();
  final TextEditingController _wasteController = TextEditingController(
    text: '0',
  );
  String? _errorText;

  @override
  void dispose() {
    _coverageController.dispose();
    _wasteController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final coverage = _parse(_coverageController.text);
    final waste = _parse(_wasteController.text);
    if (coverage == null ||
        waste == null ||
        coverage <= 0 ||
        waste < 0 ||
        waste > 100) {
      setState(() => _errorText = context.l10n.text('invalidCoverageQuantity'));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context, _CadCoverageInput(coverage, waste));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final formatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.text('coverageQuantity')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.text('coverageQuantityHint')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('coverage_area_per_unit'),
            controller: _coverageController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('coverageAreaInput', {
                'unit': widget.unitSymbol,
              }),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('coverage_waste_percent'),
            controller: _wasteController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('coverageWasteInput'),
              suffixText: '%',
              helperText: l10n.text('coverageWasteHint'),
              errorText: _errorText,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('calculate_coverage_quantity'),
          onPressed: _save,
          child: Text(l10n.text('calculateCoverageQuantity')),
        ),
      ],
    );
  }
}

class _LinearQuantityDialog extends StatefulWidget {
  const _LinearQuantityDialog({required this.unitSymbol});

  final String unitSymbol;

  @override
  State<_LinearQuantityDialog> createState() => _LinearQuantityDialogState();
}

class _LinearQuantityDialogState extends State<_LinearQuantityDialog> {
  final TextEditingController _lengthController = TextEditingController();
  final TextEditingController _wasteController = TextEditingController(
    text: '0',
  );
  String? _errorText;

  @override
  void dispose() {
    _lengthController.dispose();
    _wasteController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final length = _parse(_lengthController.text);
    final waste = _parse(_wasteController.text);
    if (length == null ||
        waste == null ||
        length <= 0 ||
        waste < 0 ||
        waste > 100) {
      setState(() => _errorText = context.l10n.text('invalidLinearQuantity'));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context, _CadLinearQuantityInput(length, waste));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final formatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.text('linearQuantity')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.text('linearQuantityHint')),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('linear_length_per_unit'),
            controller: _lengthController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('linearLengthInput', {
                'unit': widget.unitSymbol,
              }),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('linear_waste_percent'),
            controller: _wasteController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: formatters,
            decoration: InputDecoration(
              labelText: l10n.text('coverageWasteInput'),
              suffixText: '%',
              helperText: l10n.text('coverageWasteHint'),
              errorText: _errorText,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('calculate_linear_quantity'),
          onPressed: _save,
          child: Text(l10n.text('calculateCoverageQuantity')),
        ),
      ],
    );
  }
}

class _QuantityLengthDialog extends StatefulWidget {
  const _QuantityLengthDialog({
    required this.unitSymbol,
    required this.purpose,
  });

  final String unitSymbol;
  final _QuantityLengthPurpose purpose;

  @override
  State<_QuantityLengthDialog> createState() => _QuantityLengthDialogState();
}

class _QuantityLengthDialogState extends State<_QuantityLengthDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _errorText;

  String get _titleKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'volumeFromArea',
    _QuantityLengthPurpose.perimeterHeight => 'lateralAreaFromPerimeter',
    _QuantityLengthPurpose.planRise => 'planSlope',
  };

  String get _hintKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'volumeDepthHint',
    _QuantityLengthPurpose.perimeterHeight => 'lateralHeightHint',
    _QuantityLengthPurpose.planRise => 'planSlopeHint',
  };

  String get _inputKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'volumeDepthInput',
    _QuantityLengthPurpose.perimeterHeight => 'lateralHeightInput',
    _QuantityLengthPurpose.planRise => 'planSlopeRiseInput',
  };

  String get _invalidKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'invalidVolumeDepth',
    _QuantityLengthPurpose.perimeterHeight => 'invalidLateralHeight',
    _QuantityLengthPurpose.planRise => 'invalidPlanSlopeInput',
  };

  String get _fieldKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'volume_depth',
    _QuantityLengthPurpose.perimeterHeight => 'perimeter_height',
    _QuantityLengthPurpose.planRise => 'plan_slope_rise',
  };

  String get _buttonKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'calculate_volume',
    _QuantityLengthPurpose.perimeterHeight => 'calculate_lateral_area',
    _QuantityLengthPurpose.planRise => 'calculate_plan_slope',
  };

  String get _buttonLabelKey => switch (widget.purpose) {
    _QuantityLengthPurpose.volumeDepth => 'calculateVolume',
    _QuantityLengthPurpose.perimeterHeight => 'calculateLateralArea',
    _QuantityLengthPurpose.planRise => 'calculatePlanSlope',
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    final acceptsZero = widget.purpose == _QuantityLengthPurpose.planRise;
    if (value == null ||
        !value.isFinite ||
        (acceptsZero ? value < 0 : value <= 0)) {
      setState(() => _errorText = context.l10n.text(_invalidKey));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.text(_titleKey)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.text(_hintKey)),
          const SizedBox(height: 12),
          TextField(
            key: ValueKey(_fieldKey),
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
            ],
            decoration: InputDecoration(
              labelText: l10n.text(_inputKey, {'unit': widget.unitSymbol}),
              errorText: _errorText,
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: ValueKey(_buttonKey),
          onPressed: _save,
          child: Text(l10n.text(_buttonLabelKey)),
        ),
      ],
    );
  }
}

class _CoordinateLocationDialog extends StatefulWidget {
  const _CoordinateLocationDialog({
    required this.unitSymbol,
    this.knownEndpoint = false,
  });

  final String unitSymbol;
  final bool knownEndpoint;

  @override
  State<_CoordinateLocationDialog> createState() =>
      _CoordinateLocationDialogState();
}

class _CoordinateLocationDialogState extends State<_CoordinateLocationDialog> {
  final TextEditingController _xController = TextEditingController();
  final TextEditingController _yController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _xController.dispose();
    _yController.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
    return parsed?.isFinite == true ? parsed : null;
  }

  void _save() {
    final x = _parse(_xController.text);
    final y = _parse(_yController.text);
    if (x == null || y == null) {
      setState(() => _errorText = context.l10n.text('invalidCoordinateValue'));
      return;
    }
    Navigator.pop(context, _CadCoordinateInput(x, y));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final inputFormatters = [
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
    ];
    return AlertDialog(
      title: Text(
        l10n.text(
          widget.knownEndpoint ? 'knownEndpointClosure' : 'locateCoordinate',
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: ValueKey(
                widget.knownEndpoint
                    ? 'known_endpoint_x'
                    : 'coordinate_location_x',
              ),
              controller: _xController,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              textInputAction: TextInputAction.next,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText: 'X (${widget.unitSymbol})',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: ValueKey(
                widget.knownEndpoint
                    ? 'known_endpoint_y'
                    : 'coordinate_location_y',
              ),
              controller: _yController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              textInputAction: TextInputAction.done,
              inputFormatters: inputFormatters,
              decoration: InputDecoration(
                labelText: 'Y (${widget.unitSymbol})',
                errorText: _errorText,
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: ValueKey(
            widget.knownEndpoint
                ? 'apply_known_endpoint'
                : 'apply_coordinate_location',
          ),
          onPressed: _save,
          child: Text(
            l10n.text(widget.knownEndpoint ? 'calculateClosure' : 'locate'),
          ),
        ),
      ],
    );
  }
}

class _ScaleCalibrationDialog extends StatefulWidget {
  const _ScaleCalibrationDialog({
    required this.drawingDistance,
    required this.initialUnit,
    required this.units,
  });

  final double drawingDistance;
  final CadEngineeringUnit initialUnit;
  final List<CadEngineeringUnit> units;

  @override
  State<_ScaleCalibrationDialog> createState() =>
      _ScaleCalibrationDialogState();
}

class _ScaleCalibrationDialogState extends State<_ScaleCalibrationDialog> {
  final TextEditingController _controller = TextEditingController();
  late CadEngineeringUnit _selectedUnit = widget.initialUnit;
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0) {
      setState(() => _errorText = context.l10n.text('invalidKnownLength'));
      return;
    }
    Navigator.pop(context, _CadCalibrationInput(value, _selectedUnit));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.text('knownLengthTitle')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.text('selectedDrawingDistance', {
                'value': formatEngineeringValue(widget.drawingDistance, 6),
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('known_calibration_length'),
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,eE+\-]')),
              ],
              decoration: InputDecoration(
                labelText: l10n.text('knownLength'),
                errorText: _errorText,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CadEngineeringUnit>(
              key: const ValueKey('calibration_unit'),
              initialValue: _selectedUnit,
              decoration: InputDecoration(
                labelText: l10n.text('measurementUnit'),
              ),
              items: [
                for (final unit in widget.units)
                  DropdownMenuItem(value: unit, child: Text(unit.symbol)),
              ],
              onChanged: (value) {
                if (value != null) _selectedUnit = value;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('apply_scale_calibration'),
          onPressed: _save,
          child: Text(l10n.text('save')),
        ),
      ],
    );
  }
}

class _AnnotationEditorDialog extends StatefulWidget {
  const _AnnotationEditorDialog();

  @override
  State<_AnnotationEditorDialog> createState() =>
      _AnnotationEditorDialogState();
}

class _AnnotationEditorDialogState extends State<_AnnotationEditorDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.text('addAnnotation')),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        decoration: InputDecoration(hintText: l10n.text('annotationHint')),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l10n.text('save')),
        ),
      ],
    );
  }
}

/// Multi-select list of what to export as images: the current view and each
/// detected drawing sheet. Returns the chosen indexes (-1 is the current view).
class _SheetChoiceDialog extends StatefulWidget {
  const _SheetChoiceDialog({required this.frames});

  final List<CadDrawingFrame> frames;

  @override
  State<_SheetChoiceDialog> createState() => _SheetChoiceDialogState();
}

class _SheetChoiceDialogState extends State<_SheetChoiceDialog> {
  late final Set<int> _selected = {
    for (var i = 0; i < widget.frames.length; i++) i,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget option(int index, String title) => CheckboxListTile(
      key: ValueKey('sheet_choice_$index'),
      value: _selected.contains(index),
      title: Text(title),
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: (checked) => setState(() {
        if (checked == true) {
          _selected.add(index);
        } else {
          _selected.remove(index);
        }
      }),
    );
    return AlertDialog(
      title: Text(l10n.text('exportChooseSheets')),
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      content: SizedBox(
        width: 360,
        child: ListView(
          shrinkWrap: true,
          children: [
            option(-1, l10n.text('exportCurrentView')),
            for (var i = 0; i < widget.frames.length; i++)
              option(
                i,
                [
                  l10n.text('exportSheet', {'index': i + 1}),
                  ?widget.frames[i].paper,
                ].join(' · '),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.text('cancel')),
        ),
        FilledButton(
          key: const ValueKey('sheet_choice_export'),
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected.toList()..sort()),
          child: Text(l10n.text('exportAction')),
        ),
      ],
    );
  }
}
