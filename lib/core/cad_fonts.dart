import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerCadFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final path in const [
      'third_party_licenses/NotoSansCJK-OFL-1.1.txt',
      'third_party_licenses/NotoFonts-OFL-1.1.txt',
    ]) {
      yield LicenseEntryWithLineBreaks(const [
        'Noto fonts',
      ], await rootBundle.loadString(path));
    }
  });
}

/// Offline families shared by CAD labels, annotations and the application UI.
const cadFontAssets = <String, String>{
  'CADView Noto Sans': 'assets/fonts/NotoSans-Regular.ttf',
  'CADView Noto CJK': 'assets/fonts/NotoSansCJKsc-Regular.otf',
  'CADView Noto Arabic': 'assets/fonts/NotoSansArabic-Regular.ttf',
  'CADView Noto Hebrew': 'assets/fonts/NotoSansHebrew-Regular.ttf',
  'CADView Noto Thai': 'assets/fonts/NotoSansThai-Regular.ttf',
  'CADView Noto Devanagari': 'assets/fonts/NotoSansDevanagari-Regular.ttf',
  'CADView Noto Bengali': 'assets/fonts/NotoSansBengali-Regular.ttf',
  'CADView Noto Gujarati': 'assets/fonts/NotoSansGujarati-Regular.ttf',
  'CADView Noto Gurmukhi': 'assets/fonts/NotoSansGurmukhi-Regular.ttf',
  'CADView Noto Tamil': 'assets/fonts/NotoSansTamil-Regular.ttf',
  'CADView Noto Telugu': 'assets/fonts/NotoSansTelugu-Regular.ttf',
  'CADView Noto Kannada': 'assets/fonts/NotoSansKannada-Regular.ttf',
  'CADView Noto Malayalam': 'assets/fonts/NotoSansMalayalam-Regular.ttf',
  'CADView Noto Sinhala': 'assets/fonts/NotoSansSinhala-Regular.ttf',
  'CADView Noto Lao': 'assets/fonts/NotoSansLao-Regular.ttf',
  'CADView Noto Khmer': 'assets/fonts/NotoSansKhmer-Regular.ttf',
  'CADView Noto Myanmar': 'assets/fonts/NotoSansMyanmar-Regular.ttf',
  'CADView Noto Armenian': 'assets/fonts/NotoSansArmenian-Regular.ttf',
  'CADView Noto Georgian': 'assets/fonts/NotoSansGeorgian-Regular.ttf',
  'CADView Noto Ethiopic': 'assets/fonts/NotoSansEthiopic-Regular.ttf',
  'CADView Noto Tibetan': 'assets/fonts/NotoSerifTibetan-Regular.ttf',
  'CADView Noto Symbols': 'assets/fonts/NotoSansSymbols-Regular.ttf',
  'CADView Noto Symbols 2': 'assets/fonts/NotoSansSymbols2-Regular.ttf',
};

const cadDefaultFontFamily = 'CADView Noto Sans';

/// Preserve valid source families, but never depend on a platform default for
/// absent DXF/SHX font metadata. Missing source families use Flutter's fallback.
String cadPrimaryFontFamily(String? requested) {
  final family = requested?.trim();
  return family == null || family.isEmpty ? cadDefaultFontFamily : family;
}

const cadFontFallback = <String>[
  'CADView Noto Sans',
  'CADView Noto CJK',
  'CADView Noto Arabic',
  'CADView Noto Hebrew',
  'CADView Noto Thai',
  'CADView Noto Devanagari',
  'CADView Noto Bengali',
  'CADView Noto Gujarati',
  'CADView Noto Gurmukhi',
  'CADView Noto Tamil',
  'CADView Noto Telugu',
  'CADView Noto Kannada',
  'CADView Noto Malayalam',
  'CADView Noto Sinhala',
  'CADView Noto Lao',
  'CADView Noto Khmer',
  'CADView Noto Myanmar',
  'CADView Noto Armenian',
  'CADView Noto Georgian',
  'CADView Noto Ethiopic',
  'CADView Noto Tibetan',
  'CADView Noto Symbols',
  'CADView Noto Symbols 2',
];

// Choose the first strong script rather than switching an entire Latin CAD
// label to RTL just because a later annotation contains Arabic or Hebrew.
final _rtlLetter = RegExp(
  r'\p{Script=Hebrew}|\p{Script_Extensions=Arabic}|\p{Script=Syriac}|'
  r'\p{Script=Thaana}|\p{Script=Nko}|\p{Script=Samaritan}|'
  r'\p{Script=Mandaic}|\p{Script=Adlam}|\p{Script=Hanifi_Rohingya}',
  unicode: true,
);
final _letter = RegExp(r'\p{Letter}', unicode: true);

TextDirection cadTextDirection(String value) {
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    // Broad script ranges also contain digits and combining marks. Those are
    // not strong letters and must not override the following label direction.
    if (!_letter.hasMatch(character)) continue;
    if (_rtlLetter.hasMatch(character)) return TextDirection.rtl;
    return TextDirection.ltr;
  }
  return TextDirection.ltr;
}
