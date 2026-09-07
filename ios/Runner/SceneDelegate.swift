import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
      super.scene(scene, openURLContexts: URLContexts)
      return
    }
    let remaining = Set(URLContexts.filter {
      !appDelegate.linkStreamHandler.handleLink($0.url.absoluteString)
    })
    if !remaining.isEmpty {
      super.scene(scene, openURLContexts: remaining)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
       appDelegate.linkStreamHandler.handleUserActivity(userActivity) {
      return
    }
    super.scene(scene, continue: userActivity)
  }
}
