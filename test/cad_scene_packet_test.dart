import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_packet.dart';
import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Independent test authoring, not a call to the production Rust encoder.
Uint8List _packet(Map<String, dynamic> document) {
  final entities =
      ((document['scene'] as Map)['scene'] as Map)['entities'] as List;
  final metadata = jsonEncode({
    ...document,
    'scene': {
      'scene_kind': 'two_d',
      'scene': {
        ...((document['scene'] as Map)['scene'] as Map),
        'entities': [],
      },
    },
  });
  final metadataBytes = utf8.encode(metadata);
  final records = BytesBuilder();
  final styles = BytesBuilder();
  final coordinates = BytesBuilder();
  final dashes = BytesBuilder();
  final text = BytesBuilder();
  void u32(BytesBuilder out, int value) => out.add(
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List(),
  );
  void u64(BytesBuilder out, int value) => out.add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void f64(BytesBuilder out, num value) => out.add(
    (ByteData(
      8,
    )..setFloat64(0, value.toDouble(), Endian.little)).buffer.asUint8List(),
  );
  for (var i = 0; i < entities.length; i++) {
    final e = entities[i] as Map;
    final geometry = e['geometry'] as Map;
    final kind = const [
      'text',
      'point',
      'line',
      'polyline',
      'circle',
      'arc',
    ].indexOf(geometry['kind']);
    var start = coordinates.length ~/ 8;
    final values = <num>[];
    void point(String key) {
      final p = geometry[key] as Map;
      values.addAll([p['x'] as num, p['y'] as num]);
    }

    if (kind == 1) point('position');
    if (kind == 2) {
      point('start');
      point('end');
    }
    if (kind == 3) {
      for (final p in geometry['points'] as List) {
        values.addAll([(p as Map)['x'] as num, p['y'] as num]);
      }
    }
    if (kind >= 4) {
      point('center');
      values.add(geometry['radius'] as num);
    }
    if (kind == 5) {
      values.addAll([
        geometry['start_angle'] as num,
        geometry['end_angle'] as num,
      ]);
    }
    var length = values.length;
    if (kind == 0) {
      start = text.length;
      final json = utf8.encode(jsonEncode(e));
      length = json.length;
      text.add(json);
    }
    for (final value in values) {
      f64(coordinates, value);
    }
    u64(records, e['id'] as int);
    u64(records, e['layer_id'] as int);
    u32(records, i);
    u32(records, kind | (geometry['closed'] == true ? 256 : 0));
    u32(records, start);
    u32(records, length);
    u32(styles, e['color_argb'] as int);
    u32(styles, e['filled'] == true ? 1 : 0);
    f64(styles, e['stroke_width'] as num);
    u32(styles, dashes.length ~/ 8);
    final pattern = e['dash'] as List? ?? const [];
    u32(styles, pattern.length);
    for (final value in pattern) {
      f64(dashes, value as num);
    }
  }
  final out = BytesBuilder()..add(ascii.encode('CAD2D001'));
  for (final n in [
    metadataBytes.length,
    entities.length,
    coordinates.length ~/ 8,
    entities.length,
    dashes.length ~/ 8,
    text.length,
  ]) {
    u32(out, n);
  }
  out.add(metadataBytes);
  while (out.length % 8 != 0) {
    out.addByte(0);
  }
  out.add(records.takeBytes());
  out.add(styles.takeBytes());
  out.add(coordinates.takeBytes());
  out.add(dashes.takeBytes());
  out.add(text.takeBytes());
  return out.takeBytes();
}

