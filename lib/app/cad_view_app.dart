import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/cad_engine.dart';
import '../core/cad_fonts.dart';
import '../core/distribution.dart';
import '../core/recent_files.dart';
import '../core/ui_preferences.dart';
import '../features/home/home_page.dart';
import '../l10n/app_localizations.dart';

class CadViewApp extends StatefulWidget {
  const CadViewApp({
    required this.engine,
    this.advertising = const DisabledAdvertisingService(),
    this.recentFiles = const RecentFilesStore(),
    super.key,
  });

  final CadEngine engine;
  final AdvertisingService advertising;
  final RecentFilesStore recentFiles;

  @override
  State<CadViewApp> createState() => _CadViewAppState();
}

class _CadViewAppState extends State<CadViewApp> with WidgetsBindingObserver {
  String _localeTag = 'system';
  int _decimalPlaces = UiPreferences.defaultDecimalPlaces;
  int _preferenceRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUiPreferences();
  }

  Future<void> _loadUiPreferences() async {
    final revision = _preferenceRevision;
    final preferences = await UiPreferences.load();
    if (mounted && revision == _preferenceRevision) {
      setState(() {
        _localeTag = preferences.localeTag;
        _decimalPlaces = preferences.decimalPlaces;
      });
    }
  }

  Future<void> _setLocale(String tag) async {
    if (!UiPreferences.supportedLocaleTags.contains(tag)) return;
    _preferenceRevision++;
    setState(() => _localeTag = tag);
    await _saveUiPreferences();
  }

  Future<void> _setDecimalPlaces(int value) async {
    if (!UiPreferences.supportedDecimalPlaces.contains(value)) return;
    _preferenceRevision++;
    setState(() => _decimalPlaces = value);
    await _saveUiPreferences();
  }

  Future<void> _saveUiPreferences() async {
    try {
      await UiPreferences(
        localeTag: _localeTag,
        decimalPlaces: _decimalPlaces,
      ).save();
    } catch (_) {
      // A settings write failure must not prevent an in-memory preference change.
    }
  }

  Locale? get _locale => switch (_localeTag) {
    'en' => const Locale('en'),
    'zh-Hans' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
    ),
    'zh-Hant' => const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
    ),
    'es' || 'ja' || 'fr' || 'ko' || 'ru' => Locale(_localeTag),
    _ => null,
  };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded = state != AppLifecycleState.resumed;
    widget.engine.setApplicationBackgrounded(backgrounded);
    if (backgrounded) {
      widget.advertising.suspend();
    } else {
      widget.advertising.resume();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (_localeTag == 'system' && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xff53d4ff);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: const Color(0xff111923),
    );
    return MaterialApp(
      onGenerateTitle: (context) => context.l10n.text('appName'),
      debugShowCheckedModeBanner: false,
      locale: _locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeListResolutionCallback: (preferred, supported) =>
          AppLocalizations.resolve(preferred),
      theme: ThemeData(
        fontFamily: 'CADView Noto Sans',
        fontFamilyFallback: cadFontFallback,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xff0b1118),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          color: Color(0xff131e29),
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff0b1118),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: HomePage(
        engine: widget.engine,
        advertising: widget.advertising,
        recentFiles: widget.recentFiles,
        localeTag: _localeTag,
        onLocaleChanged: _setLocale,
        decimalPlaces: _decimalPlaces,
        onDecimalPlacesChanged: _setDecimalPlaces,
      ),
    );
  }
}
