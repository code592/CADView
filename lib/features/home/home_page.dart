import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/cad_engine.dart';
import '../../core/cad_file_types.dart';
import '../../core/distribution.dart';
import '../../core/incoming_documents.dart';
import '../../core/native_document_picker.dart';
import '../../core/native_paths.dart';
import '../../core/privacy_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../viewer/cad_viewer_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    required this.engine,
    required this.advertising,
    required this.localeTag,
    required this.onLocaleChanged,
    super.key,
  });

  final CadEngine engine;
  final AdvertisingService advertising;
  final String localeTag;
  final Future<void> Function(String tag) onLocaleChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  StreamSubscription<String>? _incomingFilesSubscription;
  final List<String> _incomingFiles = [];
  late final Future<List<String>> _allowedExtensions;
  Completer<void>? _resumeCompleter;
  bool _applicationResumed = false;
  bool _drainingIncomingFiles = false;
  bool _opening = false;
  double _openProgress = 0;
  String _openStage = 'preparing';
  String? _error;
  PrivacyPreferences _privacy = const PrivacyPreferences.defaults();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _applicationResumed =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _allowedExtensions = widget.engine.supportedFormats().then(
      availableCadExtensions,
    );
    _incomingFilesSubscription = IncomingDocuments.files.listen(
      _enqueueIncomingFile,
    );
    unawaited(IncomingDocuments.initialize());
    if (widget.advertising.available) unawaited(_restorePrivacy());
  }

  void _enqueueIncomingFile(String path) {
    if (_incomingFiles.contains(path)) return;
    _incomingFiles.add(path);
    unawaited(_drainIncomingFiles());
  }

  Future<void> _drainIncomingFiles() async {
    if (_drainingIncomingFiles) return;
    _drainingIncomingFiles = true;
    try {
      while (mounted && _incomingFiles.isNotEmpty) {
        await _waitUntilResumed();
        if (!mounted) return;
        await _openDocumentPath(_incomingFiles.removeAt(0));
      }
    } finally {
      _drainingIncomingFiles = false;
    }
  }

  Future<void> _restorePrivacy() async {
    final privacy = await PrivacyPreferences.load();
    if (!mounted) return;
    setState(() => _privacy = privacy);
    if (!privacy.policyAccepted) return;
    try {
      await widget.advertising.setPersonalization(
        privacy.personalizedAds
            ? AdPersonalization.personalized
            : AdPersonalization.nonPersonalized,
      );
      await widget.advertising.initializeAfterPrivacyConsent();
    } catch (_) {
      // Advertising is optional and always collapses on provider failure.
    }
  }

  Future<void> _showSettings() async {
    final selection = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final l10n = context.l10n;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: Text(
                  l10n.text('settings'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.language),
                title: Text(l10n.text('language')),
              ),
              RadioGroup<String>(
                groupValue: widget.localeTag,
                onChanged: (value) => Navigator.pop(context, value),
                child: Column(
                  children: [
                    for (final option in _languageOptions(l10n))
                      RadioListTile<String>(
                        value: option.$1,
                        title: Text(option.$2),
                      ),
                  ],
                ),
              ),
              if (widget.advertising.available) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: Text(l10n.text('privacyAndAds')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, '__privacy__'),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (!mounted || selection == null) return;
    if (selection == '__privacy__') {
      await _showPrivacySettings();
    } else {
      await widget.onLocaleChanged(selection);
    }
  }

  List<(String, String)> _languageOptions(AppLocalizations l10n) => [
    ('system', l10n.text('languageSystem')),
    ('en', l10n.text('languageEnglish')),
    ('zh-Hans', l10n.text('languageSimplifiedChinese')),
    ('zh-Hant', l10n.text('languageTraditionalChinese')),
    ('es', l10n.text('languageSpanish')),
    ('ja', l10n.text('languageJapanese')),
    ('fr', l10n.text('languageFrench')),
    ('ko', l10n.text('languageKorean')),
    ('ru', l10n.text('languageRussian')),
  ];

  Future<void> _showPrivacySettings() async {
    var accepted = _privacy.policyAccepted;
    var personalized = _privacy.personalizedAds;
    final updated = await showDialog<PrivacyPreferences>(
      context: context,
      builder: (context) {
        final l10n = context.l10n;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l10n.text('privacyAndAds')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.text('privacyDescription')),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: accepted,
                    title: Text(l10n.text('privacyAccept')),
                    onChanged: (value) => setDialogState(() {
                      accepted = value == true;
                      if (!accepted) personalized = false;
                    }),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: accepted && personalized,
                    title: Text(l10n.text('personalizedAds')),
                    subtitle: Text(l10n.text('nonPersonalizedAdsHint')),
                    onChanged: accepted
                        ? (value) => setDialogState(() => personalized = value)
                        : null,
                  ),
                ],
              ),
            ),
            actions: [
              if (_privacy.policyAccepted)
                TextButton(
                  onPressed: () async {
                    try {
                      await widget.advertising.showPrivacyOptions();
                    } catch (_) {}
                  },
                  child: Text(l10n.text('providerPrivacyOptions')),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.text('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  PrivacyPreferences(
                    policyAccepted: accepted,
                    personalizedAds: accepted && personalized,
                  ),
                ),
                child: Text(l10n.text('save')),
              ),
            ],
          ),
        );
      },
    );
    if (updated == null) return;
    await updated.save();
    if (!mounted) return;
    setState(() => _privacy = updated);
    if (!updated.policyAccepted) {
      widget.advertising.suspend();
      return;
    }
    try {
      await widget.advertising.setPersonalization(
        updated.personalizedAds
            ? AdPersonalization.personalized
            : AdPersonalization.nonPersonalized,
      );
      await widget.advertising.initializeAfterPrivacyConsent();
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _resumeCompleter?.complete();
    _resumeCompleter = null;
    _incomingFilesSubscription?.cancel();
    widget.advertising.dispose();
    super.dispose();
  }

  Future<void> _pickDocument() async {
    final allowedExtensions = await _allowedExtensions;
    if (!mounted) return;
    String? path;
    String? selectedName;
    if (Platform.isAndroid) {
      path = await NativeDocumentPicker.pickDocument();
      selectedName = path == null ? null : File(path).uri.pathSegments.last;
    } else {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      selectedName = file?.name;
      path = file?.path;
      if (file != null && path == null) {
        final importDirectory = Directory(
          '${await NativePaths.applicationSupport()}${Platform.pathSeparator}imports',
        );
        await importDirectory.create(recursive: true);
        final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        path =
            '${importDirectory.path}${Platform.pathSeparator}'
            '${DateTime.now().microsecondsSinceEpoch}_$safeName';
        final output = File(path).openWrite();
        await for (final chunk in file.xFile.openRead()) {
          output.add(chunk);
        }
        await output.flush();
        await output.close();
      }
    }
    if (selectedName != null &&
        !hasCadExtension(selectedName, allowedExtensions)) {
      if (mounted) {
        setState(() {
          _error = context.l10n.text('unsupportedFileType', {
            'formats': allowedExtensions
                .map((value) => value.toUpperCase())
                .join(', '),
          });
        });
      }
      return;
    }
    if (path == null || !mounted) return;
    await _openDocumentPath(path);
  }

  Future<void> _openDocumentPath(String path) async {
    await _waitUntilResumed();
    if (!mounted) return;
    // Lifecycle observers are not guaranteed to be notified in registration
    // order. Synchronize the native core before beginOpenDocument so an
    // incoming intent cannot observe the previous background state.
    widget.engine.setApplicationBackgrounded(false);
    setState(() {
      _opening = true;
      _openProgress = 0;
      _openStage = 'preparing';
      _error = null;
    });
    try {
      final document = await widget.engine.openDocument(
        path,
        onEvent: (event) {
          if (!mounted) return;
          final progress = event.progress.clamp(0.0, 1.0);
          if (event.stage == _openStage &&
              (progress - _openProgress).abs() < 0.01 &&
              !event.terminal) {
            return;
          }
          setState(() {
            _openProgress = progress;
            _openStage = event.stage;
          });
        },
      );
      if (!mounted) return;
      widget.advertising.suspend();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              CadViewerPage(engine: widget.engine, opened: document),
        ),
      );
      widget.advertising.resume();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _waitUntilResumed() {
    if (_applicationResumed) return Future<void>.value();
    return (_resumeCompleter ??= Completer<void>()).future;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _applicationResumed = state == AppLifecycleState.resumed;
    widget.engine.setApplicationBackgrounded(!_applicationResumed);
    if (!_applicationResumed) return;
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    unawaited(_drainIncomingFiles());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.view_in_ar, color: Color(0xff53d4ff)),
            SizedBox(width: 10),
            Text('CADView', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.text('settings'),
            onPressed: _showSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.difference_outlined,
                          size: 64,
                          color: Color(0xff53d4ff),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          l10n.text('openHint'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: Colors.white70),
                        ),
                        const SizedBox(height: 28),
                        FilledButton.icon(
                          key: const Key('open_document'),
                          onPressed: _opening
                              ? widget.engine.cancelCurrentOpen
                              : _pickDocument,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                          icon: _opening
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.folder_open),
                          label: Text(
                            _opening
                                ? l10n.text('cancelOpening', {
                                    'stage': _stageLabel(l10n, _openStage),
                                  })
                                : l10n.text('openDocument'),
                          ),
                        ),
                        if (_opening) ...[
                          const SizedBox(height: 10),
                          LinearProgressIndicator(value: _openProgress),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xffff7875)),
                          ),
                        ],
                        if (DistributionConfig.featureTier ==
                            FeatureTier.viewer) ...[
                          const SizedBox(height: 14),
                          Text(
                            l10n.text('viewerEdition'),
                            style: const TextStyle(color: Colors.white38),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.advertising.available)
                Semantics(
                  label: l10n.text('ad'),
                  container: true,
                  child: widget.advertising.buildHomePlacement(context),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _stageLabel(AppLocalizations l10n, String stage) => switch (stage) {
    'probing' => l10n.text('stageProbe'),
    'parsing' => l10n.text('stageParse'),
    'normalizing' => l10n.text('stageFirstFrame'),
    'complete' => l10n.text('stageComplete'),
    _ => l10n.text('stagePrepare'),
  };
}
