import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  /// Collegamento ciesign://pair?... con cui è stata aperta l'app, letto da CieNfc.
  static var launchURL: URL?

  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let url = connectionOptions.urlContexts.first?.url { SceneDelegate.launchURL = url }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    if let url = URLContexts.first?.url { CieNfc.shared?.open(url: url) }
  }
}
