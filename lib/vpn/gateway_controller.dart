import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../auth/wallet_auth_controller.dart';
import 'credential_cache.dart';
import 'gateway_client.dart';
import 'vpn_controller.dart';
import 'vpn_models.dart';
import 'vpn_session_store.dart';

/// Loads the gateway node lists and wires [VpnController.provisioner].
///
/// Two lists are exposed for the picker's Public / Private tabs:
/// [publicNodes] (public discovery, `GET /api/v2/nodes`) and [orgNodes] (the
/// caller's org nodes incl. private, `GET /api/v2/operator/nodes`). [nodes] is
/// the de-duplicated union used for node selection, reconciliation and the
/// connect screen.
class GatewayController extends GetxController {
  GatewayController({GatewayClient? client, String? gatewayUrl})
    : _client = client ?? GatewayClient(baseUrl: gatewayUrl);

  final GatewayClient _client;
  GatewayClient get client => _client;
  final _bundleCache = CredentialCache();

  /// Union of public + org nodes (selection / reconcile / connect screen).
  final nodes = <VpnNode>[].obs;

  /// Organizations the signed-in user belongs to (empty when logged out).
  final orgs = <VpnOrg>[].obs;

  final loading = false.obs;
  final error = RxnString();
  final warning = RxnString();
  late final RxString gatewayUrl;

  List<VpnNode> _publicNodes = const [];
  Map<String, List<VpnNode>> _orgNodesBySlug = {};

  Timer? _refreshTimer;
  Future<void>? _refreshInFlight;
  static const _registryPollInterval = Duration(minutes: 2);

  @override
  void onInit() {
    super.onInit();
    gatewayUrl = _client.baseUrl.obs;
    if (Get.isRegistered<WalletAuthController>()) {
      final auth = Get.find<WalletAuthController>();
      _client.setBearerToken(auth.bearerToken);
      _client.sessions = auth.sessions;
    }
    _wireProvisioner();
    _refreshTimer = Timer.periodic(_registryPollInterval, (_) {
      refreshNodes(silent: true);
    });
  }

  @override
  void onClose() {
    _refreshTimer?.cancel();
    super.onClose();
  }

  void setBearerToken(String? token) => _client.setBearerToken(token);

  Future<void> clearLocalCaches() => _bundleCache.clearAll();

  /// Online public discovery nodes (draining/offline filtered).
  List<VpnNode> get publicNodes =>
      _publicNodes.where((n) => !n.isDraining && !n.isOffline).toList();

  /// Online org nodes across every org the user belongs to (incl. private).
  List<VpnNode> get orgNodes {
    final out = <VpnNode>[];
    for (final list in _orgNodesBySlug.values) {
      for (final n in list) {
        if (!n.isDraining && !n.isOffline) out.add(n);
      }
    }
    return out;
  }

  void _wireProvisioner() {
    final vpn = Get.find<VpnController>();
    vpn.provisioner =
        ({
          required VpnNode node,
          required String wgPublicKey,
          required String name,
        }) async {
          try {
            final bundle = await _client.provisionClient(
              nodeId: node.id,
              wgPublicKey: wgPublicKey,
              name: name,
            );
            await _bundleCache.write(
              nodeId: node.id,
              wgPublicKey: wgPublicKey,
              bundle: bundle,
            );
            return bundle;
          } on GatewayException catch (e) {
            // Authentication and connected-device admission failures are
            // authoritative; cached credentials must not bypass either.
            if (e.blocksProvisioningFallback) rethrow;
            final cached = await _bundleCache.read(
              nodeId: node.id,
              wgPublicKey: wgPublicKey,
            );
            if (cached != null && cached.hasWireGuard && cached.hasStealth) {
              debugPrint(
                '[Gateway] using cached credential bundle for ${node.name}',
              );
              return cached;
            }
            final reused = await _client.fetchExistingClientBundle(
              nodeId: node.id,
              wgPublicKey: wgPublicKey,
            );
            if (reused != null) {
              debugPrint(
                '[Gateway] reusing existing VPN client for ${node.name}',
              );
              await _bundleCache.write(
                nodeId: node.id,
                wgPublicKey: wgPublicKey,
                bundle: reused,
              );
              return reused;
            }
            rethrow;
          }
        };
  }

  /// Fetches the live node registry (public pool + the caller's org nodes).
  Future<void> refreshNodes({bool silent = false}) {
    final existing = _refreshInFlight;
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _refreshNodesOnce(silent: silent).whenComplete(() {
      if (identical(_refreshInFlight, operation)) _refreshInFlight = null;
    });
    _refreshInFlight = operation;
    return operation;
  }

