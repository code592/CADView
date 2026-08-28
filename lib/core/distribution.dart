import 'package:flutter/widgets.dart';

enum DistributionChannel { community, cnViewer, cnPro, globalStore }

enum FeatureTier { viewer, full }

enum MonetizationModel { none, paidDownload, limitedAdsWithAdFreePurchase }

class DistributionConfig {
  const DistributionConfig._();

  static const String _raw = String.fromEnvironment(
    'CADVIEW_DISTRIBUTION',
    defaultValue: 'community',
  );
  static const bool adFreeEdition = bool.fromEnvironment(
    'CADVIEW_AD_FREE',
    defaultValue: false,
  );

  static DistributionChannel get channel => switch (_raw) {
    'globalStore' => DistributionChannel.globalStore,
    'cnViewer' => DistributionChannel.cnViewer,
    'cnPro' => DistributionChannel.cnPro,
    _ => DistributionChannel.community,
  };

  static FeatureTier get featureTier => switch (channel) {
    DistributionChannel.cnViewer => FeatureTier.viewer,
    _ => FeatureTier.full,
  };

  static MonetizationModel get monetization => switch (channel) {
    DistributionChannel.cnPro => MonetizationModel.paidDownload,
    DistributionChannel.globalStore =>
      MonetizationModel.limitedAdsWithAdFreePurchase,
    _ => MonetizationModel.none,
  };

  static bool get fullFeatures => featureTier == FeatureTier.full;

  static bool get networkCapable => switch (channel) {
    DistributionChannel.globalStore => true,
    _ => false,
  };

  static bool get advertisingAllowed => switch (channel) {
    DistributionChannel.globalStore => !adFreeEdition,
    _ => false,
  };

  static bool get adFreePurchaseSupported =>
      monetization == MonetizationModel.limitedAdsWithAdFreePurchase &&
      !adFreeEdition;
}

enum AdPersonalization { nonPersonalized, personalized }

/// Store advertising is deliberately isolated behind this interface. The
/// Apache-2.0 community application never imports or initializes a proprietary
/// provider package, and the viewer never receives an [AdvertisingService].
abstract interface class AdvertisingService {
  bool get available;
  Future<void> initializeAfterPrivacyConsent();
  Future<void> setPersonalization(AdPersonalization value);
  Future<void> showPrivacyOptions();
  Widget buildHomePlacement(BuildContext context);
  void resume();
  void suspend();
  void dispose();
}

class DisabledAdvertisingService implements AdvertisingService {
  const DisabledAdvertisingService();

  @override
  bool get available => false;

  @override
  Widget buildHomePlacement(BuildContext context) => const SizedBox.shrink();

  @override
  void resume() {}

  @override
  Future<void> initializeAfterPrivacyConsent() async {}

  @override
  Future<void> setPersonalization(AdPersonalization value) async {}

  @override
  Future<void> showPrivacyOptions() async {}

  @override
  void suspend() {}

  @override
  void dispose() {}
}
