import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    forward(connectionOptions.urlContexts.map(\.url))
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    forward(URLContexts.map(\.url))
  }

  private func forward(_ urls: [URL]) {
    (UIApplication.shared.delegate as? AppDelegate)?.receiveIncomingFiles(urls)
  }
}
