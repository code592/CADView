import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../features/viewer/cad_document_model.dart';
import '../features/viewer/cad_scene_painter.dart' show cadTextWorldBounds;
import '../src/rust/api/document.dart' as native;
import 'distribution.dart';
import 'document_name.dart';
import 'cad_font_metrics.dart';
import 'native_paths.dart';

class CadFormatDescriptor {
  const CadFormatDescriptor({
    required this.id,
    required this.displayName,
    required this.extensions,
    required this.sceneKind,
    required this.supportLevel,
    required this.available,
    required this.canMeasure,
    this.note,
  });

  final String id;
  final String displayName;
  final List<String> extensions;
  final String sceneKind;
  final String supportLevel;
  final bool available;
  final bool canMeasure;
  final String? note;
}

class OpenedCadDocument {
  OpenedCadDocument({
    required this.sessionId,
    required this.formatId,
    required this.sceneKind,
    required this.displayName,
    required this.fingerprint,
    required this.document,
    required this.annotations,
    required this.sourcePath,
    required this.totalEntityCount,
    required this.isPartial,
  });

  final BigInt sessionId;
  final String formatId;
  final String sceneKind;
  final String displayName;
  final String fingerprint;
  CadDocumentModel document;
  List<CadTextAnnotation> annotations;
  final String sourcePath;
  final BigInt totalEntityCount;
  final bool isPartial;
}

class CadTextAnnotation {
  const CadTextAnnotation({
    required this.id,
    required this.value,
    required this.x,
    required this.y,
    this.z,
  });

  final String id;
  final String value;
  final double x;
  final double y;
  final double? z;
  bool get is3D => z != null;

  static List<CadTextAnnotation> listFromJson(String source) {
    final root = jsonDecode(source) as Map<String, dynamic>;
    return (root['annotations'] as List<dynamic>)
        .map((item) => item as Map<String, dynamic>)
        .where(
          (item) =>
              (item['geometry'] as Map<String, dynamic>)['kind'] == 'text',
        )
        .map((item) {
          final geometry = item['geometry'] as Map<String, dynamic>;
          final anchor = geometry['anchor'] as Map<String, dynamic>;
          final world = anchor['world_2d'] as Map<String, dynamic>?;
          final world3D = anchor['world_3d'] as Map<String, dynamic>?;
          return CadTextAnnotation(
            id: item['id'] as String,
            value: geometry['value'] as String,
            x: ((world ?? world3D)?['x'] as num?)?.toDouble() ?? 0,
            y: ((world ?? world3D)?['y'] as num?)?.toDouble() ?? 0,
            z: (world3D?['z'] as num?)?.toDouble(),
          );
        })
        .toList(growable: false);
  }
}

class CadHit {
  const CadHit({
    required this.entityId,
    required this.layerId,
    required this.distance,
    required this.entityKind,
  });

  final BigInt entityId;
  final BigInt layerId;
  final double distance;
  final String entityKind;
}

class CadSnap {
  const CadSnap({
    required this.entityId,
    required this.position,
    required this.kind,
    required this.distance,
  });

  final BigInt entityId;
  final Offset position;
  final String kind;
  final double distance;
}

class CadEntityCountSummary {
  const CadEntityCountSummary({
    required this.entityKind,
    required this.layerId,
    required this.sameKindInLayer,
    required this.sameKindInDocument,
    this.sameKindLengthInLayer,
    this.sameKindLengthInDocument,
    this.sameKindAreaInLayer,
    this.sameKindAreaInDocument,
  });

  final String entityKind;
  final BigInt layerId;
  final BigInt sameKindInLayer;
  final BigInt sameKindInDocument;
  final double? sameKindLengthInLayer;
  final double? sameKindLengthInDocument;
  final double? sameKindAreaInLayer;
  final double? sameKindAreaInDocument;
}

class CadOpenEvent {
  const CadOpenEvent({
    required this.kind,
    required this.stage,
    required this.progress,
    this.message,
  });

  final String kind;
  final String stage;
  final double progress;
  final String? message;
  bool get terminal =>
      kind == 'complete' || kind == 'cancelled' || stage == 'failed';
}

