import 'dart:convert';
import 'dart:io';

import 'native_paths.dart';

class UiPreferences {
  const UiPreferences({
    this.localeTag = 'system',
    this.decimalPlaces = defaultDecimalPlaces,
  });

  final String localeTag;
  final int decimalPlaces;

  static const defaultDecimalPlaces = 3;
  static const supportedDecimalPlaces = <int>{0, 1, 2, 3, 4, 5, 6};

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
      return UiPreferences.fromJson(map);
    } catch (_) {
      return const UiPreferences();
    }
  }

  factory UiPreferences.fromJson(Map<String, dynamic> map) {
    final tag = map['locale'] as String? ?? 'system';
    final precision = map['decimal_places'];
    return UiPreferences(
      localeTag: supportedLocaleTags.contains(tag) ? tag : 'system',
      decimalPlaces:
          precision is int && supportedDecimalPlaces.contains(precision)
          ? precision
          : defaultDecimalPlaces,
    );
  }

  Map<String, Object> toJson() => {
    'locale': localeTag,
    'decimal_places': decimalPlaces,
  };

  Future<void> save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
