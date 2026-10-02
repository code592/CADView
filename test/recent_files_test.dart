import 'dart:io';

import 'package:cad_view/core/recent_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recent files are persisted, deduplicated and bounded', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cadview_recent_files_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final storage = File('${directory.path}/recent_files.json');
    final store = RecentFilesStore(fileProvider: () async => storage);

    List<RecentFileEntry> entries = const [];
    for (var index = 0; index < 12; index++) {
      entries = await store.record(
        path: '${directory.path}/drawing_$index.dwg',
        displayName: 'Drawing $index',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(entries, hasLength(RecentFilesStore.maxEntries));
    expect(entries.first.displayName, 'Drawing 11');
    expect(entries.any((entry) => entry.displayName == 'Drawing 0'), isFalse);

    entries = await store.record(
      path: '${directory.path}/drawing_11.dwg',
      displayName: 'Renamed drawing',
    );
    expect(entries, hasLength(RecentFilesStore.maxEntries));
    expect(entries.first.displayName, 'Renamed drawing');
    expect(
      entries.where((entry) => entry.path.endsWith('drawing_11.dwg')),
      hasLength(1),
    );

    final restored = await store.load();
    expect(restored, hasLength(RecentFilesStore.maxEntries));
    expect(restored.first.displayName, 'Renamed drawing');

    final removed = await store.remove(restored.first.path);
    expect(removed, hasLength(RecentFilesStore.maxEntries - 1));
    await store.clear();
    expect(await store.load(), isEmpty);
  });

  test('malformed recent-file data is ignored safely', () async {
    final directory = await Directory.systemTemp.createTemp(
      'cadview_recent_files_invalid_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final storage = File('${directory.path}/recent_files.json');
    await storage.writeAsString('{not-json');
    final store = RecentFilesStore(fileProvider: () async => storage);

    expect(await store.load(), isEmpty);
  });
}
