import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Socket;

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../platform/platform_capabilities.dart';
import '../platform/secure_storage.dart';
import '../settings/app_settings_controller.dart';
import '../settings/split_tunnel_config.dart';
import 'gateway_client.dart';
import 'gateway_controller.dart';
import 'gateway_errors.dart';
import 'egress_ip_probe.dart';
import 'singbox_engine.dart';
import 'vpn_models.dart';
import 'vpn_session_store.dart';

/// Provisions a VPN client on a node through the gateway and returns the
/// credential bundle. Injected so the controller stays independent of the HTTP
/// layer (api.dart provides the real implementation:
/// POST /api/v2/vpn/clients { name, node_id, wg_public_key }).
typedef Provisioner =
    Future<CredentialBundle> Function({
      required VpnNode node,
      required String wgPublicKey,
      required String name,
    });

/// Drives the single sing-box engine for every protocol. The UI binds to its
/// observables; the connect flow provisions a client, builds the per-transport
/// sing-box config (WireGuard as the endpoint), and — for Auto/Stealth — falls
/// back across transports until one establishes.
class VpnController extends GetxController {
  VpnController({
    Provisioner? provisioner,
    SingboxEngine? engine,
    this.egressProbe,
    this.beforeSessionSave,
  }) : _provision = provisioner,
       _engine = engine ?? SingboxEngine.instance;

  final SingboxEngine _engine;
  final Future<String?> Function()? egressProbe;
  Provisioner? _provision;
  int _generation = 0;
  Future<void> _engineQueue = Future<void>.value();
  bool _blockRecoveryUsed = false;
  bool _preserveProxy = false;
  final Future<void> Function()? beforeSessionSave;
  int _terminalRevision = 0;
  int? _pendingDropGeneration;

  Future<void> _drainUnexpectedDrop() async {
    if (_pendingDropGeneration != _generation ||
        _connectInProgress ||
        _syncingNative ||
        killSwitchEngaging.value ||
        _userDisconnecting ||
        _cancelRequested) {
      return;
    }
    _pendingDropGeneration = null;
    await _engageKillSwitch();
  }

