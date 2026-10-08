import 'dart:ui';

import 'cad_scene_packet.dart';

class CadDocumentModel {
  CadDocumentModel({
    required this.format,
    required this.displayName,
    required this.sceneKind,
    required this.scene,
    required this.diagnostics,
    this.units,
    this.frames = const [],
  });

  factory CadDocumentModel.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'] as Map<String, dynamic>;
    final sceneEnvelope = json['scene'] as Map<String, dynamic>;
    return CadDocumentModel(
      format: metadata['format'] as String,
      displayName: metadata['display_name'] as String,
      units: metadata['units'] as String?,
      frames: CadDrawingFrame.listFromJson(metadata['frames']),
      sceneKind: sceneEnvelope['scene_kind'] as String,
      scene: sceneEnvelope['scene'] as Map<String, dynamic>,
      diagnostics: (json['diagnostics'] as List<dynamic>)
          .cast<Map<String, dynamic>>(),
    );
  }

  final String format;
  final String displayName;
  final String? units;

  /// Sheet borders detected by the native engine, in reading order.
  final List<CadDrawingFrame> frames;
  final String sceneKind;
  final Map<String, dynamic> scene;
  final List<Map<String, dynamic>> diagnostics;

  late final List<CadLayerModel> layers = _decodeLayers();
  late final List<Map<String, dynamic>> entities = _decodeEntities();
  late final Rect? bounds2D = _decodeBounds2D();
  late final List<Map<String, dynamic>> meshes = _decodeMeshes();
  late final List<CadAssemblyNode> assemblyRoots = _decodeAssemblyRoots();
  late final Set<int> visibleMeshIds = _decodeVisibleMeshIds();
  final _recentEntities = <int, Map<String, dynamic>?>{};

  /// Packed scene IDs use a verified sorted lookup, including sparse IDs and
  /// first occurrences of duplicates. Legacy sequential IDs are checked
  /// directly; nonsequential legacy IDs use an exact fallback. Only 128
  /// recent lookups are retained; no million-entry Dart index is allocated.
  Map<String, dynamic>? entityById(int id) {
    if (_recentEntities.containsKey(id)) return _recentEntities[id];
    Map<String, dynamic>? found;
    final retained = entities;
    if (retained is CadPackedEntities) {
      final index = retained.indexOfId(id);
      if (index >= 0) found = retained[index];
    } else if (retained.isNotEmpty) {
      final firstId = retained.first['id'];
      if (firstId is int) {
        final guess = id - firstId;
        if (guess >= 0 && guess < retained.length) {
          final candidate = retained[guess];
          if (candidate['id'] == id) found = candidate;
        }
      }
      if (found == null) {
        for (final entity in retained) {
          if (entity['id'] == id) {
            found = entity;
            break;
          }
        }
      }
    }
    if (_recentEntities.length >= 128) {
      _recentEntities.remove(_recentEntities.keys.first);
    }
    _recentEntities[id] = found;
    return found;
  }

  CadDocumentModel withLayerStateFrom(CadDocumentModel source) {
    if (sceneKind != 'two_d' || source.sceneKind != 'two_d') return source;
    final retainedScene = Map<String, dynamic>.from(scene)
      ..['layers'] = source.scene['layers'];
    return CadDocumentModel(
      format: format,
      displayName: displayName,
      units: units,
      frames: frames,
      sceneKind: sceneKind,
      scene: retainedScene,
      diagnostics: diagnostics,
    );
  }

  CadDocumentModel withAssemblyStateFrom(CadDocumentModel source) {
    if (sceneKind != 'three_d' || source.sceneKind != 'three_d') return source;
    return CadDocumentModel(
      format: format,
      displayName: displayName,
      units: units,
      frames: frames,
      sceneKind: sceneKind,
      diagnostics: source.diagnostics,
      scene: Map<String, dynamic>.from(scene)
        ..['root_nodes'] = source.scene['root_nodes'],
    );
  }

  List<CadLayerModel> _decodeLayers() {
    if (sceneKind != 'two_d') return const [];
    return (scene['layers'] as List<dynamic>)
        .map((value) => CadLayerModel.fromJson(value as Map<String, dynamic>))
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _decodeEntities() {
    if (sceneKind != 'two_d') return const [];
    final values = scene['entities'];
    if (values is List<Map<String, dynamic>>) return values;
    return (values as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Rect? _decodeBounds2D() {
    if (sceneKind != 'two_d' || scene['bounds'] == null) return null;
    final bounds = scene['bounds'] as Map<String, dynamic>;
    final min = bounds['min'] as Map<String, dynamic>;
    final max = bounds['max'] as Map<String, dynamic>;
    return Rect.fromLTRB(
      (min['x'] as num).toDouble(),
      (min['y'] as num).toDouble(),
      (max['x'] as num).toDouble(),
      (max['y'] as num).toDouble(),
    );
  }

  List<Map<String, dynamic>> _decodeMeshes() {
    if (sceneKind != 'three_d') return const [];
    return (scene['meshes'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  List<CadAssemblyNode> _decodeAssemblyRoots() {
    if (sceneKind != 'three_d') return const [];
    return (scene['root_nodes'] as List<dynamic>)
        .map((value) => CadAssemblyNode.fromJson(value as Map<String, dynamic>))
        .toList(growable: false);
  }

  Set<int> _decodeVisibleMeshIds() {
    final result = <int>{};
    void visit(CadAssemblyNode node, bool parentVisible) {
      final visible = parentVisible && node.visible;
      if (visible) {
        result.addAll(node.meshIds.map((id) => id.toInt()));
      }
      for (final child in node.children) {
        visit(child, visible);
      }
    }

    for (final root in assemblyRoots) {
      visit(root, true);
    }
    return result;
  }
}

class CadAssemblyNode {
  const CadAssemblyNode({
    required this.id,
    required this.name,
    required this.visible,
    required this.meshIds,
    required this.children,
  });

  factory CadAssemblyNode.fromJson(Map<String, dynamic> json) =>
      CadAssemblyNode(
        id: BigInt.from(json['id'] as int),
        name: json['name'] as String,
        visible: json['visible'] as bool,
        meshIds: (json['mesh_ids'] as List<dynamic>)
            .map((value) => BigInt.from(value as int))
            .toList(growable: false),
        children: (json['children'] as List<dynamic>)
            .map(
              (value) =>
                  CadAssemblyNode.fromJson(value as Map<String, dynamic>),
            )
            .toList(growable: false),
      );

  final BigInt id;
  final String name;
  final bool visible;
  final List<BigInt> meshIds;
  final List<CadAssemblyNode> children;
}

class CadLayerModel {
  const CadLayerModel({
    required this.id,
    required this.name,
    required this.visible,
    required this.color,
  });

  factory CadLayerModel.fromJson(Map<String, dynamic> json) => CadLayerModel(
    id: BigInt.from(json['id'] as int),
    name: json['name'] as String,
    visible: json['visible'] as bool,
    color: Color(json['color_argb'] as int),
  );

  final BigInt id;
  final String name;
  final bool visible;
  final Color color;
}

/// One drawing sheet: the outer border of a title-block frame.
class CadDrawingFrame {
  const CadDrawingFrame({required this.bounds, this.paper, this.scale});

  /// World rectangle (left/top hold the minimum X/Y, as for scene bounds).
  final Rect bounds;

  /// Matching ISO sheet, such as "A1".
  final String? paper;

  /// Drawing units per paper millimetre for [paper].
  final double? scale;

  static List<CadDrawingFrame> listFromJson(Object? value) {
    if (value is! List) return const [];
    final frames = <CadDrawingFrame>[];
    for (final item in value) {
      if (item is! Map) continue;
      final bounds = item['bounds'];
      if (bounds is! Map) continue;
      final min = bounds['min'];
      final max = bounds['max'];
      if (min is! Map || max is! Map) continue;
      final rect = Rect.fromLTRB(
        (min['x'] as num).toDouble(),
        (min['y'] as num).toDouble(),
        (max['x'] as num).toDouble(),
        (max['y'] as num).toDouble(),
      );
      if (!rect.isFinite || rect.isEmpty) continue;
      final scale = (item['scale'] as num?)?.toDouble();
      frames.add(
        CadDrawingFrame(
          bounds: rect,
          paper: item['paper'] as String?,
          scale: scale != null && scale.isFinite && scale > 0 ? scale : null,
        ),
      );
    }
    return List.unmodifiable(frames);
  }
}
