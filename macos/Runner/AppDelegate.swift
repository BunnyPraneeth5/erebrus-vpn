import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private static let eventsChannel = "com.erebrus.vpn/events"
  private static let methodsChannel = "com.erebrus.vpn/methods"

  let linkStreamHandler = LinkStreamHandler()
  private var eventsChannelRef: FlutterEventChannel?
  private var methodsChannelRef: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      showMainWindow(sender)
    }
    return true
  }

  private func showMainWindow(_ application: NSApplication) {
    guard let window = application.windows.first(where: { $0 is MainFlutterWindow }) else {
      return
    }

    // The Flutter window is hidden (not destroyed) when its close button is
    // pressed. A Dock-icon click must activate the app and order that same
    // window back to the front.
    application.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(self)
  }

  func wireChannels(messenger: FlutterBinaryMessenger) {
    SingboxBridge.shared.register(with: messenger)

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

  override func application(_ application: NSApplication, open urls: [URL]) {
    let remaining = urls.filter { !linkStreamHandler.handleLink($0.absoluteString) }
    if !remaining.isEmpty {
      super.application(application, open: remaining)
    }
  }

  @objc func showAboutPanel(_ sender: Any?) {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    let build = info?["CFBundleVersion"] as? String ?? ""
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationName: "Erebrus VPN",
      .applicationVersion: version,
      .version: build,
    ]
    if let icon = NSImage(named: "AboutIcon") {
      icon.isTemplate = false
      options[.applicationIcon] = icon
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
  }
}

final class LinkStreamHandler: NSObject, FlutterStreamHandler {
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
}
