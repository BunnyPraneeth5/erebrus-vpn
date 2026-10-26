import CryptoKit
import Flutter
import UIKit

/// iOS implementation of `dev.erebrus/singbox` — WireGuard keygen and tunnel
/// control via [TunnelManager] + the ErebrusTunnel Network Extension.
final class SingboxBridge {
  static let shared = SingboxBridge()
  static let methodChannel = "dev.erebrus/singbox"
  static let statusChannel = "dev.erebrus/singbox/status"
  static let statsChannel = "dev.erebrus/singbox/stats"

  private var statusSink: FlutterEventSink?
  private(set) var stage = "disconnected"

  private init() {
    TunnelManager.shared.onStageChange = { [weak self] stage in
      self?.publishStage(stage)
    }
  }

  func register(with messenger: FlutterBinaryMessenger) {
    let method = FlutterMethodChannel(name: Self.methodChannel, binaryMessenger: messenger)
    method.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "prepare":
        Task {
          let ok = await TunnelManager.shared.prepare()
          self.complete(result, with: ok)
        }
      case "start":
        guard let args = call.arguments as? [String: Any],
              let config = args["config"] as? String else {
          result(FlutterError(code: "ARGS", message: "config required", details: nil))
          return
        }
        let name = (args["name"] as? String) ?? "Erebrus"
        Task {
          do {
            try await TunnelManager.shared.start(config: config, profileName: name)
            self.complete(result, with: nil)
          } catch {
            self.publishStage("error")
            self.complete(
              result,
              with: FlutterError(
                code: "START",
                message: error.localizedDescription,
                details: nil
              )
            )
          }
        }
      case "stop":
        Task {
          await TunnelManager.shared.stop()
          self.complete(result, with: nil)
        }
      case "stage":
        result(self.stage)
      case "genWgKeys":
        result(self.generateWireGuardKeyPair())
      case "setAppProxy", "clearAppProxy":
        // WKWebView on iOS has no supported per-app proxy override equivalent
        // to Android's WebView proxy API. Its traffic is already carried by the
        // system packet tunnel, so the routing requirement is satisfied.
        result(true)
      case "setOnDemandEnabled":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        Task {
          let updated = await TunnelManager.shared.setOnDemandEnabled(enabled)
          self.complete(result, with: updated)
        }
      case "lastError":
        Task {
          let error = await TunnelManager.shared.lastError
          self.complete(result, with: error)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let status = FlutterEventChannel(name: Self.statusChannel, binaryMessenger: messenger)
    status.setStreamHandler(StatusStreamHandler(bridge: self))

    let stats = FlutterEventChannel(name: Self.statsChannel, binaryMessenger: messenger)
    stats.setStreamHandler(StatsStreamHandler())
  }

  func bindStatusSink(_ sink: @escaping FlutterEventSink) {
    statusSink = sink
    TunnelManager.shared.refreshStageFromSystem()
    sink(stage)
  }

  func unbindStatusSink() {
    statusSink = nil
  }

  private func publishStage(_ value: String) {
    onPlatformThread { [weak self] in
      guard let self else { return }
      self.stage = value
      self.statusSink?(value)
    }
  }

  private func complete(_ result: @escaping FlutterResult, with value: Any?) {
    onPlatformThread {
      result(value)
    }
  }

  private func onPlatformThread(_ action: @escaping () -> Void) {
    if Thread.isMainThread {
      action()
    } else {
      DispatchQueue.main.async(execute: action)
    }
  }

  private func generateWireGuardKeyPair() -> [String: String] {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let publicKey = privateKey.publicKey
    return [
      "private": privateKey.rawRepresentation.base64EncodedString(),
      "public": publicKey.rawRepresentation.base64EncodedString(),
    ]
  }
}

private final class StatusStreamHandler: NSObject, FlutterStreamHandler {
  weak var bridge: SingboxBridge?
  init(bridge: SingboxBridge) { self.bridge = bridge }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    bridge?.bindStatusSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    bridge?.unbindStatusSink()
    return nil
  }
}

private final class StatsStreamHandler: NSObject, FlutterStreamHandler {
  private var timer: Timer?
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    emitStats()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.emitStats()
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    timer?.invalidate()
    timer = nil
    eventSink = nil
    return nil
  }

  private func emitStats() {
    let defaults = sharedAppGroupDefaults
    eventSink?([
      "rx_bytes": defaults.integer(forKey: TunnelConstants.StatsKeys.rxBytes),
      "tx_bytes": defaults.integer(forKey: TunnelConstants.StatsKeys.txBytes),
      "downlink_bps": defaults.integer(forKey: TunnelConstants.StatsKeys.downlinkBps),
      "uplink_bps": defaults.integer(forKey: TunnelConstants.StatsKeys.uplinkBps),
    ])
  }

  private var sharedAppGroupDefaults: UserDefaults {
    UserDefaults(suiteName: TunnelConstants.appGroup) ?? .standard
  }
}
