import Flutter
import UIKit
#if canImport(GoogleMobileAds)
import AppTrackingTransparency
import GoogleMobileAds
import UserMessagingPlatform
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var nativePathChannel: FlutterMethodChannel?
  private var incomingFilesChannel: FlutterMethodChannel?
  private var pendingIncomingURLs: [URL] = []
  private let incomingFilesLock = NSLock()
#if canImport(GoogleMobileAds)
  private var storeAdsChannel: FlutterMethodChannel?
  private var storeAdsController: StoreAdsController?
#endif

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "org.cadview/native_paths",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "applicationSupportPath" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let directory = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        ).appendingPathComponent("CADView", isDirectory: true)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: true
        )
        result(directory.path)
      } catch {
        result(
          FlutterError(
            code: "native_path_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
    nativePathChannel = channel

    let incomingChannel = FlutterMethodChannel(
      name: "org.cadview/incoming_files",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    incomingChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "takePendingFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.importPendingFiles(result: result)
    }
    incomingFilesChannel = incomingChannel

#if canImport(GoogleMobileAds)
    let adsController = StoreAdsController(registrar: engineBridge.applicationRegistrar)
    adsController.register()
    storeAdsController = adsController
    storeAdsChannel = adsController.channel
#endif
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    receiveIncomingFiles([url])
    return true
  }

  func receiveIncomingFiles(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    incomingFilesLock.lock()
    for url in urls where !pendingIncomingURLs.contains(url) {
      pendingIncomingURLs.append(url)
    }
    incomingFilesLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.incomingFilesChannel?.invokeMethod("incomingFilesAvailable", arguments: nil)
    }
  }

  private func importPendingFiles(result: @escaping FlutterResult) {
    incomingFilesLock.lock()
    let urls = pendingIncomingURLs
    pendingIncomingURLs.removeAll()
    incomingFilesLock.unlock()
    guard !urls.isEmpty else {
      result([String]())
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let paths = urls.compactMap(self.copyIncomingFile)
      DispatchQueue.main.async { result(paths) }
    }
  }

  private func copyIncomingFile(_ source: URL) -> String? {
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
    do {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let directory = base
        .appendingPathComponent("CADView", isDirectory: true)
        .appendingPathComponent("imports", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let name = source.lastPathComponent.isEmpty ? "document" : source.lastPathComponent
      let destination = directory.appendingPathComponent(name)
      var coordinatedError: NSError?
      var copyError: Error?
      let coordinator = NSFileCoordinator()
      coordinator.coordinate(readingItemAt: source, options: [], error: &coordinatedError) {
        coordinatedURL in
        do {
          try FileManager.default.copyItem(at: coordinatedURL, to: destination)
        } catch {
          copyError = error
        }
      }
      if let error = coordinatedError { throw error }
      if let error = copyError { throw error }
      return destination.path
    } catch {
      return nil
    }
  }
}

#if canImport(GoogleMobileAds)
private final class StoreAdsController: NSObject {
  let channel: FlutterMethodChannel
  private let registrar: FlutterApplicationRegistrar
  private var personalized = false
  private var initialized = false
  private var banners = NSHashTable<StoreBannerPlatformView>.weakObjects()

  init(registrar: FlutterApplicationRegistrar) {
    self.registrar = registrar
    channel = FlutterMethodChannel(
      name: "org.cadview/store_ads",
      binaryMessenger: registrar.messenger()
    )
    super.init()
  }

  func register() {
    registrar.register(
      StoreBannerFactory(controller: self),
      withId: "org.cadview/global_store_banner"
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "available":
        result(true)
      case "initialize":
        let arguments = call.arguments as? [String: Any]
        personalized = arguments?["personalized"] as? Bool == true
        initializeAfterConsent(result: result)
      case "setPersonalization":
        let arguments = call.arguments as? [String: Any]
        personalized = arguments?["personalized"] as? Bool == true
        result(nil)
      case "privacyOptions":
        guard let presenter = Self.presenter else {
          return result(FlutterError(code: "no_presenter", message: nil, details: nil))
        }
        ConsentForm.presentPrivacyOptionsForm(from: presenter) { error in
          if let error {
            result(FlutterError(code: "ump_privacy_options", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "suspend":
        banners.allObjects.forEach { $0.dispose() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func initializeAfterConsent(result: @escaping FlutterResult) {
    if initialized {
      result(nil)
      return
    }
    let continueInitialization = { [weak self] in
      guard let self else { return }
      let parameters = RequestParameters()
      ConsentInformation.shared.requestConsentInfoUpdate(with: parameters) { error in
        if let error {
          result(FlutterError(code: "ump_update", message: error.localizedDescription, details: nil))
          return
        }
        guard let presenter = Self.presenter else {
          result(FlutterError(code: "no_presenter", message: nil, details: nil))
          return
        }
        ConsentForm.loadAndPresentIfRequired(from: presenter) { error in
          if let error {
            result(FlutterError(code: "ump_form", message: error.localizedDescription, details: nil))
            return
          }
          MobileAds.shared.start { _ in
            self.initialized = true
            result(nil)
          }
        }
      }
    }
    if personalized && ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
      ATTrackingManager.requestTrackingAuthorization { _ in continueInitialization() }
    } else {
      continueInitialization()
    }
  }

  func makeBanner(frame: CGRect) -> StoreBannerPlatformView {
    let banner = StoreBannerPlatformView(
      frame: frame,
      personalized: personalized,
      presenter: Self.presenter
    )
    banners.add(banner)
    return banner
  }

  private static var presenter: UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }
}

private final class StoreBannerFactory: NSObject, FlutterPlatformViewFactory {
  private weak var controller: StoreAdsController?

  init(controller: StoreAdsController) { self.controller = controller }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    controller?.makeBanner(frame: frame) ?? EmptyPlatformView(frame: frame)
  }
}

private final class StoreBannerPlatformView: NSObject, FlutterPlatformView, BannerViewDelegate {
  private let container: UIView
  private var banner: BannerView?

  init(frame: CGRect, personalized: Bool, presenter: UIViewController?) {
    container = UIView(frame: frame)
    super.init()
    guard let bannerId = Bundle.main.object(forInfoDictionaryKey: "CADViewAdMobBannerIdentifier") as? String,
          !bannerId.isEmpty else { return }
    let banner = BannerView(adSize: AdSizeBanner)
    banner.adUnitID = bannerId
    banner.rootViewController = presenter
    banner.delegate = self
    banner.isAutoloadEnabled = false
    banner.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(banner)
    NSLayoutConstraint.activate([
      banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      banner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    let request = Request()
    if !personalized {
      let extras = Extras()
      extras.additionalParameters = ["npa": "1"]
      request.register(extras)
    }
    banner.load(request)
    self.banner = banner
  }

  func view() -> UIView { container }

  func bannerViewDidReceiveAd(_ bannerView: BannerView) {
    bannerView.isAutoloadEnabled = false
  }

  func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
    container.isHidden = true
  }

  func dispose() {
    banner?.removeFromSuperview()
    banner = nil
    container.isHidden = true
  }
}

private final class EmptyPlatformView: NSObject, FlutterPlatformView {
  private let empty: UIView
  init(frame: CGRect) { empty = UIView(frame: frame) }
  func view() -> UIView { empty }
}
#endif