  Future<T?> _engineOperation<T>(int generation, Future<T> Function() action) {
    final result = _engineQueue.then<T?>((_) async {
      if (generation != _generation) return null;
      return await action();
    });
    _engineQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<String?> _fetchEgress() async {
    try {
      if (!await _engine.verifyConnection()) return null;
      final ip =
          await (egressProbe?.call() ??
              EgressIpProbe.fetch(
                timeout: const Duration(seconds: 6),
                useTunnelProxy: PlatformCapabilities.usesDesktopVpnRunner,
              ));
      return await _engine.verifyConnection() ? ip : null;
    } catch (_) {
      return null;
    }
  }

  // observables
  final stage = VpnStage.disconnected.obs;
  final mode = ConnectMode.auto.obs;
  final activeTransport = Rxn<Transport>();
  final selectedNode = Rxn<VpnNode>();
  final stats = const VpnStats().obs;
  final error = RxnString();
  final killSwitchBlocking = false.obs;
  final killSwitchEngaging = false.obs;
  final egressIp = RxnString();
  final egressIpLoading = false.obs;

  /// False when the tunnel is up but repeated egress probes fail (TUN captures
  /// traffic while the inner WireGuard/carrier is dead — "connected, no internet").
  final tunnelHealthy = true.obs;

  /// When the tunnel entered the connected state (null while not connected).
  /// Tracked here so the connect screen's elapsed timer stays accurate across
  /// view rebuilds instead of restarting from zero each time the view mounts.
  final connectedSince = Rxn<DateTime>();

  StreamSubscription<VpnStage>? _stageSub;
  StreamSubscription<VpnStats>? _statsSub;
  Worker? _healthWorker;
  Timer? _healthTimer;
  Worker? _blockingWorker;
  Timer? _blockingTimer;
  int _blockingCheckRevision = 0;
  bool _blockingCheckInProgress = false;
  int _egressFailures = 0;
  bool _wasConnected = false;
  bool _userDisconnecting = false;
  bool _syncingNative = false;
  bool _connectInProgress = false;
  bool _cancelRequested = false;
  Transport? _confirmedTransport;

  static const _kWgPrivate = 'erebrus_wg_private';
  static const _kWgPublic = 'erebrus_wg_public';

  bool get isConnected => stage.value == VpnStage.connected;
  bool get isProtected =>
      isConnected &&
      tunnelHealthy.value &&
      !killSwitchEngaging.value &&
      !killSwitchBlocking.value;
  String get protectionLabel {
    if (killSwitchEngaging.value) return 'Securing connection';
    if (killSwitchBlocking.value) {
      return PlatformCapabilities.usesDesktopVpnRunner
          ? 'Proxy traffic blocked'
          : 'Kill switch active';
    }
    if (isProtected) {
      return PlatformCapabilities.usesDesktopVpnRunner
          ? 'Proxy protected'
          : 'Protected';
    }
    if (isConnected) return 'Connection unhealthy';
    if (stage.value == VpnStage.error) return 'Connection failed';
    return isBusy ? 'Connecting' : 'Disconnected';
  }

  String get blockingMessage {
    if (killSwitchEngaging.value) return 'Verifying kill switch enforcement…';
    if (!killSwitchBlocking.value) {
      return 'Kill switch protection is not verified';
    }
    return PlatformCapabilities.usesDesktopVpnRunner
        ? 'System-proxy traffic is blocked until you reconnect. Apps that bypass the proxy are not blocked.'
        : 'Kill switch active — tunnel traffic blocked until you reconnect';
  }

  bool get isBusy =>
      killSwitchEngaging.value ||
      stage.value == VpnStage.connecting ||
      stage.value == VpnStage.disconnecting;

  /// Allows late injection of the gateway provisioner (e.g. after login).
  set provisioner(Provisioner p) => _provision = p;

  @override
  void onInit() {
    super.onInit();
    // Health monitoring follows the UI stage regardless of which path set it
    // (engine event, connect() success, or syncWithNative()).
    _healthWorker = ever<VpnStage>(stage, (s) {
      if (s == VpnStage.connected) {
        // `??=` so re-entrant connected events (e.g. iOS delivering a delayed
        // disconnected/connected pair) don't reset the elapsed timer.
        connectedSince.value ??= DateTime.now();
        _startHealthMonitor();
      } else {
        connectedSince.value = null;
        _stopHealthMonitor();
      }
    });
    _blockingWorker = ever<bool>(killSwitchBlocking, (blocking) {
      _stopBlockingMonitor();
      if (blocking) _scheduleBlockingCheck();
    });
    if (killSwitchBlocking.value) _scheduleBlockingCheck();
    _stageSub = _engine.onStage.listen((s) {
      if (s == VpnStage.error || s == VpnStage.disconnected) {
        ++_terminalRevision;
        if (isConnected || killSwitchBlocking.value) {
          final wasBlocking = killSwitchBlocking.value;
          killSwitchBlocking.value = false;
          tunnelHealthy.value = false;
          stage.value = VpnStage.error;
          activeTransport.value = null;
          egressIp.value = null;
          egressIpLoading.value = false;
          _wasConnected = false;
          _preserveProxy = true;
          error.value = wasBlocking
              ? 'Kill switch stopped — protection could not be verified'
              : 'Connection lost — protection could not be verified';
          if (!_userDisconnecting &&
              !_cancelRequested &&
              _killSwitchEnabled &&
              (!wasBlocking || !_blockRecoveryUsed)) {
            if (wasBlocking) _blockRecoveryUsed = true;
            _pendingDropGeneration = _generation;
            unawaited(_drainUnexpectedDrop());
          }
          return;
        }
      }
      if (_userDisconnecting ||
          _cancelRequested ||
          _syncingNative ||
          _connectInProgress ||
          killSwitchEngaging.value) {
        return;
      }
      if (killSwitchBlocking.value || _engine.isBlocking) {
        if (s == VpnStage.connected) {
          stage.value = VpnStage.error;
          return;
        }
        killSwitchBlocking.value = false;
        tunnelHealthy.value = false;
        stage.value = VpnStage.error;
        error.value = 'Kill switch stopped — protection could not be verified';
        activeTransport.value = null;
        if (!_blockRecoveryUsed && _killSwitchEnabled) {
          _blockRecoveryUsed = true;
          unawaited(_engageKillSwitch());
        }
        return;
      }
      // During connect(), hold the UI on "connecting" until egress is verified.
      if (_connectInProgress && s == VpnStage.connected) return;
      // A TUN that comes up late — after connect() already failed and showed an
      // error — is a zombie from an abandoned attempt: tear it down instead of
      // flipping the UI to "connected" on a tunnel nobody verified.
      if (s == VpnStage.connected &&
          !_wasConnected &&
          !_syncingNative &&
          stage.value == VpnStage.error) {
        debugPrint(
          '[VPN] late connected event after failed connect — stopping zombie tunnel',
        );
        unawaited(
          _engineOperation<void>(
            _generation,
            () => _engine.stop(preserveProxy: true),
          ).catchError((_) {}),
        );
        return;
      }
      if (s == VpnStage.connected && !isProtected) {
        unawaited(syncWithNative());
        return;
      }
      stage.value = s;
      if (s == VpnStage.connected) {
        _wasConnected = true;
        killSwitchBlocking.value = false;
        // iOS may deliver a delayed disconnected/connected pair after a
        // fallback transport has already succeeded. Restore the transport that
        // passed egress verification so Diagnostics reflects the actual path.
        if (activeTransport.value == null && _confirmedTransport != null) {
          activeTransport.value = _confirmedTransport;
        }
        unawaited(_probeEgressIp());
      }
      if (s == VpnStage.disconnected || s == VpnStage.error) {
        egressIp.value = null;
        egressIpLoading.value = false;
        // A delayed "disconnected" event from the previous candidate can
        // arrive after the next candidate has already been selected. Keep the
        // in-flight transport so Diagnostics does not lose VLESS/Hy2 while a
        // fallback connection is succeeding.
        if (!_connectInProgress) {
          activeTransport.value = null;
        }
        if (!_connectInProgress) {
          _restorePreferredMode();
        }
        if (_wasConnected &&
            !_userDisconnecting &&
            !_syncingNative &&
            !_connectInProgress &&
            _killSwitchEnabled) {
          unawaited(_engageKillSwitch());
        } else if (_userDisconnecting) {
          _wasConnected = false;
          _userDisconnecting = false;
        }
      }
    });
    _statsSub = _engine.onStats.listen((s) => stats.value = s);
  }

  /// Reconciles Flutter observables with the native tunnel and persisted session.
  /// Call on cold start and whenever the app returns to the foreground.
  Future<void> syncWithNative() async {
    if (_connectInProgress ||
        killSwitchEngaging.value ||
        _userDisconnecting ||
        _cancelRequested ||
        _syncingNative) {
      return;
    }
    final generation = _generation;
    final terminalRevision = _terminalRevision;
    _syncingNative = true;
    try {
      final native = await _engine.stage().catchError(
        (_) => VpnStage.disconnected,
      );
      final session = await VpnSessionStore.load();
      if (generation != _generation) return;
      if (killSwitchBlocking.value ||
          session?.killSwitchActive == true ||
          _engine.isBlocking) {
        killSwitchBlocking.value = false;
        tunnelHealthy.value = false;
        stage.value = VpnStage.error;
        _preserveProxy = true;
        final verified = await _engine.verifyBlocking().catchError(
          (_) => false,
        );
        if (generation != _generation) return;
        if (verified &&
            terminalRevision == _terminalRevision &&
            _engine.isBlocking) {
          killSwitchBlocking.value = true;
          error.value = blockingMessage;
          _applySession(session);
        } else {
          await _engageKillSwitch(force: true);
        }
        return;
      }
      final verifiedConnection =
          native == VpnStage.connected &&
          await _engine.verifyConnection().catchError((_) => false);
      if (generation != _generation) return;
      if (terminalRevision != _terminalRevision) {
        stage.value = VpnStage.error;
        tunnelHealthy.value = false;
        activeTransport.value = null;
        error.value = 'Connection lost — protection could not be verified';
        if (native == VpnStage.connected && _killSwitchEnabled) {
          _preserveProxy = true;
          _pendingDropGeneration = generation;
        }
        return;
      }
      if (verifiedConnection) {
        _wasConnected = true;
        _userDisconnecting = false;
        killSwitchBlocking.value = false;
        // Anchor the elapsed timer to the real connect time persisted in the
        // snapshot so a cold start / resume shows the true session duration
        // rather than counting from app launch. Set before flipping the stage
        // so the stage worker's `??=` keeps this value; falls back to now when
        // the snapshot predates this field.
        connectedSince.value = session?.savedAt;
        tunnelHealthy.value = false;
        stage.value = VpnStage.connected;
        error.value = null;
        if (session?.killSwitchActive == true) {
          await VpnSessionStore.clear();
          debugPrint(
            '[VPN] sync: cleared stale kill-switch session (tunnel is up)',
          );
        }
        _applySession(session);
        unawaited(_probeEgressIp());
        debugPrint(
          '[VPN] sync: native connected'
          '${session != null ? ' · ${session.nodeName} (${session.transport.label})' : ''}',
        );
        return;
      }

      if (native == VpnStage.connected) {
        stage.value = VpnStage.error;
        tunnelHealthy.value = false;
        activeTransport.value = null;
        error.value = 'Connection protection could not be verified — reconnect';
        return;
      }

      stage.value = native;
      if (native == VpnStage.disconnected || native == VpnStage.error) {
        _wasConnected = false;
        activeTransport.value = null;
        if (session != null) await VpnSessionStore.clear();
      }
      debugPrint('[VPN] sync: native ${native.name}');
    } finally {
      _syncingNative = false;
      await _drainUnexpectedDrop();
    }
  }

  void _applySession(VpnSessionSnapshot? session) {
    if (session == null) return;
    mode.value = session.mode;
    _confirmedTransport = session.transport;
    activeTransport.value = session.transport;
    final matched = _matchNode(session);
    if (matched != null) {
      selectedNode.value = matched;
    } else if (isConnected || killSwitchBlocking.value) {
      selectedNode.value = session.toNode();
    }
  }

  VpnNode? _matchNode(VpnSessionSnapshot session) {
    if (!Get.isRegistered<GatewayController>()) return null;
    for (final n in Get.find<GatewayController>().nodes) {
      if (n.id == session.nodeId) return n;
    }
    return null;
  }

  void reconcileNodeFromGateway() {
    if (!isConnected && !killSwitchBlocking.value) return;
    final current = selectedNode.value;
    if (current == null) return;
    if (!Get.isRegistered<GatewayController>()) return;
    for (final n in Get.find<GatewayController>().nodes) {
      if (n.id == current.id) {
        selectedNode.value = n;
        return;
      }
    }
  }

  @override
  void onClose() {
    ++_generation;
    _stageSub?.cancel();
    _statsSub?.cancel();
    _healthWorker?.dispose();
    _healthTimer?.cancel();
    _blockingWorker?.dispose();
    _stopBlockingMonitor();
    super.onClose();
  }

  void setMode(ConnectMode m) => mode.value = m;
  void selectNode(VpnNode n) => selectedNode.value = n;
  void clearSelectedNode() => selectedNode.value = null;

  /// Wipes locally stored WG keys and disconnects (used on sign-out / reset).
  Future<void> resetLocalVpnData() async {
    await disconnect().catchError((_) {});
    selectedNode.value = null;
    _confirmedTransport = null;
    activeTransport.value = null;
    await _deleteStoredSecret(_kWgPrivate);
    await _deleteStoredSecret(_kWgPublic);
    await VpnSessionStore.clear();
  }

  /// Connects to [node] (or the currently selected node) using the current mode,
  /// trying each candidate transport in order until one connects.
  Future<void> connect({
    VpnNode? node,
    CredentialBundle? providedBundle,
    String? clientPrivateKey,
  }) async {
    if (_connectInProgress && !_cancelRequested) {
      debugPrint(
        '[VPN] connect already in progress — ignoring duplicate request',
      );
      return;
    }
    final target = node ?? selectedNode.value;
    if (target == null) {
      error.value = 'Select a node first';
      return;
    }
    if (!target.canAcceptClients) {
      error.value = 'Selected server is at capacity — pick another node';
      stage.value = VpnStage.error;
      return;
    }
    if (providedBundle == null && _provision == null) {
      error.value = 'VPN provisioning is not configured';
      return;
    }
    final generation = ++_generation;
    _preserveProxy = true;
    _userDisconnecting = false;
    _connectInProgress = true;
    _cancelRequested = false;
    _wasConnected = false;
    _blockRecoveryUsed = false;
    killSwitchBlocking.value = false;
    killSwitchEngaging.value = false;
    selectedNode.value = target;
    error.value = null;
    stage.value = VpnStage.connecting;

    try {
      await _engineOperation<void>(
        generation,
        () => _engine.stop(preserveProxy: _preserveProxy),
      );
      if (generation != _generation) return;
      for (var attempt = 0; attempt <= 1; attempt++) {
        try {
          if (generation != _generation) return;
          stage.value = VpnStage.connecting;
          final prepared = await _engine.prepare();
          if (generation != _generation) return;
          if (!prepared) {
            error.value =
                _engine.desktopPrepareError ??
                (PlatformCapabilities.usesDesktopVpnRunner
                    ? 'sing-box is missing — install the bundled desktop VPN engine'
                    : 'VPN permission denied');
            stage.value = VpnStage.error;
            return;
          }
          final String privateToUse;
          ({String private, String public})? wgKeys;
          CredentialBundle bundle;
          if (providedBundle != null) {
            bundle = providedBundle;
            if (clientPrivateKey != null && clientPrivateKey.isNotEmpty) {
              privateToUse = clientPrivateKey;
            } else {
              wgKeys = await _ensureWgKeys();
              privateToUse = wgKeys.private;
            }
          } else {
            wgKeys = await _ensureWgKeys();
            if (generation != _generation) return;
            privateToUse = wgKeys.private;
            bundle = await _provision!(
              node: target,
              wgPublicKey: wgKeys.public,
              name: _clientName(),
            );
          }
          if (generation != _generation) return;
          if (_cancelRequested) {
            await _finishCancelled();
            return;
          }

          // Stealth needs a full sing-box profile; stale WG-only caches break REALITY.
          if (providedBundle == null &&
              mode.value != ConnectMode.wireguard &&
              !bundle.hasStealth &&
              Get.isRegistered<GatewayController>()) {
            final gw = Get.find<GatewayController>();
            debugPrint(
              '[VPN] bundle missing stealth — refreshing from gateway',
            );
            try {
              final fresh = await gw.client.fetchExistingClientBundle(
                nodeId: target.id,
                wgPublicKey: wgKeys!.public,
              );
              if (fresh != null && fresh.hasStealth) bundle = fresh;
            } catch (e) {
              debugPrint('[VPN] stealth bundle refresh failed: $e');
            }
          }

          if (generation != _generation) return;
          // Filter candidate transports to what this node/bundle actually supports.
          final candidates = mode.value.transports.where((t) {
            if (t == Transport.wireguard) return true;
            return bundle.hasStealth && target.supportsStealth;
          }).toList();
          if (candidates.isEmpty) {
            error.value = 'No usable transport for this node';
            stage.value = VpnStage.error;
            return;
          }

          debugPrint(
            '[VPN] mode=${mode.value.label} · try order: '
            '${candidates.map((t) => t.label).join(' → ')}',
          );

          final resolvedHosts = PlatformCapabilities.usesDesktopVpnRunner
              ? const <String, String>{}
              : await SingboxConfigBuilder.resolveDialHosts(bundle);

          for (var i = 0; i < candidates.length; i++) {
            if (generation != _generation) return;
            if (_cancelRequested) break;
            final t = candidates[i];
            try {
              if (i > 0) await _ensureTunnelStopped();
              if (generation != _generation) return;
              if (_cancelRequested) break;
              stage.value = VpnStage.connecting;
              final config = SingboxConfigBuilder.build(
                bundle: bundle,
                transport: t,
                clientPrivateKey: privateToUse,
                // Windows/Linux use a local mixed proxy. Apple and Android
                // builds use their OS-managed full-device tunnel.
                useSystemTunnel: !PlatformCapabilities.usesDesktopVpnRunner,
                resolvedHosts: resolvedHosts,
              );
              activeTransport.value = t;
              final srv = bundle.serverPublicKey;
              final srvShort = srv.length > 8 ? '${srv.substring(0, 8)}…' : srv;
              debugPrint(
                '[VPN] trying ${t.label} → ${bundle.dialTarget(t)} '
                '(wg ${bundle.address}, srv $srvShort)',
              );
              var ok = await _armAndStart(
                _engineOperation<void>(
                  generation,
                  () => _engine.start(
                    jsonEncode(config),
                    profileName: 'Erebrus · ${target.name}',
                    splitTunnel: _splitTunnelConfig(),
                    preserveProxy: _preserveProxy,
                  ),
                ),
              );
              if (generation != _generation) return;
              if (!ok) {
                // Native tunnel may be up while EventChannel/method-channel was blocked (e.g. main-thread ANR).
                final native = await _engine.stage().catchError(
                  (_) => VpnStage.disconnected,
                );
                if (native == VpnStage.connected) {
                  ok = true;
                  debugPrint(
                    '[VPN] ${t.label} native connected (stage event missed)',
                  );
                }
              }
              debugPrint(
                '[VPN] ${t.label} finished stage=${stage.value.name} ok=$ok',
              );
              if (ok) {
                final ready = t == Transport.wireguard
                    ? await _waitWireGuardReady()
                    : await _waitStealthReady();
                if (generation != _generation) return;
                if (_cancelRequested) break;
                if (!ready) {
                  debugPrint(
                    '[VPN] ${t.label} tunnel up but no egress — trying next transport',
                  );
                  await _ensureTunnelStopped();
                  continue;
                }
              }
              if (generation != _generation) return;
              if (ok) {
                final terminalRevision = _terminalRevision;
                tunnelHealthy.value = false;
                await _engineOperation<void>(generation, () async {
                  await beforeSessionSave?.call();
                  if (generation != _generation) return;
                  await VpnSessionStore.save(
                    node: target,
                    transport: t,
                    mode: mode.value,
                    profileName: 'Erebrus · ${target.name}',
                  );
                });
                if (generation != _generation) return;
                if (terminalRevision == _terminalRevision &&
                    (PlatformCapabilities.isIOS ||
                        PlatformCapabilities.isMacOS) &&
                    Get.isRegistered<AppSettingsController>() &&
                    Get.find<AppSettingsController>()
                        .autoConnectOnLaunch
                        .value) {
                  await _engine.setOnDemandEnabled(true);
                }
                if (generation != _generation) return;
                final verified = await _engine.verifyConnection().catchError(
                  (_) => false,
                );
                if (generation != _generation) return;
                if (!verified || terminalRevision != _terminalRevision) {
                  tunnelHealthy.value = false;
                  stage.value = VpnStage.error;
                  activeTransport.value = null;
                  error.value =
                      'Connection lost — protection could not be verified';
                  if (_killSwitchEnabled) _pendingDropGeneration = generation;
                  return;
                }
                _wasConnected = true;
                tunnelHealthy.value = true;
                _confirmedTransport = t;
                activeTransport.value = t;
                stage.value = VpnStage.connected;
                error.value = null;
                _preserveProxy = false;
                unawaited(_probeEgressIp());
                debugPrint(
                  '[VPN] connected · mode=${mode.value.label} · transport=${t.label} · '
                  'config=${t == Transport.wireguard ? "direct-wg" : "stealth-singbox"}',
                );
                return;
              }
            } catch (_) {
              debugPrint('[VPN] transport ${t.label} failed');
            }
            if (generation != _generation) return;
            _wasConnected = false;
            if (_cancelRequested) break;
            await _ensureTunnelStopped();
          }
          if (generation != _generation) return;
          _wasConnected = false;
          if (_cancelRequested) {
            await _finishCancelled();
            return;
          }
          await _engineOperation<void>(
            generation,
            () => _engine.stop(preserveProxy: _preserveProxy),
          );
          if (generation != _generation) return;
          _confirmedTransport = null;
          activeTransport.value = null;
          final failure = await _connectFailureMessage();
          if (generation != _generation) return;
          error.value = failure;
          stage.value = VpnStage.error;
        } on GatewayException catch (e) {
          if (generation != _generation) return;
          _wasConnected = false;
          if (_cancelRequested) {
            await _finishCancelled();
            return;
          }
          if (attempt == 0 && _looksLikeMissingServerConfig(e)) {
            debugPrint(
              '[VPN] server config missing for current WG key — rotating and retrying once',
            );
            await _rotateWgKeys();
            continue;
          }
          _confirmedTransport = null;
          activeTransport.value = null;
          error.value = friendlyGatewayError(e, nodeName: target.name);
          stage.value = VpnStage.error;
          break;
        } catch (e) {
          if (generation != _generation) return;
          _wasConnected = false;
          if (_cancelRequested) {
            await _finishCancelled();
            return;
          }
          _confirmedTransport = null;
          activeTransport.value = null;
          error.value = friendlyGatewayError(e, nodeName: target.name);
          stage.value = VpnStage.error;
          break;
        }
      }
    } catch (_) {
      if (generation == _generation) {
        stage.value = VpnStage.error;
        tunnelHealthy.value = false;
        activeTransport.value = null;
        error.value = 'Connection transition could not be verified';
      }
    } finally {
      if (generation == _generation || _cancelRequested) {
        _connectInProgress = false;
      }
      if (generation == _generation && _pendingDropGeneration == generation) {
        await _drainUnexpectedDrop();
      } else if (generation == _generation &&
          stage.value == VpnStage.error &&
          _preserveProxy &&
          _killSwitchEnabled) {
        await _engageKillSwitch();
      }
    }
  }

  /// User-initiated abort of an in-flight [connect] — stops the engine and
  /// returns the UI to disconnected without surfacing an error.
  Future<void> cancelConnect() async {
    if (!_connectInProgress && !killSwitchEngaging.value) return;
    debugPrint('[VPN] connect cancelled by user');
    await disconnect();
  }

  /// Cleanup shared by every cancelled-connect exit path.
  Future<void> _finishCancelled() async {
    await disconnect();
    debugPrint('[VPN] connect aborted — back to disconnected');
  }

  Future<void> disconnect() async {
    final generation = ++_generation;
    _userDisconnecting = true;
    // Also aborts any connect() still running its transport loop.
    _cancelRequested = true;
    _preserveProxy = false;
    killSwitchBlocking.value = false;
    killSwitchEngaging.value = false;
    _wasConnected = false;
    _confirmedTransport = null;
    activeTransport.value = null;
    error.value = null;
    egressIp.value = null;
    egressIpLoading.value = false;
    stage.value = VpnStage.disconnecting;
    try {
      await _engineOperation<void>(generation, () => _engine.stop());
      if (generation != _generation) return;
      final current = await _engine.stage();
      if (generation != _generation) return;
      if (current != VpnStage.disconnected) {
        throw StateError('Stop not verified');
      }
      stage.value = VpnStage.disconnected;
    } catch (_) {
      if (generation != _generation) return;
      stage.value = VpnStage.error;
      error.value = 'Disconnect could not be verified — retry disconnect';
    }
    if (generation != _generation) return;
    tunnelHealthy.value = false;
    _userDisconnecting = false;
    _restorePreferredMode();
    await _engineOperation<void>(generation, VpnSessionStore.clear);
  }

  Future<void> releaseKillSwitchIfActive() async {
    if (!killSwitchBlocking.value &&
        !killSwitchEngaging.value &&
        !_preserveProxy) {
      return;
    }
    await disconnect();
  }

  void _restorePreferredMode() {
    if (!Get.isRegistered<AppSettingsController>()) return;
    mode.value = Get.find<AppSettingsController>().defaultProtocol.value;
  }

  Future<void> _probeEgressIp() async {
    if (!isConnected || killSwitchBlocking.value || killSwitchEngaging.value) {
      return;
    }
    if (egressIpLoading.value) return;
    final generation = _generation;
    egressIpLoading.value = true;
    try {
      final ip = await _fetchEgress();
      if (generation == _generation && isConnected) _recordEgressResult(ip);
      debugPrint('[VPN] egress IP probe → ${ip ?? "failed"}');
    } finally {
      if (generation == _generation) egressIpLoading.value = false;
    }
  }

  // ── Tunnel health monitor ─────────────────────────────────────────────
  // Native reports "connected" when the OS TUN opens, not when the inner
  // WireGuard handshake completes (see ErebrusVpnService.openTun). connect()
  // verifies egress before celebrating, but syncWithNative() and long-lived
  // sessions have no such gate — so re-probe periodically and flag the
  // "TUN up, nothing flows" state instead of showing PROTECTED forever.

  void _startHealthMonitor() {
    _egressFailures = 0;
    _scheduleHealthCheck(const Duration(seconds: 45));
  }

  void _stopHealthMonitor() {
    _healthTimer?.cancel();
    _healthTimer = null;
    _egressFailures = 0;
    tunnelHealthy.value = false;
  }

  void _scheduleHealthCheck(Duration delay) {
    _healthTimer?.cancel();
    _healthTimer = Timer(delay, () async {
      if (!isConnected ||
          killSwitchBlocking.value ||
          killSwitchEngaging.value) {
        return;
      }
      final generation = _generation;
      final ip = await _fetchEgress();
      if (!isConnected || generation != _generation) return;
      _recordEgressResult(ip);
      // Re-check quickly while degraded so recovery/confirmation is prompt.
      _scheduleHealthCheck(Duration(seconds: _egressFailures > 0 ? 10 : 45));
    });
  }

  void _recordEgressResult(String? ip) {
    if (ip != null) {
      if (!tunnelHealthy.value) debugPrint('[VPN] tunnel egress recovered');
      _egressFailures = 0;
      tunnelHealthy.value = true;
      egressIp.value = ip;
      return;
    }
    _egressFailures += 1;
    tunnelHealthy.value = false;
    egressIp.value = null;
    if (_egressFailures == 1) _scheduleHealthCheck(const Duration(seconds: 10));
    if (_egressFailures >= 2) {
      debugPrint('[VPN] tunnel up but egress failing — flagging unhealthy');
      stage.value = VpnStage.error;
      activeTransport.value = null;
      error.value = 'Connection health could not be verified';
      if (_killSwitchEnabled) unawaited(_engageKillSwitch());
    }
  }

  bool get _killSwitchEnabled =>
      Get.isRegistered<AppSettingsController>() &&
      Get.find<AppSettingsController>().killSwitchEnabled.value;

  SplitTunnelConfig _splitTunnelConfig() {
    if (!Get.isRegistered<AppSettingsController>()) {
      return const SplitTunnelConfig();
    }
    return Get.find<AppSettingsController>().activeSplitTunnelConfig();
  }

  void _stopBlockingMonitor() {
    ++_blockingCheckRevision;
    _blockingTimer?.cancel();
    _blockingTimer = null;
  }

  void _scheduleBlockingCheck() {
    final generation = _generation;
    final revision = _blockingCheckRevision;
    bool isCurrent() =>
        generation == _generation &&
        revision == _blockingCheckRevision &&
        killSwitchBlocking.value;
    _blockingTimer?.cancel();
    _blockingTimer = Timer(const Duration(seconds: 5), () async {
      if (!isCurrent()) return;
      if (_blockingCheckInProgress) {
        _scheduleBlockingCheck();
        return;
      }
      _blockingCheckInProgress = true;
      bool verified;
      try {
        verified = await _engine.verifyBlocking();
      } catch (_) {
        verified = false;
      } finally {
        _blockingCheckInProgress = false;
      }
      if (!isCurrent()) return;
      if (verified) {
        _scheduleBlockingCheck();
        return;
      }
      ++_terminalRevision;
      killSwitchBlocking.value = false;
      tunnelHealthy.value = false;
      stage.value = VpnStage.error;
      activeTransport.value = null;
      egressIp.value = null;
      egressIpLoading.value = false;
      _wasConnected = false;
      _preserveProxy = true;
      error.value =
          'Kill switch protection could not be verified — reconnect or disconnect to retry';
      if (!_blockRecoveryUsed && _killSwitchEnabled) {
        _blockRecoveryUsed = true;
        _pendingDropGeneration = generation;
        await _drainUnexpectedDrop();
      }
    });
  }

  Future<void> _engageKillSwitch({bool force = false}) async {
    if (killSwitchBlocking.value ||
        killSwitchEngaging.value ||
        _userDisconnecting ||
        _connectInProgress ||
        (!force && !_killSwitchEnabled)) {
      return;
    }
    final generation = ++_generation;
    _preserveProxy = true;
    _wasConnected = false;
    killSwitchBlocking.value = false;
    killSwitchEngaging.value = true;
    stage.value = VpnStage.error;
    tunnelHealthy.value = false;
    activeTransport.value = null;
    egressIp.value = null;
    egressIpLoading.value = false;
    error.value = blockingMessage;
    try {
      await _engineOperation<void>(
        generation,
        () => _engine.stop(preserveProxy: true),
      );
      if (generation != _generation) return;
      final config = SingboxConfigBuilder.killSwitchBlockConfig();
      await _engineOperation<void>(
        generation,
        () => _engine.start(
          jsonEncode(config),
          profileName: 'Erebrus · Kill switch',
          splitTunnel: _splitTunnelConfig(),
          preserveProxy: true,
        ),
      );
      if (generation != _generation) return;
      final terminalRevision = _terminalRevision;
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      var verified = false;
      do {
        verified = await _engine.verifyBlocking();
        if (generation != _generation) return;
        if (verified) break;
        final current = await _engine.stage();
        if (generation != _generation) return;
        if (current == VpnStage.error ||
            current == VpnStage.connected ||
            (PlatformCapabilities.usesDesktopVpnRunner &&
                current != VpnStage.connecting)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } while (DateTime.now().isBefore(deadline));
      if (!verified ||
          !_engine.isBlocking ||
          terminalRevision != _terminalRevision) {
        throw StateError('Blocking not verified');
      }
      killSwitchBlocking.value = true;
      killSwitchEngaging.value = false;
      error.value = blockingMessage;
      final node = selectedNode.value;
      if (node != null) {
        await _engineOperation<void>(generation, () async {
          await beforeSessionSave?.call();
          if (generation != _generation) return;
          await VpnSessionStore.save(
            node: node,
            transport: _confirmedTransport ?? Transport.wireguard,
            mode: mode.value,
            profileName: 'Erebrus · Kill switch',
            killSwitchActive: true,
          );
        });
      }
      if (generation != _generation || !killSwitchBlocking.value) return;
      debugPrint(
        '[VPN] kill switch engaged — replaced tunnel with block config',
      );
    } catch (_) {
      if (generation != _generation) return;
      debugPrint('[VPN] kill switch engage failed');
      killSwitchBlocking.value = false;
      error.value =
          'Kill switch protection could not be verified — reconnect or disconnect to retry';
      stage.value = VpnStage.error;
    } finally {
      if (generation == _generation) killSwitchEngaging.value = false;
      await _drainUnexpectedDrop();
    }
  }

  Future<void> toggle() => isConnected ? disconnect() : connect();

  /// Waits until the local sing-box mixed inbound accepts TCP (egress probe target).
  Future<bool> _waitLocalMixedProxy({
    int attempts = 40,
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    if (egressProbe != null) return true;
    final host = SingboxConfigBuilder.localProxyHost;
    final port = SingboxConfigBuilder.localProxyPort;
    for (var i = 0; i < attempts; i++) {
      if (_cancelRequested) return false;
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 200),
        );
        await socket.close();
        debugPrint('[VPN] mixed proxy ready at $host:$port');
        return true;
      } catch (_) {
        if (i + 1 < attempts) await Future<void>.delayed(interval);
      }
    }
    debugPrint('[VPN] mixed proxy not ready at $host:$port');
    return false;
  }

