import 'dart:convert';
import 'dart:io';

import 'native_paths.dart';
import 'document_name.dart';

class RecentFileEntry {
  const RecentFileEntry({
    required this.path,
    required this.displayName,
    required this.openedAtEpochMs,
  });

  factory RecentFileEntry.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final displayName = json['displayName'];
    final openedAtEpochMs = json['openedAtEpochMs'];
    if (path is! String ||
        path.isEmpty ||
        displayName is! String ||
        displayName.isEmpty ||
        openedAtEpochMs is! int) {
      throw const FormatException('Invalid recent-file entry');
    }
    return RecentFileEntry(
      path: path,
      displayName: documentDisplayName(path, displayName),
      openedAtEpochMs: openedAtEpochMs,
    );
  }

  final String path;
  final String displayName;
  final int openedAtEpochMs;

  Map<String, Object> toJson() => {
    'path': path,
    'displayName': displayName,
    'openedAtEpochMs': openedAtEpochMs,
  };
}

class RecentFilesStore {
  const RecentFilesStore({this.fileProvider});

  static const maxEntries = 10;
  static const _schemaVersion = 1;

  final Future<File> Function()? fileProvider;

  Future<File> _file() async {
    final provider = fileProvider;
    if (provider != null) return provider();
    final directory = await NativePaths.applicationSupport();
    return File('$directory${Platform.pathSeparator}recent_files.json');
  }

  Future<List<RecentFileEntry>> load() async {
    try {
      final decoded = jsonDecode(await (await _file()).readAsString());
      final envelope = decoded as Map<String, dynamic>;
      if (envelope['schemaVersion'] != _schemaVersion) return const [];
      final entries = (envelope['entries'] as List<dynamic>)
          .map(
            (value) => RecentFileEntry.fromJson(value as Map<String, dynamic>),
          )
          .toList(growable: false);
      entries.sort(
        (first, second) =>
            second.openedAtEpochMs.compareTo(first.openedAtEpochMs),
      );
      return entries.take(maxEntries).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<RecentFileEntry>> record({
    required String path,
    required String displayName,
  }) async {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return load();
    final normalizedName = displayName.trim().isEmpty
        ? File(normalizedPath).uri.pathSegments.last
        : displayName.trim();
    final current = await load();
    final updated = <RecentFileEntry>[
      RecentFileEntry(
        path: normalizedPath,
        displayName: normalizedName,
        openedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      ),
      for (final entry in current)
        if (entry.path != normalizedPath) entry,
    ].take(maxEntries).toList(growable: false);
    await _save(updated);
    return updated;
  }

  Future<List<RecentFileEntry>> remove(String path) async {
    final updated = (await load())
        .where((entry) => entry.path != path)
        .toList(growable: false);
    await _save(updated);
    return updated;
  }

  Future<void> clear() => _save(const []);

  Future<void> _save(List<RecentFileEntry> entries) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'schemaVersion': _schemaVersion,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
