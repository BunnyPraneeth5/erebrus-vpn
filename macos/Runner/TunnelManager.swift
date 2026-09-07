import Foundation
import NetworkExtension

/// Controls the macOS Packet Tunnel Provider via NETunnelProviderManager.
final class TunnelManager {
    static let shared = TunnelManager()

    private(set) var stage: String = "disconnected"
    @MainActor private(set) var lastError: String?
    var onStageChange: ((String) -> Void)?

    private var statusObserver: NSObjectProtocol?
    private var currentManager: NETunnelProviderManager?
    private weak var observedConnection: NEVPNConnection?

    private init() {}

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func prepare() async -> Bool {
        await MainActor.run { lastError = nil }
        do {
            _ = try await loadOrCreateManager()
            return true
        } catch {
            await MainActor.run { lastError = error.localizedDescription }
            NSLog("[TunnelManager] prepare failed: \(error)")
            return false
        }
    }

    func start(config: String, profileName: String) async throws {
        await MainActor.run { lastError = nil }
        do {
            try await startTunnel(config: config, profileName: profileName)
        } catch {
            await MainActor.run { lastError = error.localizedDescription }
            throw error
        }
    }

    private func startTunnel(config: String, profileName: String) async throws {
        setStage("connecting")
        let manager = try await loadOrCreateManager()

        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            observeStatus(of: manager)
        }

        if manager.connection.status != .disconnected &&
            manager.connection.status != .invalid {
            manager.connection.stopVPNTunnel()
            await waitUntilDisconnected(manager)
        }

        let proto = manager.protocolConfiguration as! NETunnelProviderProtocol
        proto.providerBundleIdentifier = TunnelConstants.tunnelBundleId
        proto.serverAddress = TunnelConstants.providerDescription
        proto.providerConfiguration = [
            TunnelConstants.configKey: config as NSString,
            TunnelConstants.profileNameKey: profileName as NSString,
        ]
        manager.localizedDescription = TunnelConstants.providerDescription
        manager.isEnabled = true
        try await manager.saveToPreferences()

        try await manager.loadFromPreferences()
        observeStatus(of: manager)
        try manager.connection.startVPNTunnel()
        refreshStageFromSystem()
    }

    func stop() async {
        setStage("disconnecting")
        guard let manager = try? await loadManager() else {
            setStage("disconnected")
            return
        }
        manager.isOnDemandEnabled = false
        manager.isEnabled = false
        try? await manager.saveToPreferences()
        manager.connection.stopVPNTunnel()
        await waitUntilDisconnected(manager)
        setStage("disconnected")
    }

    func setOnDemandEnabled(_ enabled: Bool) async -> Bool {
        guard let manager = try? await loadManager() else { return false }
        if enabled {
            let connect = NEOnDemandRuleConnect()
            connect.interfaceTypeMatch = .any
            manager.onDemandRules = [connect]
            manager.isEnabled = true
        } else {
            manager.onDemandRules = []
        }
        manager.isOnDemandEnabled = enabled
        do {
            try await manager.saveToPreferences()
            return true
        } catch {
            NSLog("[TunnelManager] on-demand update failed: \(error)")
            return false
        }
    }

    func refreshStageFromSystem() {
        if let manager = currentManager {
            setStage(mapStatus(manager.connection.status))
            return
        }
        Task {
            guard let manager = try? await loadManager() else {
                setStage("disconnected")
                return
            }
            setStage(mapStatus(manager.connection.status))
        }
    }

    private func mapStatus(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected:
            return "connected"
        case .connecting, .reasserting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        case .disconnected, .invalid:
            return "disconnected"
        @unknown default:
            return "disconnected"
        }
    }

    private func waitUntilDisconnected(_ manager: NETunnelProviderManager) async {
        for _ in 0..<40 {
            if manager.connection.status == .disconnected ||
                manager.connection.status == .invalid {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[TunnelManager] timed out waiting for the previous VPN session to stop")
    }

    private func setStage(_ value: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setStage(value)
            }
            return
        }
        guard stage != value else { return }
        stage = value
        onStageChange?(value)
    }

    private func observeStatus(of manager: NETunnelProviderManager) {
        let install = { [weak self] in
            guard let self else { return }
            let connection = manager.connection
            self.currentManager = manager
            if self.observedConnection === connection { return }
            if let statusObserver = self.statusObserver {
                NotificationCenter.default.removeObserver(statusObserver)
            }
            self.observedConnection = connection
            self.statusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: connection,
                queue: .main
            ) { [weak self, weak connection] _ in
                guard let self, let connection else { return }
                self.setStage(self.mapStatus(connection.status))
            }
        }
        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == TunnelConstants.tunnelBundleId
        }) {
            observeStatus(of: existing)
            return existing
        }
        throw NSError(domain: "ErebrusTunnel", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "VPN profile not found",
        ])
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        do {
            return try await loadManager()
        } catch {
            let failure = error as NSError
            guard failure.domain == "ErebrusTunnel", failure.code == 1 else { throw error }
        }
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = TunnelConstants.tunnelBundleId
        proto.serverAddress = TunnelConstants.providerDescription
        manager.protocolConfiguration = proto
        manager.localizedDescription = TunnelConstants.providerDescription
        observeStatus(of: manager)
        return manager
    }
}