  Future<bool> _waitTunnelEgress({
    required String label,
    int attempts = 4,
    Duration interval = const Duration(milliseconds: 400),
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (_cancelRequested) return false;
      final ip = await _fetchEgress();
      if (ip != null) {
        debugPrint('[VPN] $label egress ready → $ip');
        return true;
      }
      if (i + 1 < attempts) await Future<void>.delayed(interval);
    }
    return false;
  }

  /// Direct WireGuard: TUN may be up before UDP handshake completes — verify egress.
  Future<bool> _waitWireGuardReady() async {
    if (Platform.isAndroid && !await _waitLocalMixedProxy(attempts: 24)) {
      return false;
    }
    return _waitTunnelEgress(label: 'WireGuard');
  }

  /// Stealth: wait for mixed-in, then carrier + inner WG, before showing connected.
  /// Probes run in parallel with a hard 3s cap each, so a dead carrier falls
  /// through to the next transport in about 13s instead of appearing hung.
  Future<bool> _waitStealthReady() async {
    if (!await _waitLocalMixedProxy()) return false;
    // Carrier (VLESS/Hy2) and loopback WG peer need a beat after mixed-in is up.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return _waitTunnelEgress(label: 'Stealth');
  }

  /// Fully tears down the native tunnel before the next transport attempt.
  Future<void> _ensureTunnelStopped() async {
    final generation = _generation;
    if (_cancelRequested) return;
    final now = await _engine.stage();
    if (generation != _generation || now == VpnStage.disconnected) return;
    await _engineOperation<void>(
      generation,
      () => _engine.stop(preserveProxy: _preserveProxy),
    );
    for (var i = 0; i < 50; i++) {
      if (generation != _generation) return;
      final s = await _engine.stage();
      if (s == VpnStage.disconnected) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint(
      '[VPN] stop: timed out waiting for disconnected before transport retry',
    );
  }

  /// Subscribes before [startFuture] completes so fast native errors are not missed.
  /// Also polls native [stage] because Android starts the tunnel asynchronously
  /// after the method channel returns and the EventChannel "connected" event can
  /// be missed, leaving the UI stuck on "connecting" while the OS VPN is up.
  Future<String> _connectFailureMessage() async {
    final native = await _engine.lastTunnelError();
    if (native != null && native.isNotEmpty) {
      if (native.contains('ParsePrefix') || native.contains('ipcidr')) {
        return 'VPN config error — update the Erebrus app to the latest build';
      }
      final short = native.length > 160
          ? '${native.substring(0, 160)}…'
          : native;
      return 'Could not connect — $short';
    }
    final desktop = _engine.desktopPrepareError;
    if (desktop != null && desktop.isNotEmpty) {
      return 'Could not connect — $desktop';
    }
    if (PlatformCapabilities.usesDesktopVpnRunner) {
      return 'Could not connect — verify the desktop VPN engine, then try Stealth or another server';
    }
    return 'Could not connect — try WireGuard or Stealth mode, or pick another server';
  }

  Future<bool> _armAndStart(
    Future<void> startFuture, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final completer = Completer<bool>();
    late StreamSubscription<VpnStage> sub;
    sub = _engine.onStage.listen((s) {
      if (s == VpnStage.connected && !completer.isCompleted) {
        completer.complete(true);
      }
      if (s == VpnStage.error && !completer.isCompleted) {
        completer.complete(false);
      }
    });
    try {
      await startFuture;
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (_cancelRequested) return false;
        if (completer.isCompleted) return await completer.future;
        final now = await _engine.stage();
        if (now == VpnStage.connected) return true;
        if (now == VpnStage.error) return false;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      final finalStage = await _engine.stage().catchError(
        (_) => VpnStage.disconnected,
      );
      if (finalStage == VpnStage.connected) return true;
      debugPrint(
        '[VPN] _armAndStart timed out after ${timeout.inSeconds}s (native=${finalStage.name})',
      );
      return false;
    } finally {
      await sub.cancel();
    }
  }

  Future<({String private, String public})> _ensureWgKeys() async {
    final priv = await _readStoredSecret(_kWgPrivate);
    final pub = await _readStoredSecret(_kWgPublic);
    if (priv != null && priv.isNotEmpty && pub != null && pub.isNotEmpty) {
      return (private: priv, public: pub);
    }
    final keys = await _engine.generateWireGuardKeyPair();
    await _writeStoredSecret(_kWgPrivate, keys.private);
    await _writeStoredSecret(_kWgPublic, keys.public);
    return keys;
  }

  Future<String?> _readStoredSecret(String key) =>
      ErebrusSecureStorage.read(key);

  Future<void> _writeStoredSecret(String key, String value) =>
      ErebrusSecureStorage.write(key, value);

  Future<void> _deleteStoredSecret(String key) async {
    try {
      await ErebrusSecureStorage.delete(key);
    } catch (_) {}
  }

  /// If the gateway no longer recognizes the current WG public key, retry once
  /// with a freshly generated key pair.
  bool _looksLikeMissingServerConfig(GatewayException e) {
    final lower = e.message.toLowerCase();
    if (lower.contains('node not found')) return false;
    final missingHints = [
      'not found',
      'notfound',
      'no such client',
      'client not found',
      'config not found',
      'invalid public key',
      'public key not found',
      'missing client',
      'unknown client',
    ];
    return missingHints.any(lower.contains);
  }

  Future<void> _rotateWgKeys() async {
    await _deleteStoredSecret(_kWgPrivate);
    await _deleteStoredSecret(_kWgPublic);
    final keys = await _engine.generateWireGuardKeyPair();
    await _writeStoredSecret(_kWgPrivate, keys.private);
    await _writeStoredSecret(_kWgPublic, keys.public);
  }

  String _clientName() {
    final platform = defaultTargetPlatform.name;
    return 'erebrus-$platform-${DateTime.now().millisecondsSinceEpoch % 100000}';
  }
}
