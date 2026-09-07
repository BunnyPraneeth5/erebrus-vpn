import Cocoa
import FlutterMacOS
import XCTest
@testable import Erebrus_VPN

class RunnerTests: XCTestCase {

  func testColdLinksDrainOnceAndWarmLinksAreImmediate() {
    let handler = LinkStreamHandler()
    let first = "erebrusvpn://auth?token=first"
    let second = "erebrusvpn://wc?response=second"
    var received = [String]()
    XCTAssertTrue(handler.handleLink(first))
    XCTAssertTrue(handler.handleLink(second))
    XCTAssertNil(handler.onListen(withArguments: nil) { received.append($0 as! String) })
    XCTAssertEqual(received, [first, second])
    XCTAssertTrue(handler.handleLink(first))
    XCTAssertEqual(received, [first, second, first])
    XCTAssertNil(handler.onCancel(withArguments: nil))
    XCTAssertNil(handler.onListen(withArguments: nil) { received.append($0 as! String) })
    XCTAssertEqual(received, [first, second, first])
  }

  func testLinksReceivedWhileCancelledAreDeliveredOnce() {
    let handler = LinkStreamHandler()
    var received = [String]()
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    _ = handler.onCancel(withArguments: nil)
    XCTAssertTrue(handler.handleLink("erebrusvpn://auth?token=resume"))
    XCTAssertTrue(received.isEmpty)
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, ["erebrusvpn://auth?token=resume"])
  }

  func testOnlyExistingRedirectsAreOwned() {
    let handler = LinkStreamHandler()
    let accepted = [
      "erebrusvpn://auth?token=test",
      "erebrusvpn://wc?response=test",
      "https://erebrus.io/vpn?wc_ev=test",
    ]
    let rejected = [
      "com.googleusercontent.apps.test:/oauthredirect?code=test",
      "coinbase-wallet-sdk://callback",
      "https://example.com/vpn",
      "https://erebrus.io.evil.example/vpn",
      "https://erebrus.io/auth",
      "https://erebrus.io/vpn/other",
      "http://erebrus.io/vpn",
      "https://erebrus.io:8443/vpn",
      "https://user@erebrus.io/vpn",
      "not a callback",
    ]
    accepted.forEach { XCTAssertTrue(handler.handleLink($0), $0) }
    rejected.forEach { XCTAssertFalse(handler.handleLink($0), $0) }
    var received = [String]()
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, accepted)
  }

  @MainActor
  func testApplicationQueuesEarlyOwnedLinksAndForwardsOtherURLsToPlugins() {
    let delegate = AppDelegate()
    let plugin = URLPluginSpy()
    delegate.addApplicationLifecycleDelegate(plugin)
    let unrelated = URL(string: "com.googleusercontent.apps.test:/oauthredirect")!
    let owned = URL(string: "erebrusvpn://auth?token=test")!
    delegate.application(NSApplication.shared, open: [owned, unrelated])
    XCTAssertEqual(plugin.received, [unrelated])
    var received = [String]()
    _ = delegate.linkStreamHandler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, [owned.absoluteString])
    delegate.application(NSApplication.shared, open: [owned])
    XCTAssertEqual(received, [owned.absoluteString, owned.absoluteString])
    XCTAssertEqual(plugin.received, [unrelated])
  }

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}

private final class URLPluginSpy: NSObject, FlutterAppLifecycleDelegate {
  var received = [URL]()

  func handleOpenURLs(_ urls: [URL]) -> Bool {
    received.append(contentsOf: urls)
    return true
  }
}
