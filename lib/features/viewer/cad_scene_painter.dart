import 'dart:math' as math;
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/cad_engine.dart';
import 'cad_document_model.dart';

const _cadFontFallback = <String>[
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'PingFang SC',
  'Hiragino Sans GB',
  'Arial Unicode MS',
  'sans-serif',
];

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

final Expando<List<CadPoint3>> _meshPositionCache = Expando<List<CadPoint3>>();
final Expando<List<int>> _meshIndexCache = Expando<List<int>>();

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
    this.measurementPoints = const [],
    this.yaw = -0.75,
    this.pitch = 0.55,
    this.selectedMeshId,
    this.measurement3DPoints = const [],
    this.interactive = false,
  });

  final CadDocumentModel document;
  final double zoom;
  final Offset pan;
  final List<CadTextAnnotation> annotations;
  final BigInt? selectedEntityId;
  final List<Offset> measurementPoints;
  final double yaw;
  final double pitch;
  final BigInt? selectedMeshId;
  final List<CadPoint3> measurement3DPoints;
  final bool interactive;

  static final Expando<Rect> _polylineBounds = Expando<Rect>();
  static final LinkedHashMap<(int, int, int, String), TextPainter>
  _textLayouts = LinkedHashMap();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff071017),
    );
    _paintGrid(canvas, size);
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
    final entities = document.entities;
    final paints = <int, Paint>{};
    const interactiveEntityBudget = 25000;
    final entityStride = interactive
        ? math.max(1, (entities.length / interactiveEntityBudget).ceil())
        : 1;
    for (
      var entityIndex = 0;
      entityIndex < entities.length;
      entityIndex += entityStride
    ) {
      final entity = entities[entityIndex];
      if (!(visibleLayers[entity['layer_id'] as int] ?? true)) continue;
      final selected = BigInt.from(entity['id'] as int) == selectedEntityId;
      final colorArgb = selected ? 0xffffd666 : entity['color_argb'] as int;
      final paintKey = Object.hash(colorArgb, selected);
      final paint = paints.putIfAbsent(
        paintKey,
        () => Paint()
          ..color = Color(colorArgb)
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 2.5 : 1.15
          ..strokeCap = StrokeCap.round,
      );
      final geometry = entity['geometry'] as Map<String, dynamic>;
      if (!_geometryVisible(geometry, transform, size)) continue;
      if (interactive && geometry['kind'] == 'text') continue;
      switch (geometry['kind']) {
        case 'point':
          final point = transform.worldToScreen(_point(geometry['position']));
          canvas.drawCircle(point, selected ? 5 : 2.5, paint);
        case 'line':
          canvas.drawLine(
            transform.worldToScreen(_point(geometry['start'])),
            transform.worldToScreen(_point(geometry['end'])),
            paint,
          );
        case 'polyline':
          final points = geometry['points'] as List<dynamic>;
          if (points.isEmpty) continue;
          final first = transform.worldToScreen(_point(points.first));
          final path = Path()..moveTo(first.dx, first.dy);
          for (final value in points.skip(1)) {
            final point = transform.worldToScreen(_point(value));
            path.lineTo(point.dx, point.dy);
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
          final radius =
              (geometry['radius'] as num).toDouble() * transform.scale;
          final start = (geometry['start_angle'] as num).toDouble();
          var sweep = (geometry['end_angle'] as num).toDouble() - start;
          if (sweep <= 0) sweep += math.pi * 2;
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            -start,
            -sweep,
            false,
            paint,
          );
        case 'text':
          final origin = transform.worldToScreen(_point(geometry['origin']));
          final value = geometry['value'] as String;
          final fontSize =
              ((geometry['height'] as num).toDouble() * transform.scale)
                  .clamp(6, 256)
                  .toDouble();
          final text = _textLayout(
            entity['id'] as int,
            value,
            paint.color,
            fontSize,
          );
          canvas.save();
          canvas.translate(origin.dx, origin.dy);
          canvas.rotate(-(geometry['rotation'] as num).toDouble());
          text.paint(canvas, Offset.zero);
          canvas.restore();
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
            fontFamilyFallback: _cadFontFallback,
          ),
        ),
        maxLines: 2,
        ellipsis: '…',
        textDirection: _textDirection(annotation.value),
      )..layout(maxWidth: 180);
      label.paint(canvas, point + const Offset(8, -28));
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
    if (screenPoints.length == 2) {
      canvas.drawLine(screenPoints[0], screenPoints[1], measurementPaint);
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
    final triangleBudget = interactive ? 8000 : 25000;
    final totalTriangles = visibleMeshes.fold<int>(
      0,
      (total, mesh) => total + (mesh['indices'] as List<dynamic>).length ~/ 3,
    );
    final triangleStride = math.max(
      1,
      (totalTriangles / triangleBudget).ceil(),
    );
    var triangleOrdinal = 0;
    var paintedTriangles = 0;
    for (final mesh in visibleMeshes) {
      final positions = _meshPositions(mesh);
      final indices = _meshIndices(mesh);
      final selected = BigInt.from(mesh['id'] as int) == selectedMeshId;
      final paint = Paint()
        ..color = selected
            ? const Color(0xffffd666)
            : const Color(0xff73dfff).withValues(alpha: 0.72)
        ..strokeWidth = selected ? 1.8 : 0.8
        ..style = PaintingStyle.stroke;
      for (
        var index = 0;
        index + 2 < indices.length && paintedTriangles < triangleBudget;
        index += 3
      ) {
        if (triangleOrdinal++ % triangleStride != 0) continue;
        final a = transform.project(positions[indices[index]]);
        final b = transform.project(positions[indices[index + 1]]);
        final c = transform.project(positions[indices[index + 2]]);
        canvas.drawLine(a, b, paint);
        canvas.drawLine(b, c, paint);
        canvas.drawLine(c, a, paint);
        paintedTriangles++;
      }
    }

    for (final annotation in annotations.where((item) => item.is3D)) {
      final point = transform.project(
        CadPoint3(annotation.x, annotation.y, annotation.z!),
      );
      _paintAnnotation(canvas, point, annotation.value);
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
    if (screenPoints.length == 2) {
      canvas.drawLine(screenPoints[0], screenPoints[1], measurementPaint);
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
          fontFamilyFallback: _cadFontFallback,
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: _textDirection(value),
    )..layout(maxWidth: 180);
    label.paint(canvas, point + const Offset(8, -28));
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
        return viewport.contains(
          transform.worldToScreen(_point(geometry['origin'])),
        );
      default:
        return true;
    }
  }

  TextDirection _textDirection(String value) {
    final hasRtl = value.runes.any(
      (rune) =>
          (rune >= 0x0590 && rune <= 0x08ff) ||
          (rune >= 0xfb1d && rune <= 0xfdff) ||
          (rune >= 0xfe70 && rune <= 0xfeff),
    );
    return hasRtl ? TextDirection.rtl : TextDirection.ltr;
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

  TextPainter _textLayout(int id, String value, Color color, double fontSize) {
    final sizeBucket = (fontSize * 2).round();
    final key = (id, sizeBucket, color.toARGB32(), value);
    final existing = _textLayouts.remove(key);
    if (existing != null) {
      _textLayouts[key] = existing;
      return existing;
    }
    final layout = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontFamilyFallback: _cadFontFallback,
          fontSize: sizeBucket / 2,
        ),
      ),
      textDirection: _textDirection(value),
    )..layout();
    _textLayouts[key] = layout;
    if (_textLayouts.length > 512) _textLayouts.remove(_textLayouts.keys.first);
    return layout;
  }

  @override
  bool shouldRepaint(covariant CadScenePainter oldDelegate) =>
      oldDelegate.document != document ||
      oldDelegate.zoom != zoom ||
      oldDelegate.pan != pan ||
      !listEquals(oldDelegate.annotations, annotations) ||
      oldDelegate.selectedEntityId != selectedEntityId ||
      !listEquals(oldDelegate.measurementPoints, measurementPoints) ||
      oldDelegate.yaw != yaw ||
      oldDelegate.pitch != pitch ||
      oldDelegate.selectedMeshId != selectedMeshId ||
      !listEquals(oldDelegate.measurement3DPoints, measurement3DPoints) ||
      oldDelegate.interactive != interactive;
}
