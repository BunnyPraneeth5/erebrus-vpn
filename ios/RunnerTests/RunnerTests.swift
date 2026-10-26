import Flutter
import UIKit
import XCTest
@testable import Runner

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

  func testColdConnectionCollectsCustomAndUniversalLinksWithoutRepeatingAnEntry() {
    let handler = LinkStreamHandler()
    let nativeURL = URL(string: "erebrusvpn://auth?token=cold")!
    let universal = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    universal.webpageURL = URL(string: "https://erebrus.io/vpn?wc_ev=cold")!
    let repeated = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    repeated.webpageURL = nativeURL
    XCTAssertTrue(handler.handleConnectionLinks(
      urls: [nativeURL], userActivities: [universal, repeated]
    ))
    var received = [String]()
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, [nativeURL.absoluteString, universal.webpageURL!.absoluteString])
  }

  func testUnrelatedAndEmptyColdConnectionsReturnFalseWithoutQueueing() {
    let handler = LinkStreamHandler()
    let unrelatedURL = URL(string: "com.googleusercontent.apps.test:/oauthredirect")!
    let unrelatedActivity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    unrelatedActivity.webpageURL = URL(string: "https://example.com/vpn")!
    XCTAssertFalse(handler.handleConnectionLinks(urls: [], userActivities: []))
    XCTAssertFalse(handler.handleConnectionLinks(urls: [unrelatedURL], userActivities: []))
    XCTAssertFalse(handler.handleConnectionLinks(urls: [], userActivities: [unrelatedActivity]))
    XCTAssertFalse(handler.handleConnectionLinks(
      urls: [], userActivities: [NSUserActivity(activityType: "com.example.restore")]
    ))
    var received = [String]()
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertTrue(received.isEmpty)
  }

  func testMixedColdURLsReturnFalseAndQueueOnlyOwnedLinkOnce() {
    let handler = LinkStreamHandler()
    let owned = URL(string: "erebrusvpn://auth?token=cold")!
    let unrelated = URL(string: "com.googleusercontent.apps.test:/oauthredirect")!
    XCTAssertFalse(handler.handleConnectionLinks(
      urls: [owned, unrelated, owned], userActivities: []
    ))
    var received = [String]()
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, [owned.absoluteString])
    _ = handler.onCancel(withArguments: nil)
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, [owned.absoluteString])
  }

  func testMixedColdActivitiesReturnFalseAndQueueOwnedUniversalLink() {
    let owned = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    owned.webpageURL = URL(string: "https://erebrus.io/vpn?wc_ev=cold")!
    let unrelated = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    unrelated.webpageURL = URL(string: "https://example.com/vpn")!
    let missingURL = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    let restoration = NSUserActivity(activityType: "com.example.restore")
    restoration.webpageURL = owned.webpageURL
    for activity in [unrelated, missingURL, restoration] {
      let handler = LinkStreamHandler()
      XCTAssertFalse(handler.handleConnectionLinks(
        urls: [], userActivities: [owned, activity]
      ))
      var received = [String]()
      _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
      XCTAssertEqual(received, [owned.webpageURL!.absoluteString])
    }
  }

  func testOtherColdPayloadPreventsClaimingOwnedConnectionWithoutDroppingLink() {
    let handler = LinkStreamHandler()
    let owned = URL(string: "erebrusvpn://auth?token=cold")!
    XCTAssertFalse(handler.handleConnectionLinks(
      urls: [owned], userActivities: [], hasOtherPayload: true
    ))
    XCTAssertFalse(handler.handleConnectionLinks(
      urls: [], userActivities: [], hasOtherPayload: true
    ))
    var received = [String]()
    _ = handler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, [owned.absoluteString])
  }

  func testWarmUniversalActivitiesRequireBrowsingTypeAndKnownRedirect() {
    let handler = LinkStreamHandler()
    let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity.webpageURL = URL(string: "https://erebrus.io/vpn?wc_ev=warm")!
    XCTAssertTrue(handler.handleUserActivity(activity))
    activity.webpageURL = URL(string: "https://example.com/vpn")!
    XCTAssertFalse(handler.handleUserActivity(activity))
    let unrelated = NSUserActivity(activityType: "com.example.restore")
    unrelated.webpageURL = URL(string: "https://erebrus.io/vpn")!
    XCTAssertFalse(handler.handleUserActivity(unrelated))
  }

  @MainActor
  func testApplicationForwardsUnrelatedURLsToPlugins() {
    let delegate = AppDelegate()
    let plugin = URLPluginSpy()
    delegate.addApplicationLifeCycleDelegate(plugin)
    let unrelated = URL(string: "com.googleusercontent.apps.test:/oauthredirect")!
    let owned = URL(string: "erebrusvpn://auth?token=test")!
    XCTAssertTrue(delegate.application(UIApplication.shared, open: unrelated))
    XCTAssertTrue(delegate.application(UIApplication.shared, open: owned))
    XCTAssertEqual(plugin.received, [unrelated])
    var received = [String]()
    _ = delegate.linkStreamHandler.onListen(withArguments: nil) { received.append($0 as! String) }
    XCTAssertEqual(received, [owned.absoluteString])
  }

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}

private final class URLPluginSpy: NSObject, FlutterApplicationLifeCycleDelegate {
  var received = [URL]()

  func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    received.append(url)
    return true
  }
}
