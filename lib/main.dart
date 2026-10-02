import 'package:flutter/material.dart';

import 'app/cad_view_app.dart';
import 'core/cad_engine.dart';
import 'core/cad_fonts.dart';
import 'core/cad_font_metrics.dart';
import 'core/native_store_advertising.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerCadFontLicenses();
  await loadCadFontMetrics();
  await RustLib.init();
  runApp(
    CadViewApp(
      engine: NativeCadEngine(),
      advertising: advertisingForDistribution(),
    ),
  );
}
