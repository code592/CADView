import 'package:cad_view/core/ui_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('UI preferences preserve locale and engineering precision', () {
    final preferences = UiPreferences.fromJson({
      'locale': 'fr',
      'decimal_places': 6,
    });

    expect(preferences.localeTag, 'fr');
    expect(preferences.decimalPlaces, 6);
    expect(preferences.toJson(), {'locale': 'fr', 'decimal_places': 6});
  });

  test('legacy or invalid UI preferences use safe defaults', () {
    expect(
      UiPreferences.fromJson({'locale': 'ja'}).decimalPlaces,
      UiPreferences.defaultDecimalPlaces,
    );
    final invalid = UiPreferences.fromJson({
      'locale': 'unsupported',
      'decimal_places': 9,
    });
    expect(invalid.localeTag, 'system');
    expect(invalid.decimalPlaces, UiPreferences.defaultDecimalPlaces);
  });
}