Map<String, dynamic> _drawing() => {
  'metadata': {
    'format': 'dxf',
    'display_name': '完整图纸',
    'units': 'millimeters',
    'frames': [],
  },
  'diagnostics': [],
  'scene': {
    'scene_kind': 'two_d',
    'scene': {
      'bounds': {
        'min': {'x': 1e12, 'y': 1e12},
        'max': {'x': 1e12 + 100, 'y': 1e12 + 100},
      },
      'layers': [
        {'id': 4, 'name': '图层', 'visible': true, 'color_argb': 0xff73dfff},
      ],
      'entities': [
        for (final entry in [
          {
            'kind': 'point',
            'position': {'x': 1e12 + 5, 'y': 1e12 + 5},
          },
          {
            'kind': 'line',
            'start': {'x': 1e12 + 0.125, 'y': 1e12 + 15},
            'end': {'x': 1e12 + 90.125, 'y': 1e12 + 15},
          },
          {
            'kind': 'polyline',
            'closed': true,
            'points': [
              {'x': 1e12 + 20, 'y': 1e12 + 20},
              {'x': 1e12 + 40, 'y': 1e12 + 20},
              {'x': 1e12 + 30, 'y': 1e12 + 35},
            ],
          },
          {
            'kind': 'text',
            'origin': {'x': 1e12 + 20, 'y': 1e12 + 30},
            'value': '中文 ⌀42',
            'height': 4.0,
            'rotation': 0.0,
            'width_factor': 1.0,
            'background': {
              'layout_supported': true,
              'fill': true,
              'frame': true,
              'scale': 1.5,
              'color_mode': 'canvas',
              'color_argb': 0xff071017,
              'transparency': 0,
            },
            'shx': {'font': 'txt.shx'},
            'text_runs': [],
            'text_warnings': ['source-warning'],
          },
          {
            'kind': 'circle',
            'center': {'x': 1e12 + 55, 'y': 1e12 + 55},
            'radius': 12.5,
          },
          {
            'kind': 'arc',
            'center': {'x': 1e12 + 70, 'y': 1e12 + 70},
            'radius': 20.0,
            'start_angle': 0.125,
            'end_angle': 2.5,
          },
          {'kind': 'polyline', 'closed': false, 'points': []},
        ].asMap().entries)
          {
            'id': entry.key + 1,
            'layer_id': 4,
            'color_argb': 0xff73dfff,
            'stroke_width': entry.key == 2 ? 1.25 : 0.0,
            'filled': entry.key == 2,
            if (entry.key == 1) 'dash': [4.0, -2.0, 0.0],
            'geometry': entry.value,
          },
      ],
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'packed view preserves all geometry, styles, metadata and rich text',
    () {
      final source = _drawing();
      final model = CadDocumentModel.fromJson(
        decodeCadScenePacket(_packet(source)),
      );
      expect(model.entities, isA<CadPackedEntities>());
      expect(
        jsonDecode(jsonEncode(model.entities)),
        ((source['scene'] as Map)['scene'] as Map)['entities'],
      );
      expect(model.displayName, '完整图纸');
      expect(model.entities[1]['geometry']['start']['x'], 1e12 + 0.125);
      expect(model.entities.sublist(1, 4), isA<CadPackedEntities>());
      expect(model.entities.sublist(1, 4).map((e) => e['id']), [2, 3, 4]);
      expect(() => model.entities[0]['id'] = 7, throwsUnsupportedError);
    },
  );
  test(
    'packet ranges/version/flags are validated and sliced input is supported',
    () {
      final original = _packet(_drawing());
      for (final bad in [
        Uint8List(10),
        original.sublist(0, original.length - 1),
        [...original, 0],
      ]) {
        expect(
          () => decodeCadScenePacket(Uint8List.fromList(bad)),
          throwsFormatException,
        );
      }
      final invalid = Uint8List.fromList(original);
      ByteData.sublistView(invalid).setUint32(8, 0xffffffff, Endian.little);
      expect(() => decodeCadScenePacket(invalid), throwsFormatException);
      final prefix = Uint8List.fromList([0, 0, 0, ...original]);
      expect(
        CadDocumentModel.fromJson(
          decodeCadScenePacket(Uint8List.sublistView(prefix, 3)),
        ).entities.length,
        7,
      );
      final badKind = Uint8List.fromList(original);
      final data = ByteData.sublistView(badKind);
      final records = ((32 + data.getUint32(8, Endian.little) + 7) ~/ 8) * 8;
      data.setUint32(records + 20, 255, Endian.little);
      expect(() => decodeCadScenePacket(badKind), throwsFormatException);
    },
  );
  test(
    'sparse, duplicate and unsorted IDs retain exact source occurrences',
    () {
      for (final ids in [
        [10, 11, 11, 300, 300, 9007199254740993, 9007199254740994],
        [300, 11, 10, 300, 11, 9007199254740994, 9007199254740993],
      ]) {
        final source = _drawing();
        final entities =
            ((source['scene'] as Map)['scene'] as Map)['entities'] as List;
        for (var i = 0; i < ids.length; i++) {
          entities[i]['id'] = ids[i];
        }
        final model = CadDocumentModel.fromJson(
          decodeCadScenePacket(_packet(source)),
        );
        final packed = model.entities as CadPackedEntities;
        for (final id in [...ids, 12, 9007199254740995]) {
          expect(packed.indexOfId(id), ids.indexOf(id));
          expect(
            model.entityById(id),
            ids.contains(id) ? packed[ids.indexOf(id)] : null,
          );
        }
        expect((packed.indicesOfIds({11, 300}).toList()..sort()), [
          for (var i = 0; i < ids.length; i++)
            if ({11, 300}.contains(ids[i])) i,
        ]);
        final slice = packed.sublist(1, 6);
        for (final id in ids) {
          expect(slice.indexOfId(id), ids.sublist(1, 6).indexOf(id));
        }
        expect(packed.indicesOfIds({12}), isEmpty);
      }
    },
  );
  test('packed and legacy rendering have identical pixels, including masks and selection', () async {
    final source = _drawing();
    final entities =
        ((source['scene'] as Map)['scene'] as Map)['entities'] as List;
    // Solid-line fast path on both sides of a text-mask barrier, with shared
    // styles, negative widths, filled flags and an invisible layer.
    for (var i = 0; i < 4; i++) {
      entities.insert(i == 0 ? 1 : entities.length, {
        'id': 90 + i,
        'layer_id': i == 3 ? 99 : 4,
        'color_argb': 0xff73dfff,
        'stroke_width': i == 2 ? -1.25 : 0.0,
        'filled': i == 2,
        'geometry': {
          'kind': 'line',
          'start': {'x': 1e12 + 0.125, 'y': 1e12 + 30 + i},
          'end': {'x': 1e12 + 90.125, 'y': 1e12 + 30 + i},
        },
      });
    }
    (((source['scene'] as Map)['scene'] as Map)['layers'] as List).add({
      'id': 99,
      'name': 'Hidden',
      'visible': false,
      'color_argb': 0xff73dfff,
    });
    final old = CadDocumentModel.fromJson(source);
    final packed = CadDocumentModel.fromJson(
      decodeCadScenePacket(_packet(source)),
    );
    Future<Uint8List> render(CadDocumentModel model, double zoom) async {
      final recorder = ui.PictureRecorder();
      CadScenePainter(
        document: model,
        zoom: zoom,
        pan: const Offset(10, -12),
        showGrid: false,
        selectedEntityIds: {BigInt.two, BigInt.from(5), BigInt.from(90)},
      ).paint(Canvas(recorder), const Size(500, 400));
      final picture = recorder.endRecording();
      CadScenePainter.releaseDocument(model);
      CadScenePainter.releaseDocument(model);
      final image = await picture.toImage(500, 400);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    }

    for (final zoom in [1.0, 2.5]) {
      expect(await render(packed, zoom), await render(old, zoom));
    }
    // All duplicate source occurrences must highlight, not just the first.
    entities.last['id'] = 90;
    entities.last['layer_id'] = 4;
    expect(
      await render(
        CadDocumentModel.fromJson(decodeCadScenePacket(_packet(source))),
        2.5,
      ),
      await render(CadDocumentModel.fromJson(source), 2.5),
    );
    entities.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    expect(
      await render(
        CadDocumentModel.fromJson(decodeCadScenePacket(_packet(source))),
        2.5,
      ),
      await render(CadDocumentModel.fromJson(source), 2.5),
    );
  });

  test('documents prepared between frames paint the same pixels', () async {
    final source = _drawing();
    final entities =
        ((source['scene'] as Map)['scene'] as Map)['entities'] as List;
    // Enough entities for several slices, dashed lines among them.
    for (var i = 0; i < 400; i++) {
      entities.add({
        'id': 1000 + i,
        'layer_id': 4,
        'color_argb': 0xff73dfff - i,
        'stroke_width': 0.0,
        'filled': false,
        if (i.isEven) 'dash': [2.0, -1.0],
        'geometry': i % 3 == 0
            ? {
                'kind': 'arc',
                'center': {'x': 1e12 + i * 0.25, 'y': 1e12 + 40},
                'radius': 3.5,
                'start_angle': 0.25,
                'end_angle': 2.5,
              }
            : {
                'kind': 'polyline',
                'closed': i % 3 == 1,
                'points': [
                  {'x': 1e12 + i * 0.25, 'y': 1e12 + 10},
                  {'x': 1e12 + i * 0.25 + 4, 'y': 1e12 + 16},
                  {'x': 1e12 + i * 0.25 + 1, 'y': 1e12 + 22},
                ],
              },
      });
    }
    Future<Uint8List> render(CadDocumentModel model, double zoom) async {
      final recorder = ui.PictureRecorder();
      CadScenePainter(
        document: model,
        zoom: zoom,
        pan: const Offset(10, -12),
        showGrid: false,
      ).paint(Canvas(recorder), const Size(500, 400));
      final picture = recorder.endRecording();
      final image = await picture.toImage(500, 400);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    }

    for (final legacy in [false, true]) {
      CadDocumentModel decode() => CadDocumentModel.fromJson(
        legacy ? source : decodeCadScenePacket(_packet(source)),
      );
      final prepared = decode();
      var turns = 0;
      var preparing = true;
      void tick() {
        turns++;
        if (preparing) Timer(Duration.zero, tick);
      }

      Timer(Duration.zero, tick);
      await CadScenePainter.prepareDocument(
        prepared,
        sliceBudget: Duration.zero,
      );
      preparing = false;
      // Every exhausted slice handed the event loop back.
      expect(turns, greaterThan(3));
      final direct = decode();
      for (final zoom in [1.0, 2.5, 40.0]) {
        expect(await render(prepared, zoom), await render(direct, zoom));
      }
      CadScenePainter.releaseDocument(prepared);
      CadScenePainter.releaseDocument(direct);
    }
  });

  test(
    'labels too small to read are drawn as strokes along the label',
    () async {
      CadDocumentModel label(double height) => CadDocumentModel.fromJson({
        'diagnostics': <Object>[],
        'metadata': {'format': 'dxf', 'display_name': 'label.dxf'},
        'scene': {
          'scene_kind': 'two_d',
          'scene': {
            'layers': [
              {'id': 1, 'name': '0', 'visible': true, 'color_argb': 0xffffffff},
            ],
            'bounds': {
              'min': {'x': 0.0, 'y': 0.0},
              'max': {'x': 1000.0, 'y': 1000.0},
            },
            'entities': [
              {
                'id': 1,
                'layer_id': 1,
                'color_argb': 0xffff0000,
                'stroke_width': 0.0,
                'filled': false,
                'geometry': {
                  'kind': 'text',
                  'origin': {'x': 400.0, 'y': 500.0},
                  'value': 'WWWWWWWWWW',
                  'height': height,
                  'height_reference': 'cap_height',
                  'rotation': 0.0,
                  'width_factor': 1.0,
                  'oblique_angle': 0.0,
                  'horizontal_alignment': 'left',
                  'vertical_alignment': 'baseline',
                },
              },
            ],
          },
        },
      });
      // Rows of the 500 × 500 image that contain red ink.
      Future<Set<int>> inkRows(CadDocumentModel document) async {
        final recorder = ui.PictureRecorder();
        CadScenePainter(
          document: document,
          zoom: 1 / 0.88,
          pan: Offset.zero,
          showGrid: false,
        ).paint(Canvas(recorder), const Size(500, 500));
        final picture = recorder.endRecording();
        final image = await picture.toImage(500, 500);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        image.dispose();
        picture.dispose();
        return {
          for (var i = 0; i < pixels.length; i += 4)
            if (pixels[i] > 60 && pixels[i] > pixels[i + 1] * 2) i ~/ 4 ~/ 500,
        };
      }

      // 0.5 drawing units per pixel: 2 units tall is 1 px, 20 units is 10 px.
      final tiny = await inkRows(label(2));
      final readable = await inkRows(label(20));
      expect(tiny, isNotEmpty);
      expect(tiny.length, lessThanOrEqualTo(3));
      expect(readable.length, greaterThan(6));
    },
  );

  test('path cells skip off-screen geometry without changing pixels', () async {
    final source = _drawing();
    final entities =
        ((source['scene'] as Map)['scene'] as Map)['entities'] as List;
    // Crossing strokes of several colors spanning many cells.
    for (var i = 0; i < 600; i++) {
      final x = 1e12 + (i * 37) % 300 - 100;
      final y = 1e12 + (i * 53) % 200 - 60;
      entities.add({
        'id': 2000 + i,
        'layer_id': 4,
        'color_argb': [0xffff4040, 0xff40ff40, 0xff4040ff][i % 3],
        'stroke_width': i % 7 == 0 ? 1.5 : 0.0,
        'filled': false,
        if (i % 5 == 0) 'dash': [3.0, -2.0],
        'geometry': switch (i % 3) {
          0 => {
            'kind': 'line',
            'start': {'x': x, 'y': y},
            'end': {'x': x + 90, 'y': y + 40},
          },
          1 => {
            'kind': 'circle',
            'center': {'x': x, 'y': y},
            'radius': 12.0,
          },
          _ => {
            'kind': 'polyline',
            'closed': false,
            'points': [
              {'x': x, 'y': y},
              {'x': x - 50, 'y': y + 70},
              {'x': x + 20, 'y': y + 90},
            ],
          },
        },
      });
    }
    Future<Uint8List> render(
      CadDocumentModel model,
      double zoom,
      Offset pan,
    ) async {
      final recorder = ui.PictureRecorder();
      CadScenePainter(
        document: model,
        zoom: zoom,
        pan: pan,
        showGrid: false,
      ).paint(Canvas(recorder), const Size(400, 300));
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 300);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      return bytes;
    }

    try {
      for (final legacy in [false, true]) {
        CadDocumentModel decode() => CadDocumentModel.fromJson(
          legacy ? source : decodeCadScenePacket(_packet(source)),
        );
        for (final (zoom, pan) in [
          (1.0, Offset.zero),
          (4.0, const Offset(300, -150)),
          (12.0, const Offset(-900, 400)),
        ]) {
          CadScenePainter.debugChunkGrid = 8;
          final cells = await render(decode(), zoom, pan);
          CadScenePainter.debugDrawAllCells = true;
          final unculled = await render(decode(), zoom, pan);
          CadScenePainter.debugDrawAllCells = false;
          // Skipping off-screen cells never changes a pixel.
          expect(cells, unculled, reason: 'legacy $legacy zoom $zoom');
          // Splitting paths only changes how overlapping edges are
          // antialiased: all ink stays where single paths put it.
          CadScenePainter.debugChunkGrid = 1;
          final whole = await render(decode(), zoom, pan);
          expect(
            _inkNear(cells, whole),
            greaterThan(0.99),
            reason: 'legacy $legacy zoom $zoom',
          );
          expect(
            _inkNear(whole, cells),
            greaterThan(0.99),
            reason: 'legacy $legacy zoom $zoom',
          );
        }
      }
    } finally {
      CadScenePainter.debugChunkGrid = null;
      CadScenePainter.debugDrawAllCells = false;
    }
  });
}

/// Fraction of [image]'s bright pixels (400 × 300 RGBA) that have a bright
/// pixel in [reference] within one pixel.
double _inkNear(Uint8List image, Uint8List reference) {
  bool bright(Uint8List pixels, int x, int y) {
    if (x < 0 || y < 0 || x >= 400 || y >= 300) return false;
    final at = (y * 400 + x) * 4;
    return pixels[at] > 100 || pixels[at + 1] > 100 || pixels[at + 2] > 100;
  }

  var ink = 0, near = 0;
  for (var y = 0; y < 300; y++) {
    for (var x = 0; x < 400; x++) {
      if (!bright(image, x, y)) continue;
      ink++;
      search:
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (bright(reference, x + dx, y + dy)) {
            near++;
            break search;
          }
        }
      }
    }
  }
  return near / ink;
}
