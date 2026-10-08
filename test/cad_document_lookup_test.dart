import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cad_view/features/viewer/cad_document_model.dart';
import 'package:cad_view/features/viewer/cad_scene_packet.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountedEntities extends ListBase<Map<String, dynamic>> {
  _CountedEntities(this.count, this.idAt);
  final int count;
  final int Function(int) idAt;
  var reads = 0;
  @override
  int get length => count;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  Map<String, dynamic> operator [](int index) {
    RangeError.checkValidIndex(index, this);
    reads++;
    return {'id': idAt(index), 'source_index': index};
  }

  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      throw UnsupportedError('read only');
}

CadDocumentModel _document(List<Map<String, dynamic>> entities) =>
    CadDocumentModel(
      format: 'dxf',
      displayName: 'lookup',
      sceneKind: 'two_d',
      diagnostics: [],
      scene: {'layers': [], 'entities': entities},
    );

CadPackedEntities _millionSparseEntities() {
  const count = 1000000;
  final metadata = utf8.encode(
    jsonEncode({
      'metadata': {'format': 'dxf', 'display_name': 'sparse'},
      'diagnostics': [],
      'scene': {
        'scene_kind': 'two_d',
        'scene': {'entities': [], 'layers': []},
      },
    }),
  );
  final records = ((32 + metadata.length + 7) ~/ 8) * 8;
  final styles = records + count * 32;
  final coordinates = styles + 24;
  final bytes = Uint8List(coordinates + 32)
    ..setRange(0, 8, ascii.encode('CAD2D001'))
    ..setRange(32, 32 + metadata.length, metadata);
  final data = ByteData.sublistView(bytes);
  for (final (offset, value) in [
    (8, metadata.length),
    (12, count),
    (16, 4),
    (20, 1),
  ]) {
    data.setUint32(offset, value, Endian.little);
  }
  for (var i = 0; i < count; i++) {
    final offset = records + i * 32;
    data.setUint64(offset, 5001 + i * 2, Endian.little);
    data.setUint32(offset + 20, 2, Endian.little);
    data.setUint32(offset + 28, 4, Endian.little);
  }
  data.setUint32(styles, 0xff73dfff, Endian.little);
  data.setFloat64(coordinates + 16, 1, Endian.little);
  data.setFloat64(coordinates + 24, 1, Endian.little);
  return CadDocumentModel.fromJson(decodeCadScenePacket(bytes)).entities
      as CadPackedEntities;
}

void main() {
  test('million sparse packed IDs select exact ranges without a map index', () {
    final entities = _millionSparseEntities();
    final document = _document(entities);
    for (final index in [0, 1, 500000, 999999]) {
      final id = 5001 + index * 2;
      expect(entities.indexOfId(id), index);
      expect(document.entityById(id)!['id'], id);
      expect(entities.indexOfId(id + 1), -1);
      expect(document.entityById(id + 1), isNull);
    }
    final selected = {5001, 1005001, 2004999, 2005000};
    expect((entities.indicesOfIds(selected).toList()..sort()), [
      0,
      500000,
      999999,
    ]);
    final tail = entities.sublist(999990);
    expect(tail.indexOfId(2004999), 9);
    expect(tail.indicesOfIds(selected), [9]);
  });
  test('million-entity measurement lookup does not scan sequential IDs', () {
    final entities = _CountedEntities(1000000, (index) => index + 5001);
    final document = _document(entities);
    final last = document.entityById(1005000)!;
    expect(last['source_index'], 999999);
    expect(entities.reads, lessThanOrEqualTo(3));
    final reads = entities.reads;
    expect(document.entityById(1005000), same(last));
    expect(entities.reads, reads);
  });

  test(
    'sparse and block-expanded IDs verify guesses and cache exact misses',
    () {
      const ids = [10, 100, 12, 300, 11];
      final entities = _CountedEntities(ids.length, (index) => ids[index]);
      final document = _document(entities);
      expect(document.entityById(11)!['source_index'], 4);
      expect(document.entityById(100)!['source_index'], 1);
      expect(document.entityById(12)!['source_index'], 2);
      expect(document.entityById(99), isNull);
      final reads = entities.reads;
      expect(document.entityById(99), isNull);
      expect(entities.reads, reads);
      final newViewport = _document([
        {'id': 99},
      ]);
      expect(newViewport.entityById(99)!['id'], 99);
    },
  );

  test(
    'lookup cache remains bounded rather than indexing the complete scene',
    () {
      final entities = _CountedEntities(200, (index) => index + 1);
      final document = _document(entities);
      for (var id = 1; id <= 200; id++) {
        expect(document.entityById(id)!['id'], id);
      }
      final reads = entities.reads;
      document.entityById(1);
      expect(entities.reads, greaterThan(reads));
      final retainedReads = entities.reads;
      document.entityById(200);
      expect(entities.reads, retainedReads);
    },
  );
}
