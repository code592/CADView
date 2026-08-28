import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../../l10n/app_localizations.dart';

class PdfDocumentViewport extends StatefulWidget {
  const PdfDocumentViewport({required this.path, super.key});

  final String path;

  @override
  State<PdfDocumentViewport> createState() => _PdfDocumentViewportState();
}

class _PdfDocumentViewportState extends State<PdfDocumentViewport> {
  final TransformationController _transformation = TransformationController();
  PdfDocument? _document;
  ui.Image? _image;
  int _pageIndex = 0;
  bool _busy = true;
  String? _error;
  int _renderGeneration = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final cache = Directory('${Directory.systemTemp.path}/cadview-pdfium');
      await cache.create(recursive: true);
      await pdfrxInitialize(tmpPath: cache.path);
      final document = await PdfDocument.openFile(widget.path);
      if (!mounted) {
        await document.dispose();
        return;
      }
      _document = document;
      await _renderPage(0);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _renderPage(int index) async {
    final document = _document;
    if (document == null || index < 0 || index >= document.pages.length) return;
    final generation = ++_renderGeneration;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = document.pages[index];
      final scale = mathMin(2.25, 3000 / mathMax(page.width, page.height));
      final rendered = await page.render(
        fullWidth: page.width * scale,
        fullHeight: page.height * scale,
      );
      if (rendered == null) throw StateError('PDFium returned no page image');
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rendered.pixels,
        rendered.width,
        rendered.height,
        ui.PixelFormat.bgra8888,
        completer.complete,
        rowBytes: rendered.width * 4,
      );
      final image = await completer.future;
      rendered.dispose();
      if (!mounted || generation != _renderGeneration) {
        image.dispose();
        return;
      }
      final previous = _image;
      setState(() {
        _image = image;
        _pageIndex = index;
        _busy = false;
      });
      previous?.dispose();
      _transformation.value = Matrix4.identity();
    } catch (error) {
      if (mounted && generation == _renderGeneration) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _renderGeneration++;
    _image?.dispose();
    _document?.dispose();
    _transformation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final document = _document;
    return ColoredBox(
      color: const Color(0xff071017),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            InteractiveViewer(
              transformationController: _transformation,
              minScale: 0.2,
              maxScale: 12,
              boundaryMargin: const EdgeInsets.all(160),
              child: Center(
                child: AspectRatio(
                  aspectRatio: image.width / image.height,
                  child: RawImage(image: image, fit: BoxFit.contain),
                ),
              ),
            ),
          if (_busy) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.text('pdfRenderFailed', {'error': _error!}),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xffff7875)),
                ),
              ),
            ),
          if (document != null && document.pages.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xee111923),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: context.l10n.text('previousPage'),
                        onPressed: !_busy && _pageIndex > 0
                            ? () => _renderPage(_pageIndex - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${_pageIndex + 1} / ${document.pages.length}'),
                      IconButton(
                        tooltip: context.l10n.text('nextPage'),
                        onPressed:
                            !_busy && _pageIndex + 1 < document.pages.length
                            ? () => _renderPage(_pageIndex + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
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
}

double mathMin(double a, double b) => a < b ? a : b;
double mathMax(double a, double b) => a > b ? a : b;
