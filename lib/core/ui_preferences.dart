import 'dart:convert';
import 'dart:io';

import 'native_paths.dart';

class UiPreferences {
  const UiPreferences({this.localeTag = 'system'});

  final String localeTag;

  static const supportedLocaleTags = <String>{
    'system',
    'en',
    'zh-Hans',
    'zh-Hant',
    'es',
    'ja',
    'fr',
    'ko',
    'ru',
  };

  static Future<File> _file() async {
    final directory = await NativePaths.applicationSupport();
    return File('$directory${Platform.pathSeparator}ui_preferences.json');
  }

  static Future<UiPreferences> load() async {
    try {
      final map = jsonDecode(
        await (await _file()).readAsString(),
      ) as Map<String, dynamic>;
      final tag = map['locale'] as String? ?? 'system';
      return UiPreferences(
        localeTag: supportedLocaleTags.contains(tag) ? tag : 'system',
      );
    } catch (_) {
      return const UiPreferences();
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'locale': localeTag}),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
