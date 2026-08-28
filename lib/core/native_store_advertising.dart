import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'distribution.dart';
import '../l10n/app_localizations.dart';

AdvertisingService advertisingForDistribution() {
  if (DistributionConfig.advertisingAllowed &&
      (Platform.isAndroid || Platform.isIOS)) {
    return NativeStoreAdvertisingService();
  }
  return const DisabledAdvertisingService();
}

class NativeStoreAdvertisingService implements AdvertisingService {
  static const _channel = MethodChannel('org.cadview/store_ads');
  final ValueNotifier<bool> _ready = ValueNotifier(false);
  AdPersonalization _personalization = AdPersonalization.nonPersonalized;
  bool _initializedByConsent = false;

  @override
  bool get available => true;

  @override
  Future<void> initializeAfterPrivacyConsent() async {
    await _channel.invokeMethod<void>('initialize', {
      'personalized': _personalization == AdPersonalization.personalized,
    });
    _initializedByConsent = true;
    _ready.value = true;
  }

  @override
  Future<void> setPersonalization(AdPersonalization value) async {
    _personalization = value;
    if (_initializedByConsent) {
      await _channel.invokeMethod<void>('setPersonalization', {
        'personalized': value == AdPersonalization.personalized,
      });
    }
  }

  @override
  Future<void> showPrivacyOptions() =>
      _channel.invokeMethod<void>('privacyOptions');

  @override
  Widget buildHomePlacement(BuildContext context) =>
      _StoreAdPlacement(ready: _ready);

  @override
  void resume() {
    if (_initializedByConsent) {
      unawaited(initializeAfterPrivacyConsent().catchError((_) {}));
    }
  }

  @override
  void suspend() {
    _ready.value = false;
    unawaited(_channel.invokeMethod<void>('suspend').catchError((_) {}));
  }

  @override
  void dispose() {
    suspend();
    _ready.dispose();
  }
}

class _StoreAdPlacement extends StatefulWidget {
  const _StoreAdPlacement({required this.ready});

  final ValueListenable<bool> ready;

  @override
  State<_StoreAdPlacement> createState() => _StoreAdPlacementState();
}

class _StoreAdPlacementState extends State<_StoreAdPlacement> {
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: widget.ready,
      builder: (context, ready, _) {
        if (!ready) return const SizedBox.shrink();
        final platformView = Platform.isAndroid
            ? const AndroidView(viewType: 'org.cadview/global_store_banner')
            : const UiKitView(viewType: 'org.cadview/global_store_banner');
        return Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      context.l10n.text('ad'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() => _hidden = true),
                      child: Text(context.l10n.text('hideThisAd')),
                    ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(context.l10n.text('reportAdTitle')),
                          content: Text(context.l10n.text('reportAdBody')),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: Text(context.l10n.text('done')),
                            ),
                          ],
                        ),
                      ),
                      child: Text(context.l10n.text('reportAd')),
                    ),
                  ],
                ),
                SizedBox(height: 50, child: Center(child: platformView)),
              ],
            ),
          ),
        );
      },
    );
  }
}
