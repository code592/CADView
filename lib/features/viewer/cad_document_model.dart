import 'dart:ui';

class CadDocumentModel {
  CadDocumentModel({
    required this.format,
    required this.displayName,
    required this.sceneKind,
    required this.scene,
    required this.diagnostics,
    this.units,
  });

  factory CadDocumentModel.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'] as Map<String, dynamic>;
    final sceneEnvelope = json['scene'] as Map<String, dynamic>;
    return CadDocumentModel(
      format: metadata['format'] as String,
      displayName: metadata['display_name'] as String,
      units: metadata['units'] as String?,
      sceneKind: sceneEnvelope['scene_kind'] as String,
      scene: sceneEnvelope['scene'] as Map<String, dynamic>,
      diagnostics: (json['diagnostics'] as List<dynamic>)
          .cast<Map<String, dynamic>>(),
    );
  }

  final String format;
  final String displayName;
  final String? units;
  final String sceneKind;
  final Map<String, dynamic> scene;
  final List<Map<String, dynamic>> diagnostics;

  late final List<CadLayerModel> layers = _decodeLayers();
  late final List<Map<String, dynamic>> entities = _decodeEntities();
  late final Rect? bounds2D = _decodeBounds2D();
  late final List<Map<String, dynamic>> meshes = _decodeMeshes();
  late final List<CadAssemblyNode> assemblyRoots = _decodeAssemblyRoots();
  late final Set<int> visibleMeshIds = _decodeVisibleMeshIds();

  CadDocumentModel withLayerStateFrom(CadDocumentModel source) {
    if (sceneKind != 'two_d' || source.sceneKind != 'two_d') return source;
    final retainedScene = Map<String, dynamic>.from(scene)
      ..['layers'] = source.scene['layers'];
    return CadDocumentModel(
      format: format,
      displayName: displayName,
      units: units,
      sceneKind: sceneKind,
      scene: retainedScene,
      diagnostics: diagnostics,
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
    return (scene['entities'] as List<dynamic>).cast<Map<String, dynamic>>();
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
