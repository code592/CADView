import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/cad_engine.dart';
import '../../core/distribution.dart';
import '../../l10n/app_localizations.dart';
import 'cad_document_model.dart';
import 'cad_scene_painter.dart';
import 'pdf_document_viewport.dart';

enum ViewerTool { pan, select, measure, annotate }

class CadViewerPage extends StatefulWidget {
  const CadViewerPage({required this.engine, required this.opened, super.key});

  final CadEngine engine;
  final OpenedCadDocument opened;

  @override
  State<CadViewerPage> createState() => _CadViewerPageState();
}

class _CadViewerPageState extends State<CadViewerPage> {
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
  final List<CadPoint3> _measurement3DPoints = [];
  late List<CadTextAnnotation> _annotations = widget.opened.annotations;
  double? _measurement;
  double _yaw = -0.75;
  double _pitch = 0.55;
  double _startYaw = -0.75;
  double _startPitch = 0.55;
  double _startGestureScale = 1;
  int _gesturePointerCount = 0;
  Offset? _scaleAnchor2D;
  CadPoint3? _scaleAnchor3D;
  bool _isInteracting = false;
  Size _viewportSize = Size.zero;
  int _viewportRequest = 0;
  bool _initialViewportRequested = false;
  bool _viewportRefreshScheduled = false;

  @override
  void dispose() {
    widget.engine.closeDocument(widget.opened.sessionId);
    super.dispose();
  }

  void _resetView() {
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
      _yaw = -0.75;
      _pitch = 0.55;
    });
    unawaited(_refreshViewport());
  }

  void _onScaleStart(ScaleStartDetails details, Size size) {
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
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_isInteracting) setState(() => _isInteracting = false);
    unawaited(_refreshViewport());
  }

  Future<void> _refreshViewport() async {
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
    final padding = math.max(bounds.width, bounds.height) * 0.08;
    final request = ++_viewportRequest;
    try {
      final updated = await widget.engine.loadViewport(
        widget.opened.sessionId,
        bounds.inflate(padding),
      );
      if (!mounted || request != _viewportRequest) return;
      setState(() => _document = updated);
    } catch (_) {
      // Keep the last valid retained batch if a viewport refresh is cancelled
      // by navigation or a native session shutdown.
    }
  }

  void _scheduleViewportRefresh() {
    if (_viewportRefreshScheduled) return;
    _viewportRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportRefreshScheduled = false;
      if (mounted && !_isInteracting) unawaited(_refreshViewport());
    });
  }

  Future<void> _onTap(Offset local, Size size) async {
    if (_tool == ViewerTool.pan) return;
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
      } else if (_tool == ViewerTool.annotate) {
        if (hit != null) await _addAnnotation3D(hit);
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
      }
      return;
    }
    if (_document.sceneKind != 'two_d') return;
    final transform = CadViewTransform.forScene(_document, size, _zoom, _pan);
    final world = transform.screenToWorld(local);
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
    final updated = await widget.engine.setVisibility(
      widget.opened.sessionId,
      layer.id,
      visible,
    );
    if (mounted) {
      setState(() => _document = updated);
      await _refreshViewport();
    }
  }

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
                ),
                for (final layer in layers)
                  SwitchListTile(
                    value: layer.visible,
                    secondary: Icon(Icons.layers, color: layer.color),
                    title: Text(layer.name),
                    onChanged: (value) async {
                      await _setLayer(layer, value);
                      modalSetState(() {});
                    },
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

  void _showDiagnostics() {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final annotationsAvailable =
        DistributionConfig.fullFeatures && widget.opened.formatId != 'pdf';
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.opened.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              '${widget.opened.formatId.toUpperCase()} · ${_sceneLabel(widget.opened.sceneKind)}',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
        actions: [
          if (annotationsAvailable) ...[
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
          IconButton(
            tooltip: l10n.text('layersAssembly'),
            onPressed: _showLayers,
            icon: const Icon(Icons.layers_outlined),
          ),
          IconButton(
            tooltip: l10n.text('diagnostics'),
            onPressed: _showDiagnostics,
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: widget.opened.formatId == 'pdf'
                ? PdfDocumentViewport(path: widget.opened.sourcePath)
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
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: (details) => _onScaleStart(details, size),
                        onScaleUpdate: (details) =>
                            _onScaleUpdate(details, size),
                        onScaleEnd: _onScaleEnd,
                        onTapUp: (details) =>
                            _onTap(details.localPosition, size),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(
                                painter: CadScenePainter(
                                  document: _document,
                                  zoom: _zoom,
                                  pan: _pan,
                                  annotations: _annotations,
                                  selectedEntityId: _selectedEntityId,
                                  measurementPoints: List.of(
                                    _measurementPoints,
                                  ),
                                  yaw: _yaw,
                                  pitch: _pitch,
                                  selectedMeshId: _selectedMeshId,
                                  measurement3DPoints: List.of(
                                    _measurement3DPoints,
                                  ),
                                  interactive: _isInteracting,
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
                              top: 12,
                              child: _StatusPill(
                                text: _statusText(),
                                icon: _tool == ViewerTool.measure
                                    ? Icons.straighten
                                    : Icons.touch_app,
                              ),
                            ),
                            if (_measurement != null)
                              Positioned(
                                left: 12,
                                bottom: 12,
                                child: _StatusPill(
                                  text: _measurement!.toStringAsFixed(3),
                                  icon: Icons.straighten,
                                  accent: true,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          if (widget.opened.formatId != 'pdf')
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
                      _ToolButton(
                        icon: Icons.pan_tool_outlined,
                        label: l10n.text('browse'),
                        selected: _tool == ViewerTool.pan,
                        onTap: () => setState(() => _tool = ViewerTool.pan),
                      ),
                      if (DistributionConfig.fullFeatures)
                        _ToolButton(
                          icon: Icons.mode_comment_outlined,
                          label: l10n.text('annotate'),
                          selected: _tool == ViewerTool.annotate,
                          onTap: () =>
                              setState(() => _tool = ViewerTool.annotate),
                        ),
                      _ToolButton(
                        icon: Icons.near_me_outlined,
                        label: l10n.text('select'),
                        selected: _tool == ViewerTool.select,
                        onTap: () => setState(() => _tool = ViewerTool.select),
                      ),
                      if (DistributionConfig.fullFeatures)
                        _ToolButton(
                          icon: Icons.straighten,
                          label: l10n.text('measure'),
                          selected: _tool == ViewerTool.measure,
                          onTap: () => setState(() {
                            _tool = ViewerTool.measure;
                            _measurementPoints.clear();
                            _measurement3DPoints.clear();
                            _measurement = null;
                          }),
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
        width: 72,
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
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(
                fontSize: 10,
                height: 1,
                color: selected ? const Color(0xff53d4ff) : Colors.white54,
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
  });

  final String text;
  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: const Color(0xff53d4ff)),
            const SizedBox(width: 7),
            Text(text, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
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
