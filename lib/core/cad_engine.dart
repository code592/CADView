import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../features/viewer/cad_document_model.dart';
import '../src/rust/api/document.dart' as native;
import 'distribution.dart';
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
  Future<CadDocumentModel> loadViewport(BigInt sessionId, Rect worldBounds);
  Future<CadHit?> hitTest(
    BigInt sessionId,
    double x,
    double y,
    double tolerance,
  );
  double measureDistance(double x1, double y1, double x2, double y2);
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
    if (!_cacheConfigured) {
      final directory = await NativePaths.applicationSupport();
      native.configureCache(
        directory:
            '$directory${Platform.pathSeparator}cache'
            '${Platform.pathSeparator}scenes',
      );
      _cacheConfigured = true;
    }
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
          onEvent?.call(converted);
          terminal = terminal || converted.terminal;
        }
      }
      response = await native.finishOpenDocument(ticketId: ticket.ticketId);
      while (response == null) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        response = await native.finishOpenDocument(ticketId: ticket.ticketId);
      }
    } finally {
      if (_currentOpenTicket == ticket.ticketId) _currentOpenTicket = null;
    }
    final documentMap = await compute(
      _decodeDocumentJson,
      response.documentJson,
    );
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
    return OpenedCadDocument(
      sessionId: response.sessionId,
      formatId: response.formatId,
      sceneKind: response.sceneKind,
      displayName: response.displayName,
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
    final ticket = _currentOpenTicket;
    if (ticket != null) native.cancelOpenDocument(ticketId: ticket);
  }

  @override
  void setApplicationBackgrounded(bool backgrounded) {
    native.setApplicationBackgrounded(backgrounded: backgrounded);
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
  double measureDistance(double x1, double y1, double x2, double y2) {
    _requireFullFeatures();
    return native.measureDistance2D(x1: x1, y1: y1, x2: x2, y2: y2);
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

Map<String, dynamic> _decodeDocumentJson(String source) =>
    jsonDecode(source) as Map<String, dynamic>;
