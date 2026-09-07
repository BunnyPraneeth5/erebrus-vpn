import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let eventsChannel = "com.erebrus.vpn/events"
  private static let methodsChannel = "com.erebrus.vpn/methods"

  let linkStreamHandler = LinkStreamHandler()
  private var eventsChannelRef: FlutterEventChannel?
  private var methodsChannelRef: FlutterMethodChannel?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.pluginRegistry.registrar(forPlugin: "ErebrusDeepLinks")?
      .addSceneDelegate(linkStreamHandler)
    SingboxBridge.shared.register(with: engineBridge.applicationRegistrar.messenger())

    let messenger = engineBridge.applicationRegistrar.messenger()
    eventsChannelRef = FlutterEventChannel(
      name: AppDelegate.eventsChannel,
      binaryMessenger: messenger
    )
    eventsChannelRef?.setStreamHandler(linkStreamHandler)

    methodsChannelRef = FlutterMethodChannel(
      name: AppDelegate.methodsChannel,
      binaryMessenger: messenger
    )
    methodsChannelRef?.setMethodCallHandler { call, result in
      if call.method == "initialLink" {
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if linkStreamHandler.handleLink(url.absoluteString) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if linkStreamHandler.handleUserActivity(userActivity) {
      return true
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }
}

final class LinkStreamHandler: NSObject, FlutterStreamHandler, FlutterSceneLifeCycleDelegate {
  private var eventSink: FlutterEventSink?
  private var queuedLinks = [String]()

  static func ownsURL(_ url: URL) -> Bool {
    if url.scheme?.lowercased() == "erebrusvpn" { return true }
    return url.scheme?.lowercased() == "https" &&
      url.host?.lowercased() == "erebrus.io" &&
      (url.port == nil || url.port == 443) &&
      url.user == nil && url.password == nil && url.path == "/vpn"
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    let pending = queuedLinks
    queuedLinks.removeAll()
    pending.forEach { events($0) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func handleLink(_ link: String) -> Bool {
    guard let url = URL(string: link), Self.ownsURL(url) else { return false }
    if let eventSink {
      eventSink(link)
    } else {
      queuedLinks.append(link)
    }
    return true
  }

  func handleUserActivity(_ userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
          let url = userActivity.webpageURL else { return false }
    return handleLink(url.absoluteString)
  }

  func handleConnectionLinks(
    urls: [URL],
    userActivities: [NSUserActivity],
    hasOtherPayload: Bool = false
  ) -> Bool {
    var links = urls.map { $0.absoluteString }
    links += userActivities.compactMap {
      $0.activityType == NSUserActivityTypeBrowsingWeb ? $0.webpageURL?.absoluteString : nil
    }
    var seen = Set<String>()
    var handled = false
    for link in links where seen.insert(link).inserted {
      if handleLink(link) { handled = true }
    }
    return handled && !hasOtherPayload && urls.allSatisfy(Self.ownsURL) &&
      userActivities.allSatisfy {
        $0.activityType == NSUserActivityTypeBrowsingWeb &&
          $0.webpageURL.map(Self.ownsURL) == true
      }
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let connectionOptions else { return false }
    return handleConnectionLinks(
      urls: connectionOptions.urlContexts.map { $0.url },
      userActivities: Array(connectionOptions.userActivities),
      hasOtherPayload: connectionOptions.shortcutItem != nil ||
        connectionOptions.notificationResponse != nil ||
        connectionOptions.cloudKitShareMetadata != nil ||
        connectionOptions.handoffUserActivityType != nil
    )
  }
}
