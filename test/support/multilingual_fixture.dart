import 'package:cad_view/features/viewer/cad_document_model.dart';

const multilingualSamples = <String, String>{
  'Latin / Cyrillic / Greek': 'Español français Русский Ελληνικά tiếng Việt',
  'Chinese': '简体图纸 繁體圖紙 尺寸測量',
  'Japanese': '日本語 図面の寸法を測定',
  'Korean': '한국어 도면 치수 측정',
  'Arabic / Persian': 'العَرَبِيَّة فارسی اندازه',
  'Hebrew': 'עברית מדידת מידות',
  'Thai': 'ภาษาไทย การวัดขนาด',
  'Devanagari': 'हिन्दी आयाम मापन',
  'CAD / engineering': '⌀ ∅ ± ° − π ∫ ² ³ ⁴ A₁ A₂ Aₘ 1:∞',
  'Combining accents': 'e\u0301 a\u0308 n\u0303 й',
  'Mixed LTR': 'CAD 120 العَرَبِيَّة',
  'Mixed RTL': 'العَرَبِيَّة CAD 120',
};

// Exercise additional modern scripts without relying on fonts installed on the
// developer's computer or on a particular Android/iOS release.
const extendedMultilingualSamples = <String, String>{
  'Bengali / Gujarati / Gurmukhi': 'বাংলা মাত্রা ગુજરાતી પરિમાણ ਪੰਜਾਬੀ ਮਾਪ',
  'Tamil / Telugu / Kannada': 'தமிழ் அளவு తెలుగు పరిమాణం ಕನ್ನಡ ಅಳತೆ',
  'Malayalam / Sinhala': 'മലയാളം അളവ് සිංහල මිනුම්',
  'Lao / Khmer': 'ພາສາລາວ ຂະໜາດ ភាសាខ្មែរ ទំហំ',
  'Myanmar': 'မြန်မာဘာသာ အတိုင်းအတာ',
  'Armenian / Georgian': 'Հայերեն չափում ქართული ზომა',
  'Ethiopic': 'አማርኛ መጠን',
  'Tibetan': 'བོད་ཡིག ཚད་',
};

CadDocumentModel multilingualCadDocument({
  String? fontFamily,
  Map<String, String> samples = multilingualSamples,
}) => CadDocumentModel.fromJson({
  'diagnostics': <Object>[],
  'metadata': {'format': 'dxf', 'display_name': 'multilingual.dxf'},
  'scene': {
    'scene_kind': 'two_d',
    'scene': {
      'layers': [
        {'id': 1, 'name': 'Text', 'visible': true, 'color_argb': 0xffffffff},
      ],
      'bounds': {
        'min': {'x': 0, 'y': 0},
        'max': {'x': 900, 'y': 1100},
      },
      'entities': [
        for (var i = 0; i < samples.length; i++)
          {
            'id': i + 1,
            'layer_id': 1,
            'color_argb': 0xffffffff,
            'geometry': {
              'kind': 'text',
              'origin': {'x': 20, 'y': 1020 - i * 80},
              'value': samples.values.elementAt(i),
              'height': 28,
              'rotation': 0,
              'font_family': fontFamily,
            },
          },
      ],
    },
  },
});
