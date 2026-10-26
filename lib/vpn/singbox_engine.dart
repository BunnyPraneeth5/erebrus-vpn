import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/desktop_system_proxy.dart';
import '../platform/platform_capabilities.dart';
import '../settings/split_tunnel_config.dart';
import 'singbox_desktop_runner.dart';
import 'vpn_models.dart';
import 'wg_keygen.dart';

/// Lifecycle stages reported by the native tunnel.
enum VpnStage { disconnected, connecting, connected, disconnecting, error }

VpnStage _stageFrom(String? s) => switch (s) {
  'connecting' => VpnStage.connecting,
  'connected' => VpnStage.connected,
  'disconnecting' => VpnStage.disconnecting,
  'error' => VpnStage.error,
  _ => VpnStage.disconnected,
};

/// Cumulative tunnel byte counters surfaced by the engine.
class VpnStats {
  const VpnStats({
    this.rxBytes = 0,
    this.txBytes = 0,
    this.uplinkBps = 0,
    this.downlinkBps = 0,
  });
  final int rxBytes;
  final int txBytes;
  final int uplinkBps;
  final int downlinkBps;

  factory VpnStats.fromMap(Map<dynamic, dynamic> m) => VpnStats(
    rxBytes: (m['rx_bytes'] as num?)?.toInt() ?? 0,
    txBytes: (m['tx_bytes'] as num?)?.toInt() ?? 0,
    uplinkBps: (m['uplink_bps'] as num?)?.toInt() ?? 0,
    downlinkBps: (m['downlink_bps'] as num?)?.toInt() ?? 0,
  );
}

/// Dart facade over the native sing-box (libbox) tunnel.
///
/// Android uses `VpnService`; iOS and macOS use a Network Extension.
/// Windows and Linux use a bundled sing-box CLI subprocess.
class SingboxEngine {
  SingboxEngine._();
  static final SingboxEngine instance = SingboxEngine._();

  static const MethodChannel _method = MethodChannel('dev.erebrus/singbox');
  static const EventChannel _statusChannel = EventChannel(
    'dev.erebrus/singbox/status',
  );
  static const EventChannel _statsChannel = EventChannel(
    'dev.erebrus/singbox/stats',
  );

  final _desktop = SingboxDesktopRunner.instance;

  Stream<VpnStage>? _stage;
  Stream<VpnStats>? _stats;
  int _generation = 0;
  bool? _requestedBlock;
  bool _requestAccepted = false;
  VpnStage _nativeStage = VpnStage.disconnected;

  bool get isBlocking => _useDesktopRunner
      ? _desktop.isBlocking
      : _requestedBlock == true &&
            _requestAccepted &&
            _nativeStage == VpnStage.connected;

  Future<bool> verifyBlocking() async {
    final generation = _generation;
    if (_useDesktopRunner) {
      final verified = await _desktop.verifyBlocking();
      return generation == _generation && verified && _desktop.isBlocking;
    }
    if (_requestedBlock != true || !_requestAccepted) return false;
    final current = await stage();
    return generation == _generation &&
        isBlocking &&
        current == VpnStage.connected;
  }

  Future<bool> verifyConnection() async {
    final generation = _generation;
    if (_useDesktopRunner) {
      if (!_desktop.hasRunningProcess ||
          _desktop.isBlocking ||
          _stageFrom(_desktop.stage) != VpnStage.connected) {
        return false;
      }
      final enabled = await DesktopSystemProxy.isEnabled(
        host: SingboxConfigBuilder.localProxyHost,
        port: SingboxConfigBuilder.localProxyPort,
      );
      return generation == _generation &&
          enabled &&
          _desktop.hasRunningProcess &&
          !_desktop.isBlocking &&
          _stageFrom(_desktop.stage) == VpnStage.connected;
    }
    if (_requestedBlock != false || !_requestAccepted) return false;
    final current = await stage();
    return generation == _generation &&
        _requestedBlock == false &&
        _requestAccepted &&
        current == VpnStage.connected;
  }

  bool get _useDesktopRunner => PlatformCapabilities.usesDesktopVpnRunner;

  /// Stream of lifecycle stages.
  Stream<VpnStage> get onStage => _stage ??= _useDesktopRunner
      ? _desktop.onStage
      : _statusChannel.receiveBroadcastStream().map((e) {
          _nativeStage = _stageFrom(e as String?);
          return _nativeStage;
        });

  /// Stream of byte counters (~1s cadence while connected).
  Stream<VpnStats> get onStats => _stats ??= _useDesktopRunner
      ? _desktop.onStats
      : _statsChannel.receiveBroadcastStream().map(
          (e) => VpnStats.fromMap((e as Map?) ?? const {}),
        );

