import 'dart:convert';
import 'dart:io';

import 'native_paths.dart';

class PrivacyPreferences {
  const PrivacyPreferences({
    required this.policyAccepted,
    required this.personalizedAds,
  });

  const PrivacyPreferences.defaults()
    : policyAccepted = false,
      personalizedAds = false;

  final bool policyAccepted;
  final bool personalizedAds;

  static Future<File> _file() async {
    final directory = await NativePaths.applicationSupport();
    return File('$directory${Platform.pathSeparator}privacy_preferences.json');
  }

  static Future<PrivacyPreferences> load() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      final map = json as Map<String, dynamic>;
      return PrivacyPreferences(
        policyAccepted: map['policyAccepted'] == true,
        personalizedAds: map['personalizedAds'] == true,
      );
    } catch (_) {
      return const PrivacyPreferences.defaults();
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'policyAccepted': policyAccepted,
        'personalizedAds': personalizedAds,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