class CadOpenCancelled implements Exception {
  const CadOpenCancelled();
}

abstract interface class CadEngine {
  Future<List<CadFormatDescriptor>> supportedFormats();
  Future<OpenedCadDocument> openDocument(
    String path, {
    void Function(CadOpenEvent event)? onEvent,
  });
  void cancelCurrentOpen();
  void setApplicationBackgrounded(bool backgrounded);
  Future<void> closeDocument(BigInt sessionId);
  Future<CadDocumentModel> setVisibility(
    BigInt sessionId,
    BigInt itemId,
    bool visible,
  );
  Future<CadDocumentModel> setVisibilities(
    BigInt sessionId,
    Map<BigInt, bool> changes,
  );
  Future<CadDocumentModel> loadViewport(BigInt sessionId, Rect worldBounds);
  Future<CadHit?> hitTest(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  );
  Future<CadSnap?> snap(BigInt sessionId, double x, double y, double tolerance);
  Future<CadSnap?> snapIntersection(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  );
  CadEntityCountSummary? entityCountSummary(BigInt sessionId, BigInt entityId);
  double measureDistance(double x1, double y1, double x2, double y2);
  double measurePath(List<Offset> points, {bool closed = false});
  double measureAngle(Offset vertex, Offset first, Offset second);
  double? measureArea(List<Offset> points);
  double measureDistance3D(
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
  );
  Future<List<CadTextAnnotation>> addTextAnnotation(
    BigInt sessionId,
    String value,
    double x,
    double y,
    BigInt? entityId,
  );
  Future<List<CadTextAnnotation>> addTextAnnotation3D(
    BigInt sessionId,
    String value,
    double x,
    double y,
    double z,
    BigInt? meshId,
  );
  Future<List<CadTextAnnotation>> deleteAnnotation(
    BigInt sessionId,
    String annotationId,
  );
  Future<String> exportAnnotations(BigInt sessionId);
}

class NativeCadEngine implements CadEngine {
  String? _annotationDatabasePath;
  bool _cacheConfigured = false;
  BigInt? _currentOpenTicket;
  int _openGeneration = 0;
  bool _applicationBackgrounded = false;

  Future<String> _databasePath() async {
    if (_annotationDatabasePath != null) return _annotationDatabasePath!;
    final directory = await NativePaths.applicationSupport();
    return _annotationDatabasePath =
        '$directory${Platform.pathSeparator}annotations.sqlite3';
  }