  Future<void> _refreshNodesOnce({required bool silent}) async {
    if (!silent) loading.value = true;
    error.value = null;
    if (!silent) warning.value = null;
    final previous = List<VpnNode>.from(nodes);
    try {
      _publicNodes = await _client.fetchNodes();
      await _refreshOrgScope(); // best-effort; sets orgs + org node buffer
      _applyNodes();
      if (nodes.isEmpty) {
        warning.value = 'No servers available — try refresh again in a moment';
      }
      debugPrint(
        '[Gateway] ${publicNodes.length} public + ${orgNodes.length} org node(s)',
      );
    } on GatewayException catch (e) {
      debugPrint('[Gateway] error: ${e.message}');
      error.value = '${e.message} · ${gatewayUrl.value}';
      _restorePreviousOrClear(previous);
    } catch (e) {
      debugPrint('[Gateway] error: $e');
      error.value = e.toString();
      _restorePreviousOrClear(previous);
    } finally {
      if (!silent) loading.value = false;
    }
  }

  /// Refreshes [orgs] and the per-org node buffer. Logged-out users (no bearer)
  /// get empty results; transient auth/network errors keep the prior buffers.
  Future<void> _refreshOrgScope() async {
    try {
      final fetchedOrgs = await _client.fetchOrgs();
      final fetchedNodes = await _client.fetchOrgNodes();

      final bySlug = <String, List<VpnNode>>{};
      for (final n in fetchedNodes) {
        final slug = n.org?.slug;
        if (slug == null || slug.isEmpty) continue;
        (bySlug[slug] ??= <VpnNode>[]).add(n);
      }
      _orgNodesBySlug = bySlug;

      // Authoritative /orgs list, plus any org that has nodes but wasn't returned.
      final merged = <VpnOrg>[...fetchedOrgs];
      final known = merged.map((o) => o.slug).toSet();
      for (final entry in bySlug.entries) {
        if (known.contains(entry.key)) continue;
        final orgBlock = entry.value.first.org;
        merged.add(
          VpnOrg(
            name: orgBlock?.name ?? entry.key,
            slug: entry.key,
            verificationStatus: orgBlock?.verified == true
                ? 'verified'
                : orgBlock?.verificationStatus,
          ),
        );
        known.add(entry.key);
      }
      orgs.assignAll(merged);
    } catch (e) {
      debugPrint('[Gateway] org nodes unavailable: $e');
    }
  }

  /// Rebuilds [nodes] as the de-duplicated union and reconciles VPN selection.
  void _applyNodes() {
    final seen = <String>{};
    final union = <VpnNode>[];
    for (final n in [...publicNodes, ...orgNodes]) {
      if (seen.add(n.id)) union.add(n);
    }
    nodes.assignAll(union);
    _reconcileSelection(union);
    if (Get.isRegistered<VpnController>()) {
      Get.find<VpnController>().reconcileNodeFromGateway();
    }
  }

  void _restorePreviousOrClear(List<VpnNode> previous) {
    if (previous.isNotEmpty) {
      warning.value = 'Showing last known servers — refresh failed';
      nodes.assignAll(previous);
    } else {
      nodes.clear();
      _reconcileSelection(const []);
    }
  }

  void _reconcileSelection(List<VpnNode> list) {
    final vpn = Get.find<VpnController>();
    final current = vpn.selectedNode.value;

    if (current != null) {
      VpnNode? match;
      for (final n in list) {
        if (n.id == current.id) {
          match = n;
          break;
        }
      }
      if (match != null) {
        vpn.selectNode(match);
        return;
      }
      if (!vpn.isConnected && !vpn.killSwitchBlocking.value) {
        vpn.clearSelectedNode();
        if (list.isNotEmpty) {
          vpn.selectNode(list.first);
          warning.value ??=
              'Previous server is no longer available — picked ${list.first.name}';
        } else {
          warning.value ??= 'Previous server is no longer available';
        }
        return;
      }
    }

    if (current == null && list.isNotEmpty && !vpn.isConnected) {
      vpn.selectNode(list.first);
    }
  }

  /// Clears VPN-side persisted state (bundles, session snapshot, WG keys) and
  /// org data (e.g. on logout).
  Future<void> resetVpnLocalState() async {
    orgs.clear();
    _orgNodesBySlug = {};
    _publicNodes = const [];
    nodes.clear();
    await clearLocalCaches();
    await VpnSessionStore.clear();
    if (Get.isRegistered<VpnController>()) {
      await Get.find<VpnController>().resetLocalVpnData();
    }
    await refreshNodes();
  }
}
