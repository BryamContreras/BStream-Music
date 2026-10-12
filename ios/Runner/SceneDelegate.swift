import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    for context in connectionOptions.urlContexts {
      BStreamWidgetActionRelay.shared.accept(context.url)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      BStreamWidgetActionRelay.shared.accept(context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