  @override
  Future<List<CadFormatDescriptor>> supportedFormats() async {
    return native
        .supportedFormats()
        .map(
          (format) => CadFormatDescriptor(
            id: format.id,
            displayName: format.displayName,
            extensions: format.extensions,
            sceneKind: format.sceneKind,
            supportLevel: format.supportLevel,
            available: format.available,
            canMeasure: format.canMeasure,
            note: format.note,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<OpenedCadDocument> openDocument(
    String path, {
    void Function(CadOpenEvent event)? onEvent,
  }) async {
    final generation = ++_openGeneration;
    if (!_cacheConfigured) {
      final directory = await NativePaths.applicationSupport();
      native.configureCache(
        directory:
            '$directory${Platform.pathSeparator}cache'
            '${Platform.pathSeparator}scenes',
      );
      _cacheConfigured = true;
    }
    _ensureOpenActive(generation);
    final ticket = native.beginOpenDocument(path: path);
    _currentOpenTicket = ticket.ticketId;
    native.OpenDocumentResponse? response;
    try {
      var terminal = false;
      var pollDelay = 40;
      while (!terminal) {
        await Future<void>.delayed(Duration(milliseconds: pollDelay));
        final events = native.pollDocumentEvents(ticketId: ticket.ticketId);
        pollDelay = events.isEmpty
            ? (pollDelay + 15).clamp(40, 120).toInt()
            : 40;
        for (final event in events) {
          final converted = CadOpenEvent(
            kind: event.kind,
            stage: event.stage,
            progress: event.progress,
            message: event.message,
          );
          if (converted.kind != 'complete') onEvent?.call(converted);
          terminal = terminal || converted.terminal;
        }
      }
      response = await native.finishOpenDocument(ticketId: ticket.ticketId);
      while (response == null) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        response = await native.finishOpenDocument(ticketId: ticket.ticketId);
      }
    } catch (_) {
      _ensureOpenActive(generation);
      rethrow;
    } finally {
      if (_currentOpenTicket == ticket.ticketId) _currentOpenTicket = null;
    }
    late Map<String, dynamic> documentMap;
    var fontMetricLimitReached = false;
    try {
      if (response.sceneKind == 'two_d') {
        onEvent?.call(
          const CadOpenEvent(
            kind: 'progress',
            stage: 'first_frame',
            progress: 1,
          ),
        );
        var cursor = BigInt.zero;
        while (true) {
          _ensureOpenActive(generation);
          final batch = jsonDecode(
            await native.textLayoutBatch(
              sessionId: response.sessionId,
              start: cursor,
            ),
          ) as Map<String, dynamic>;
          final packets = <Map<String, dynamic>>[];
          final budget = Stopwatch()..start();
          for (final item in batch['items'] as List<dynamic>) {
            _ensureOpenActive(generation);
            final geometry = (item['geometry'] as Map).cast<String, dynamic>();
            final calibrated = await prepareCadTextFontMetrics(geometry);
            _ensureOpenActive(generation);
            if (!calibrated) fontMetricLimitReached = true;
            final bounds = cadTextWorldBounds(geometry);
            packets.add({
              'index': item['index'],
              'id': item['id'],
              'min_x': bounds.left,
              'min_y': bounds.top,
              'max_x': bounds.right,
              'max_y': bounds.bottom,
            });
            if (budget.elapsedMilliseconds >= 8) {
              await Future<void>.delayed(Duration.zero);
              budget.reset();
            }
          }
          if (packets.isNotEmpty) {
            await native.applyTextLayoutBounds(
              sessionId: response.sessionId,
              packet: jsonEncode(packets),
            );
          }
          cursor = BigInt.from(batch['next'] as int);
          if (cursor >= BigInt.from(batch['total'] as int)) break;
          await Future<void>.delayed(Duration.zero);
        }
        _ensureOpenActive(generation);
        final summary = await native.finalizeTextLayout(
          sessionId: response.sessionId,
        );
        documentMap = await compute(_decodeDocumentJson, response.documentJson);
        final measuredMap = jsonDecode(summary) as Map<String, dynamic>;
        final scene = documentMap['scene'] as Map<String, dynamic>;
        final measuredScene = measuredMap['scene'] as Map<String, dynamic>;
        (scene['scene'] as Map<String, dynamic>)['bounds'] =
            (measuredScene['scene'] as Map<String, dynamic>)['bounds'];
      } else {
        documentMap = await compute(_decodeDocumentJson, response.documentJson);
      }
      _ensureOpenActive(generation);
      if (fontMetricLimitReached) {
        (documentMap['diagnostics'] as List).add({
          'code': 'cad.text.font_metric_fallback',
          'severity': 'warning',
          'message': 'Some font heights could not be calibrated (readback or 512-family limit); those families use readable default metrics.',
          'entity_id': null,
        });
      }
    } catch (_) {
      native.closeDocument(sessionId: response.sessionId);
      rethrow;
    }
    var annotationJson = '{"annotations": []}';
    if (DistributionConfig.fullFeatures) {
      try {
        annotationJson = native.loadAnnotations(
          sessionId: response.sessionId,
          databasePath: await _databasePath(),
        );
      } catch (_) {
        // A damaged annotation database must never prevent the CAD opening.
      }
    }
    if (generation != _openGeneration || _applicationBackgrounded) {
      native.closeDocument(sessionId: response.sessionId);
      throw const CadOpenCancelled();
    }
    onEvent?.call(
      const CadOpenEvent(kind: 'complete', stage: 'complete', progress: 1),
    );
    return OpenedCadDocument(
      sessionId: response.sessionId,
      formatId: response.formatId,
      sceneKind: response.sceneKind,
      displayName: documentDisplayName(path, response.displayName),
      fingerprint: response.fingerprint,
      document: CadDocumentModel.fromJson(documentMap),
      annotations: DistributionConfig.fullFeatures
          ? CadTextAnnotation.listFromJson(annotationJson)
          : const [],
      sourcePath: path,
      totalEntityCount: response.totalEntityCount,
      isPartial: response.isPartial,
    );
  }

  @override
  void cancelCurrentOpen() {
    _openGeneration++;
    final ticket = _currentOpenTicket;
    if (ticket != null) native.cancelOpenDocument(ticketId: ticket);
  }

  @override
  void setApplicationBackgrounded(bool backgrounded) {
    _applicationBackgrounded = backgrounded;
    if (backgrounded) _openGeneration++;
    native.setApplicationBackgrounded(backgrounded: backgrounded);
  }

  void _ensureOpenActive(int generation) {
    if (generation != _openGeneration || _applicationBackgrounded) {
      throw const CadOpenCancelled();
    }
  }

  @override
  Future<CadDocumentModel> loadViewport(
    BigInt sessionId,
    Rect worldBounds,
  ) async {
    final json = await native.viewportDocument(
      sessionId: sessionId,
      minX: worldBounds.left,
      minY: worldBounds.top,
      maxX: worldBounds.right,
      maxY: worldBounds.bottom,
    );
    final documentMap = await compute(_decodeDocumentJson, json);
    return CadDocumentModel.fromJson(documentMap);
  }

  @override
  Future<void> closeDocument(BigInt sessionId) async {
    if (DistributionConfig.fullFeatures) {
      try {
        native.saveAnnotations(
          sessionId: sessionId,
          databasePath: await _databasePath(),
        );
      } catch (_) {
        // Closing the native document remains best-effort if persistence fails.
      }
    }
    native.closeDocument(sessionId: sessionId);
  }

  @override
  Future<CadDocumentModel> setVisibility(
    BigInt sessionId,
    BigInt itemId,
    bool visible,
  ) async {
    final json = native.setVisibility(
      sessionId: sessionId,
      itemId: itemId,
      visible: visible,
    );
    return CadDocumentModel.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  Future<CadDocumentModel> setVisibilities(
    BigInt sessionId,
    Map<BigInt, bool> changes,
  ) async {
    final entries = changes.entries.toList(growable: false);
    final json = native.setVisibilities(
      sessionId: sessionId,
      changes: entries
          .map(
            (entry) => native.VisibilityChange(
              itemId: entry.key,
              visible: entry.value,
            ),
          )
          .toList(growable: false),
    );
    return CadDocumentModel.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  @override
  Future<CadHit?> hitTest(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async {
    final hit = native.hitTest(
      sessionId: sessionId,
      x: x,
      y: y,
      tolerance: tolerance,
    );
    if (hit == null) return null;
    return CadHit(
      entityId: hit.entityId,
      layerId: hit.layerId,
      distance: hit.distance,
      entityKind: hit.entityKind,
    );
  }

  @override
  Future<CadSnap?> snap(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async {
    final result = native.snap(
      sessionId: sessionId,
      x: x,
      y: y,
      tolerance: tolerance,
    );
    if (result == null) return null;
    return CadSnap(
      entityId: result.entityId,
      position: Offset(result.x, result.y),
      kind: result.snapKind,
      distance: result.distance,
    );
  }

  @override
  Future<CadSnap?> snapIntersection(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  ) async {
    final result = native.snapIntersection(
      sessionId: sessionId,
      x: x,
      y: y,
      tolerance: tolerance,
    );
    if (result == null) return null;
    return CadSnap(
      entityId: result.entityId,
      position: Offset(result.x, result.y),
      kind: result.snapKind,
      distance: result.distance,
    );
  }

  @override
  CadEntityCountSummary? entityCountSummary(BigInt sessionId, BigInt entityId) {
    final result = native.entityCountSummary(
      sessionId: sessionId,
      entityId: entityId,
    );
    if (result == null) return null;
    return CadEntityCountSummary(
      entityKind: result.entityKind,
      layerId: result.layerId,
      sameKindInLayer: result.sameKindInLayer,
      sameKindInDocument: result.sameKindInDocument,
      sameKindLengthInLayer: result.sameKindLengthInLayer,
      sameKindLengthInDocument: result.sameKindLengthInDocument,
      sameKindAreaInLayer: result.sameKindAreaInLayer,
      sameKindAreaInDocument: result.sameKindAreaInDocument,
    );
  }

  @override
  double measureDistance(double x1, double y1, double x2, double y2) {
    _requireFullFeatures();
    return native.measureDistance2D(x1: x1, y1: y1, x2: x2, y2: y2);
  }

  @override
  double measurePath(List<Offset> points, {bool closed = false}) {
    _requireFullFeatures();
    return polylineLength2D(points, closed: closed);
  }

  @override
  double measureAngle(Offset vertex, Offset first, Offset second) {
    _requireFullFeatures();
    return angleDegrees2D(vertex, first, second);
  }

  @override
  double? measureArea(List<Offset> points) {
    _requireFullFeatures();
    return simplePolygonArea2D(points);
  }

  @override
  double measureDistance3D(
    double x1,
    double y1,
    double z1,
    double x2,
    double y2,
    double z2,
  ) {
    _requireFullFeatures();
    return native.measureDistance3D(
      x1: x1,
      y1: y1,
      z1: z1,
      x2: x2,
      y2: y2,
      z2: z2,
    );
  }

  @override
  Future<List<CadTextAnnotation>> addTextAnnotation(
    BigInt sessionId,
    String value,
    double x,
    double y,
    BigInt? entityId,
  ) async {
    _requireFullFeatures();
    final json = native.addTextAnnotation(
      sessionId: sessionId,
      value: value,
      x: x,
      y: y,
      entityId: entityId,
    );
    native.saveAnnotations(
      sessionId: sessionId,
      databasePath: await _databasePath(),
    );
    return CadTextAnnotation.listFromJson(json);
  }

  @override
  Future<List<CadTextAnnotation>> addTextAnnotation3D(
    BigInt sessionId,
    String value,
    double x,
    double y,
    double z,
    BigInt? meshId,
  ) async {
    _requireFullFeatures();
    final json = native.addTextAnnotation3D(
      sessionId: sessionId,
      value: value,
      x: x,
      y: y,
      z: z,
      meshId: meshId,
    );
    native.saveAnnotations(
      sessionId: sessionId,
      databasePath: await _databasePath(),
    );
    return CadTextAnnotation.listFromJson(json);
  }

  @override
  Future<List<CadTextAnnotation>> deleteAnnotation(
    BigInt sessionId,
    String annotationId,
  ) async {
    _requireFullFeatures();
    final json = native.deleteAnnotation(
      sessionId: sessionId,
      annotationId: annotationId,
    );
    native.saveAnnotations(
      sessionId: sessionId,
      databasePath: await _databasePath(),
    );
    return CadTextAnnotation.listFromJson(json);
  }

  @override
  Future<String> exportAnnotations(BigInt sessionId) async {
    _requireFullFeatures();
    return native.exportAnnotations(sessionId: sessionId);
  }

  void _requireFullFeatures() {
    if (!DistributionConfig.fullFeatures) {
      throw UnsupportedError(
        'This feature is not available in viewer edition.',
      );
    }
  }
}

double polygonArea2D(List<Offset> points) {
  if (points.length < 3) return 0;
  final origin = points.first;
  var twiceArea = 0.0;
  var compensation = 0.0;
  for (var index = 0; index < points.length; index++) {
    final current = points[index] - origin;
    final next = points[(index + 1) % points.length] - origin;
    final term = current.dx * next.dy - next.dx * current.dy;
    final corrected = term - compensation;
    final updated = twiceArea + corrected;
    compensation = (updated - twiceArea) - corrected;
    twiceArea = updated;
  }
  return twiceArea.abs() * 0.5;
}

double? simplePolygonArea2D(
  List<Offset> source, {
  int maxValidationVertices = 4096,
}) {
  if (source.length < 3) return null;
  final points = List<Offset>.of(source);
  final tolerance = _polygonTolerance(points);
  if (_samePoint(points.first, points.last, tolerance)) points.removeLast();
  if (points.length < 3 || points.length > maxValidationVertices) return null;
  for (var index = 0; index < points.length; index++) {
    if (_samePoint(
      points[index],
      points[(index + 1) % points.length],
      tolerance,
    )) {
      return null;
    }
  }
  for (var first = 0; first < points.length; first++) {
    for (var second = first + 1; second < points.length; second++) {
      final adjacent =
          second == first + 1 || (first == 0 && second == points.length - 1);
      if (adjacent) continue;
      if (_segmentsIntersect(
        points[first],
        points[(first + 1) % points.length],
        points[second],
        points[(second + 1) % points.length],
        tolerance,
      )) {
        return null;
      }
    }
  }
  final area = polygonArea2D(points);
  return area > tolerance * tolerance ? area : null;
}

double _polygonTolerance(List<Offset> points) {
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

bool _samePoint(Offset first, Offset second, double tolerance) =>
    (second - first).distanceSquared <= tolerance * tolerance;

bool _segmentsIntersect(
  Offset a,
  Offset b,
  Offset c,
  Offset d,
  double tolerance,
) {
  final first = _orientation(a, b, c, tolerance);
  final second = _orientation(a, b, d, tolerance);
  final third = _orientation(c, d, a, tolerance);
  final fourth = _orientation(c, d, b, tolerance);
  if (first * second < 0 && third * fourth < 0) return true;
  return (first == 0 && _onSegment(a, b, c, tolerance)) ||
      (second == 0 && _onSegment(a, b, d, tolerance)) ||
      (third == 0 && _onSegment(c, d, a, tolerance)) ||
      (fourth == 0 && _onSegment(c, d, b, tolerance));
}

int _orientation(Offset a, Offset b, Offset c, double tolerance) {
  final ab = b - a;
  final ac = c - a;
  final cross = ab.dx * ac.dy - ab.dy * ac.dx;
  final epsilon = tolerance * math.max(math.max(ab.distance, ac.distance), 1);
  if (cross.abs() <= epsilon) return 0;
  return cross > 0 ? 1 : -1;
}

bool _onSegment(Offset start, Offset end, Offset point, double tolerance) =>
    point.dx >= math.min(start.dx, end.dx) - tolerance &&
    point.dx <= math.max(start.dx, end.dx) + tolerance &&
    point.dy >= math.min(start.dy, end.dy) - tolerance &&
    point.dy <= math.max(start.dy, end.dy) + tolerance;

double polylineLength2D(List<Offset> points, {bool closed = false}) {
  if (points.length < 2) return 0;
  final segmentCount = closed ? points.length : points.length - 1;
  var sum = 0.0;
  var compensation = 0.0;
  for (var index = 0; index < segmentCount; index++) {
    final next = (index + 1) % points.length;
    final distance = (points[next] - points[index]).distance;
    final corrected = distance - compensation;
    final updated = sum + corrected;
    compensation = (updated - sum) - corrected;
    sum = updated;
  }
  return sum;
}

double angleDegrees2D(Offset vertex, Offset first, Offset second) {
  final firstRay = first - vertex;
  final secondRay = second - vertex;
  if (firstRay.distanceSquared == 0 || secondRay.distanceSquared == 0) return 0;
  final cross = firstRay.dx * secondRay.dy - firstRay.dy * secondRay.dx;
  final dot = firstRay.dx * secondRay.dx + firstRay.dy * secondRay.dy;
  return math.atan2(cross.abs(), dot) * 180 / math.pi;
}

Offset measurementDelta2D(Offset start, Offset end) => end - start;

double? directionDegrees2D(Offset start, Offset end) {
  if (!start.dx.isFinite ||
      !start.dy.isFinite ||
      !end.dx.isFinite ||
      !end.dy.isFinite) {
    return null;
  }
  final delta = end - start;
  if (!delta.dx.isFinite ||
      !delta.dy.isFinite ||
      (delta.dx == 0 && delta.dy == 0)) {
    return null;
  }
  final angle = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
  final normalized = angle < 0 ? angle + 360 : angle;
  return normalized >= 359.999999999999 ? 0 : normalized;
}

Map<String, dynamic> _decodeDocumentJson(String source) =>
    jsonDecode(source) as Map<String, dynamic>;