  /// Desktop-only hint when [prepare] returns false (e.g. missing sing-box CLI).
  String? get desktopPrepareError =>
      _useDesktopRunner ? _desktop.lastError : null;

  /// Native sing-box start failure (Android/iOS), when the tunnel errors before connect.
  Future<String?> lastTunnelError() async {
    if (_useDesktopRunner) return _desktop.lastError;
    try {
      return await _method.invokeMethod<String>('lastError');
    } on PlatformException {
      return null;
    }
  }

  Future<bool> prepare() async {
    if (_useDesktopRunner) return _desktop.prepare();
    try {
      return (await _method.invokeMethod<bool>('prepare')) ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> start(
    String configJson, {
    String profileName = 'Erebrus',
    SplitTunnelConfig splitTunnel = const SplitTunnelConfig(),
    bool preserveProxy = false,
  }) async {
    final generation = ++_generation;
    if (_useDesktopRunner) {
      await _desktop.start(
        configJson,
        profileName: profileName,
        preserveProxy: preserveProxy,
      );
      return;
    }
    _requestedBlock = null;
    _requestAccepted = false;
    _nativeStage = VpnStage.connecting;
    final config = jsonDecode(configJson) as Map<String, dynamic>;
    _requestedBlock = (config['route'] as Map?)?['final'] == 'block';
    await _method.invokeMethod('start', {
      'config': configJson,
      'name': profileName,
      'splitTunnelEnabled': splitTunnel.enabled,
      'splitTunnelMode': splitTunnel.mode.name,
      'splitTunnelPackages': splitTunnel.packages,
    });
    if (generation == _generation) _requestAccepted = true;
  }

  Future<void> stop({bool preserveProxy = false}) async {
    ++_generation;
    _requestedBlock = null;
    _requestAccepted = false;
    _nativeStage = VpnStage.disconnecting;
    if (_useDesktopRunner) {
      await _desktop.stop(preserveProxy: preserveProxy);
      return;
    }
    await _method.invokeMethod('stop');
    // stop() is async via startService — wait until the TUN is actually torn down.
    for (var i = 0; i < 40; i++) {
      final s = await _method.invokeMethod<String>('stage');
      if (s == 'disconnected') return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('[SingboxEngine] stop: timed out waiting for disconnected');
    throw StateError('Tunnel stop could not be verified');
  }

  Future<VpnStage> stage() async {
    if (_useDesktopRunner) return _stageFrom(_desktop.stage);
    final generation = _generation;
    final s = await _method.invokeMethod<String>('stage');
    if (generation == _generation) _nativeStage = _stageFrom(s);
    return generation == _generation ? _nativeStage : VpnStage.disconnected;
  }

  /// Legacy optional WebView proxy override. Current mobile builds include the
  /// app in the system TUN and do not depend on this capability for routing.
  Future<bool> setAppProxy({required String host, required int port}) async {
    if (_useDesktopRunner) return true;
    try {
      return await _method.invokeMethod('setAppProxy', {
                'host': host,
                'port': port,
              })
              as bool? ??
          false;
    } on MissingPluginException catch (e) {
      debugPrint('[SingboxEngine] setAppProxy unsupported: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[SingboxEngine] setAppProxy failed: $e');
      return false;
    }
  }

  Future<bool> clearAppProxy() async {
    if (_useDesktopRunner) return true;
    try {
      return await _method.invokeMethod('clearAppProxy') as bool? ?? false;
    } on MissingPluginException catch (e) {
      debugPrint('[SingboxEngine] clearAppProxy unsupported: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[SingboxEngine] clearAppProxy failed: $e');
      return false;
    }
  }

  /// Configures Apple VPN On Demand. Other platforms retain their existing
  /// app-launch auto-connect behavior and report this capability as absent.
  Future<bool> setOnDemandEnabled(bool enabled) async {
    if (!PlatformCapabilities.isIOS && !PlatformCapabilities.isMacOS) {
      return false;
    }
    try {
      return await _method.invokeMethod<bool>('setOnDemandEnabled', {
            'enabled': enabled,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      debugPrint('[SingboxEngine] setOnDemandEnabled failed: $e');
      return false;
    }
  }

  Future<({String private, String public})> generateWireGuardKeyPair() async {
    if (_useDesktopRunner) return WgKeygen.generate();
    try {
      final m = await _method.invokeMapMethod<String, String>('genWgKeys');
      final priv = m?['private'] ?? '';
      final pub = m?['public'] ?? '';
      if (priv.isNotEmpty && pub.isNotEmpty) {
        return (private: priv, public: pub);
      }
    } catch (e) {
      debugPrint('[SingboxEngine] native genWgKeys failed: $e');
    }
    return WgKeygen.generate();
  }
}
