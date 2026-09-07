import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../platform/platform_capabilities.dart';
import 'gateway_http.dart';

/// User-facing connection modes shown in the UI.
enum ConnectMode { auto, stealth, wireguard }

extension ConnectModeX on ConnectMode {
  String get label => switch (this) {
    ConnectMode.auto => 'Auto',
    ConnectMode.stealth => 'Stealth',
    ConnectMode.wireguard => 'WireGuard',
  };

  String get blurb => switch (this) {
    ConnectMode.auto => 'Fastest path, falls back to stealth if blocked',
    ConnectMode.stealth => 'Disguises traffic as normal HTTPS / QUIC',
    ConnectMode.wireguard => 'Fast direct tunnel for normal use',
  };

  /// Ordered transports the controller tries for this mode.
  List<Transport> get transports => switch (this) {
    ConnectMode.auto => const [
      Transport.wireguard,
      Transport.vlessReality,
      Transport.hysteria2,
    ],
    ConnectMode.stealth => const [Transport.vlessReality, Transport.hysteria2],
    ConnectMode.wireguard => const [Transport.wireguard],
  };
}

/// Concrete transport the sing-box engine runs.
enum Transport { wireguard, vlessReality, hysteria2 }

extension TransportX on Transport {
  String get label => switch (this) {
    Transport.wireguard => 'WireGuard',
    Transport.vlessReality => 'VLESS · REALITY',
    Transport.hysteria2 => 'Hysteria2',
  };

  /// UI protocol segment for the transport actually running the tunnel.
  ConnectMode get connectMode => switch (this) {
    Transport.wireguard => ConnectMode.wireguard,
    Transport.vlessReality || Transport.hysteria2 => ConnectMode.stealth,
  };
}

/// Org summary embedded on gateway node discovery (`GET /api/v2/nodes`) and the
/// operator node view (`GET /api/v2/operator/nodes`). Mirrors the gateway
/// `orgSummary` shape (api/org_views.go): `verification_status` (string),
/// `slug`, `display_name`, `description`, `website_url`, `plan`, and `id` (only
/// present for any org member).
class VpnNodeOrg {
  const VpnNodeOrg({
    required this.name,
    this.id,
    this.kind,
    this.verified = false,
    this.verificationStatus,
    this.slug,
    this.displayName,
    this.description,
    this.website,
    this.plan,
  });

  final String name;
  final String? id;
  final String? kind;

  /// Derived from [verificationStatus] == 'verified'.
  final bool verified;
  final String? verificationStatus;
  final String? slug;
  final String? displayName;
  final String? description;
  final String? website;
  final String? plan;

  /// Preferred display label: `display_name` falls back to `name`.
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : name;

  factory VpnNodeOrg.fromJson(Map<String, dynamic> j) {
    String? str(String key) {
      final v = (j[key] ?? '').toString().trim();
      return v.isEmpty ? null : v;
    }

    final verificationStatus = str('verification_status');
    return VpnNodeOrg(
      name: (j['name'] ?? '').toString(),
      id: str('id'),
      kind: str('kind'),
      // Gateway sends `verification_status`; tolerate a legacy bool `verified`.
      verified: verificationStatus == 'verified' || j['verified'] == true,
      verificationStatus: verificationStatus,
      slug: str('slug'),
      displayName: str('display_name'),
      description: str('description'),
      // Gateway field is `website_url`; tolerate legacy `website`.
      website: str('website_url') ?? str('website'),
      plan: str('plan'),
    );
  }
}

/// An organization the signed-in user belongs to (`GET /api/v2/orgs`). The org
/// UUID (`id`) is returned for any org member; [slug] is always present
/// and is the stable key used to scope nodes to an org.
class VpnOrg {
  const VpnOrg({
    required this.name,
    required this.slug,
    this.id,
    this.role,
    this.plan,
    this.verificationStatus,
  });

  final String name;
  final String slug;
  final String? id;
  final String? role;
  final String? plan;
  final String? verificationStatus;

  bool get verified => verificationStatus == 'verified';

  factory VpnOrg.fromJson(Map<String, dynamic> j) {
    String? str(String key) {
      final v = (j[key] ?? '').toString().trim();
      return v.isEmpty ? null : v;
    }

    return VpnOrg(
      name: (j['name'] ?? '').toString(),
      slug: (j['slug'] ?? '').toString(),
      id: str('id'),
      role: str('role'),
      plan: str('plan'),
      verificationStatus: str('verification_status'),
    );
  }
}

/// Capability flags advertised by a node.
class VpnNodeCapabilities {
  const VpnNodeCapabilities({
    this.accessMode,
    this.appHosting = false,
    this.wildcardDomain,
  });

  final String? accessMode;
  final bool appHosting;
  final String? wildcardDomain;

  factory VpnNodeCapabilities.fromJson(Map<String, dynamic> j) {
    final wildcard = (j['wildcard_domain'] ?? '').toString().trim();
    final accessMode = (j['access_mode'] ?? '').toString().trim();
    return VpnNodeCapabilities(
      accessMode: accessMode.isEmpty ? null : accessMode,
      appHosting: j['app_hosting'] == true,
      wildcardDomain: wildcard.isEmpty ? null : wildcard,
    );
  }
}

/// A node from the gateway discovery list (`GET /api/v2/nodes`).
class VpnNode {
  VpnNode({
    required this.id,
    required this.name,
    required this.region,
    required this.did,
    required this.protocols,
    required this.loadPct,
    this.status = 'online',
    this.accessMode = 'public',
    this.deploymentProfile = 'standard',
    this.minTier = 0,
    this.zone,
    this.peerId,
    this.walletAddress,
    this.chain,
    this.ipHash,
    this.version,
    this.rxBytes,
    this.txBytes,
    this.lastHeartbeat,
    this.lastPeerHandshake,
    this.createdAt,
    this.latencyMs,
    this.downloadMbps,
    this.uploadMbps,
    this.speedtestMeasuredAt,
    this.org,
    this.capabilities,
    this.probeHost,
    this.probePorts = const [],
    this.wgPeersRegistered,
    this.wgPeersConnected,
    this.acceptingClients,
  });

  final String id;
  final String name;
  final String region;
  final String did;
  final List<String> protocols;
  final double loadPct;
  final String status;
  final String accessMode;

  /// Node type: `standard` | `shield` | `sentinel`.
  final String deploymentProfile;
  final int minTier;
  final String? zone;
  final String? peerId;
  final String? walletAddress;
  final String? chain;
  final String? ipHash;
  final String? version;
  final int? rxBytes;
  final int? txBytes;
  final String? lastHeartbeat;
  final String? lastPeerHandshake;
  final String? createdAt;
  final int? latencyMs;
  final double? downloadMbps;
  final double? uploadMbps;
  final int? speedtestMeasuredAt;
  final VpnNodeOrg? org;
  final VpnNodeCapabilities? capabilities;
  final String? probeHost;
  final List<int> probePorts;
  final int? wgPeersRegistered;
  final int? wgPeersConnected;
  final bool? acceptingClients;

  bool get supportsStealth =>
      protocols.contains('vless-reality') || protocols.contains('hysteria2');

  bool get isDraining => status.toLowerCase() == 'draining';
  bool get isOffline => status.toLowerCase() == 'offline';
  bool get isPrivateAccess => accessMode.toLowerCase() == 'private';

  bool get isShield => deploymentProfile.toLowerCase() == 'shield';
  bool get isSentinel => deploymentProfile.toLowerCase() == 'sentinel';
  bool get isStandard => deploymentProfile.toLowerCase() == 'standard';

  /// Human node-type label for the private picker (Standard / Shield / Sentinel).
  String get nodeTypeLabel {
    switch (deploymentProfile.toLowerCase()) {
      case 'shield':
        return 'Shield';
      case 'sentinel':
        return 'Sentinel';
      default:
        return 'Standard';
    }
  }

  bool get requiresHigherTier => minTier > 0;

  bool get hasLatency => latencyMs != null && latencyMs! > 0;
  bool get hasDownloadMbps => downloadMbps != null && downloadMbps! > 0;
  bool get hasUploadMbps => uploadMbps != null && uploadMbps! > 0;

  /// Node-reported Cloudflare speedtest (node → internet), not phone → node.
  bool get hasReportedSpeedtest =>
      speedtestMeasuredAt != null &&
      speedtestMeasuredAt! > 0 &&
      (hasLatency || hasDownloadMbps || hasUploadMbps);

  bool get hasHeartbeat => lastHeartbeat != null && lastHeartbeat!.isNotEmpty;

  bool get hasPeerHandshake =>
      lastPeerHandshake != null && lastPeerHandshake!.isNotEmpty;

  bool get isSolana => chain?.toUpperCase() == 'SOLANA';

  bool get canProbe =>
      probeHost != null && probeHost!.isNotEmpty && probePorts.isNotEmpty;

  /// True when the node is online and has room for another VPN peer.
  bool get canAcceptClients => acceptingClients != false && !isOffline;

  String get protocolsLabel {
    final parts = <String>[];
    if (protocols.contains('wireguard')) parts.add('WG');
    if (protocols.contains('vless-reality')) parts.add('VLESS');
    if (protocols.contains('hysteria2')) parts.add('Hy2');
    return parts.isEmpty ? 'VPN' : parts.join(' · ');
  }

  factory VpnNode.fromJson(Map<String, dynamic> j) {
    final caps = (j['capabilities'] as Map?)?.cast<String, dynamic>();
    final speedtest = (j['speedtest'] as Map?)?.cast<String, dynamic>();
    final orgMap = (j['org'] as Map?)?.cast<String, dynamic>();
    final org = orgMap == null ? null : VpnNodeOrg.fromJson(orgMap);
    final endpoints = (j['endpoints'] as Map?)?.cast<String, dynamic>();
    final probe = _parseProbeTargets(endpoints);
    final zone = (j['zone'] ?? '').toString().trim();
    final peerId = (j['peer_id'] ?? '').toString().trim();
    final walletAddress = (j['wallet_address'] ?? '').toString().trim();
    final chain = (j['chain'] ?? '').toString().trim();
    final ipHash = (j['ip_hash'] ?? '').toString().trim();
    final version = (j['version'] ?? '').toString().trim();
    final lastHeartbeat = (j['last_heartbeat'] ?? '').toString().trim();
    final lastPeerHandshake = (j['last_peer_handshake'] ?? '')
        .toString()
        .trim();
    final createdAt = (j['created_at'] ?? '').toString().trim();
    return VpnNode(
      id: (j['node_id'] ?? j['id'] ?? '').toString(),
      name: (j['name'] ?? 'Erebrus node').toString(),
      region: (j['region'] ?? '').toString(),
      did: (j['did'] ?? '').toString(),
      protocols: ((j['protocols'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      loadPct: (j['load_pct'] as num?)?.toDouble() ?? 0,
      status: (j['status'] ?? 'online').toString(),
      accessMode: (j['access_mode'] ?? caps?['access_mode'] ?? 'public')
          .toString(),
      deploymentProfile: (j['deployment_profile'] ?? 'standard').toString(),
      minTier: (j['min_tier'] as num?)?.toInt() ?? 0,
      zone: zone.isEmpty ? null : zone,
      peerId: peerId.isEmpty ? null : peerId,
      walletAddress: walletAddress.isEmpty ? null : walletAddress,
      chain: chain.isEmpty ? null : chain,
      ipHash: ipHash.isEmpty ? null : ipHash,
      version: version.isEmpty ? null : version,
      rxBytes: (j['rx_bytes'] as num?)?.toInt(),
      txBytes: (j['tx_bytes'] as num?)?.toInt(),
      lastHeartbeat: lastHeartbeat.isEmpty ? null : lastHeartbeat,
      lastPeerHandshake: lastPeerHandshake.isEmpty ? null : lastPeerHandshake,
      createdAt: createdAt.isEmpty ? null : createdAt,
      latencyMs: (speedtest?['latency_ms'] as num?)?.toInt(),
      downloadMbps: (speedtest?['download_mbps'] as num?)?.toDouble(),
      uploadMbps: (speedtest?['upload_mbps'] as num?)?.toDouble(),
      speedtestMeasuredAt: (speedtest?['measured_at'] as num?)?.toInt(),
      org: org,
      capabilities: caps == null ? null : VpnNodeCapabilities.fromJson(caps),
      probeHost: probe.$1,
      probePorts: probe.$2,
      wgPeersRegistered: (j['wg_peers_registered'] as num?)?.toInt(),
      wgPeersConnected: (j['wg_peers_connected'] as num?)?.toInt(),
      acceptingClients: j['accepting_clients'] == true
          ? true
          : (j['accepting_clients'] == false ? false : null),
    );
  }

  static (String?, List<int>) _parseProbeTargets(
    Map<String, dynamic>? endpoints,
  ) {
    if (endpoints == null) return (null, const []);
    final wg = (endpoints['wireguard'] as Map?)?.cast<String, dynamic>();
    final vless = (endpoints['vless_reality'] as Map?)?.cast<String, dynamic>();
    final hy2 = (endpoints['hysteria2'] as Map?)?.cast<String, dynamic>();
    final host = (wg?['host'] ?? '').toString().trim();
    final ports = <int>[];
    void addPort(dynamic value) {
      final port = (value as num?)?.toInt();
      if (port != null && port > 0 && !ports.contains(port)) ports.add(port);
    }

    addPort(vless?['port']);
    addPort(hy2?['port']);
    addPort(wg?['port']);
    return (host.isEmpty ? null : host, ports);
  }
}

/// Sorts nodes for the picker: client ping (if measured) → load → name.
List<VpnNode> sortNodesForPicker(
  Iterable<VpnNode> nodes, {
  Map<String, int>? clientPingMs,
}) {
  final list = nodes.toList();
  list.sort((a, b) => _compareNodesForPicker(a, b, clientPingMs: clientPingMs));
  return list;
}

int _clientPingSortKey(VpnNode node, Map<String, int>? clientPingMs) {
  final ms = clientPingMs?[node.id];
  if (ms == null || ms <= 0) return 1 << 20;
  return ms;
}

int _compareNodesForPicker(
  VpnNode a,
  VpnNode b, {
  Map<String, int>? clientPingMs,
}) {
  // Prefer nodes that are actively accepting new clients.
  final aAccept = a.canAcceptClients ? 1 : 0;
  final bAccept = b.canAcceptClients ? 1 : 0;
  if (aAccept != bAccept) return bAccept - aAccept;

  if (clientPingMs != null && clientPingMs.isNotEmpty) {
    final ping = _clientPingSortKey(
      a,
      clientPingMs,
    ).compareTo(_clientPingSortKey(b, clientPingMs));
    if (ping != 0) return ping;
  }

  final load = a.loadPct.compareTo(b.loadPct);
  if (load != 0) return load;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// The unified credential bundle returned by the gateway when a VPN client is
/// provisioned (`POST /api/v2/vpn/clients`) — it is the node's bundle: a
/// WireGuard config plus carrier share URIs and a ready sing-box profile.
class CredentialBundle {
  CredentialBundle({
    required this.serverPublicKey,
    required this.endpoint,
    required this.address,
    required this.dns,
    required this.vlessUri,
    required this.hysteria2Uri,
    required this.singboxProfile,
  });

  final String serverPublicKey;
  final String endpoint; // host:port of the node's WireGuard listener
  final String address; // client tunnel address CIDR, e.g. 10.0.0.2/32
  final String dns;
  final String vlessUri;
  final String hysteria2Uri;
  final Map<String, dynamic> singboxProfile;

  factory CredentialBundle.fromJson(Map<String, dynamic> j) {
    final wg = (j['wireguard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final profile =
        (j['singbox_profile'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    // Gateway may put the WG endpoint at wireguard.endpoint or transports[0].uri.
    var endpoint = (wg['endpoint'] ?? '').toString();
    if (endpoint.isEmpty) {
      final transports = (j['transports'] as List?) ?? const [];
      for (final t in transports) {
        if (t is Map && (t['kind'] ?? '').toString().contains('wireguard')) {
          endpoint = (t['uri'] ?? '').toString();
          break;
        }
      }
    }
    return CredentialBundle(
      serverPublicKey: (wg['server_public_key'] ?? '').toString(),
      endpoint: endpoint,
      address: (wg['address'] ?? '').toString(),
      dns: (wg['dns'] ?? '1.1.1.1').toString(),
      vlessUri: (j['vless_uri'] ?? '').toString(),
      hysteria2Uri: (j['hysteria2_uri'] ?? '').toString(),
      singboxProfile: profile,
    );
  }

  Map<String, dynamic> toJson() => {
    'wireguard': {
      'server_public_key': serverPublicKey,
      'endpoint': endpoint,
      'address': address,
      'dns': dns,
    },
    'vless_uri': vlessUri,
    'hysteria2_uri': hysteria2Uri,
    'singbox_profile': singboxProfile,
  };

  bool get hasWireGuard =>
      serverPublicKey.isNotEmpty && endpoint.isNotEmpty && address.isNotEmpty;

  bool get hasStealth =>
      singboxProfile.isNotEmpty &&
      (vlessUri.isNotEmpty || hysteria2Uri.isNotEmpty);

  /// Host:port the client actually dials for [transport] (for logs / diagnostics).
  String dialTarget(Transport transport) {
    switch (transport) {
      case Transport.wireguard:
        return endpoint;
      case Transport.vlessReality:
        final m = RegExp(
          r'^vless://[^@]+@([^:/?#]+):(\d+)',
        ).firstMatch(vlessUri);
        if (m != null) return '${m.group(1)}:${m.group(2)}';
        return endpoint;
      case Transport.hysteria2:
        final m = RegExp(
          r'^hysteria2://[^@]+@([^:/?#]+):(\d+)',
        ).firstMatch(hysteria2Uri);
        if (m != null) return '${m.group(1)}:${m.group(2)}';
        return endpoint;
    }
  }
}

/// Builds the sing-box configuration the on-device engine runs, from a
/// credential bundle, a chosen transport, and the client's locally-held
/// WireGuard private key. WireGuard is always the endpoint; stealth transports
/// wrap it (the node profile already encodes the carriers + REALITY params).
class SingboxConfigBuilder {
  static const String clientKeyPlaceholder = 'REPLACE_WITH_CLIENT_PRIVATE_KEY';
  static const String wgEndpointTag = 'wg-out';
  static const String carrierVlessTag = 'carrier-vless';
  static const String carrierHy2Tag = 'carrier-hysteria2';

  /// sing-box TUN address. [tunDnsAddress] is the tunnel DNS resolver on-device.
  static const String tunAddress = '172.19.0.1/30';
  static const String tunDnsAddress = '172.19.0.2';

  /// Local mixed inbound used by desktop system proxy mode and explicit tunnel
  /// health probes. Mobile WebViews travel through the system TUN directly.
  static const String localProxyHost = '127.0.0.1';
  static const int localProxyPort = 10808;
  static const String localMixedInboundTag = 'mixed-in';

  /// Enables the local Clash API so the app can read live traffic stats.
  static Map<String, dynamic> _withClashApi(Map<String, dynamic> config) {
    final out = Map<String, dynamic>.from(config);
    final experimental = Map<String, dynamic>.from(
      (out['experimental'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    final secret = _generateClashApiSecret();
    experimental['clash_api'] = {
      'external_controller': '127.0.0.1:9090',
      'secret': secret,
    };
    out['experimental'] = experimental;
    return out;
  }

  static String _generateClashApiSecret() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return base64Encode(bytes);
  }

  /// Resolves dial hostnames to IPv4 so WireGuard can handshake before tunnel DNS
  /// (hostname → dns-remote → wg-out chicken-and-egg on Android).
  static Future<Map<String, String>> resolveDialHosts(
    CredentialBundle bundle,
  ) async {
    final hosts = <String>{};
    final (wgHost, _) = _splitHostPort(bundle.endpoint);
    if (wgHost.isNotEmpty && !_isIpLiteral(wgHost)) hosts.add(wgHost);

    for (final t in Transport.values) {
      if (t == Transport.wireguard) continue;
      final target = bundle.dialTarget(t);
      final (h, _) = _splitHostPort(target);
      if (h.isNotEmpty && !_isIpLiteral(h)) hosts.add(h);
    }

    final out = <String, String>{};
    for (final host in hosts) {
      try {
        final ips = await GatewayHttp.resolveHost(host);
        if (ips.isNotEmpty) {
          out[host] = ips.first.address;
          debugPrint('[VPN] resolved dial host $host → ${ips.first.address}');
        }
      } catch (e) {
        debugPrint('[VPN] dial host resolve failed for $host: $e');
      }
    }
    return out;
  }

  static String _peerHost(String host, Map<String, String>? resolvedHosts) {
    if (host.isEmpty) return host;
    return resolvedHosts?[host] ?? host;
  }

  /// Returns a complete sing-box config map for [transport]. [clientPrivateKey]
  /// is the base64 WireGuard private key generated and stored on-device.
  static Map<String, dynamic> build({
    required CredentialBundle bundle,
    required Transport transport,
    required String clientPrivateKey,

    /// When false (desktop CLI / unsigned macOS), only the local mixed proxy
    /// inbound is used — no TUN (avoids needing root). Pair with system HTTP proxy.
    bool useSystemTunnel = true,

    /// Hostname → IPv4 from [resolveDialHosts]; avoids WG handshake DNS deadlock.
    Map<String, String>? resolvedHosts,
  }) {
    if (!bundle.hasWireGuard) {
      throw StateError('credential bundle is missing wireguard fields');
    }
    if (transport == Transport.wireguard) {
      return _buildDirectWireGuard(
        bundle: bundle,
        clientPrivateKey: clientPrivateKey,
        useSystemTunnel: useSystemTunnel,
        resolvedHosts: resolvedHosts,
      );
    }
    return _buildStealth(
      bundle: bundle,
      transport: transport,
      clientPrivateKey: clientPrivateKey,
      useSystemTunnel: useSystemTunnel,
      resolvedHosts: resolvedHosts,
    );
  }

  /// Direct UDP WireGuard — mirrors the gateway's `client_conf` / wg-quick layout.
  static Map<String, dynamic> _buildDirectWireGuard({
    required CredentialBundle bundle,
    required String clientPrivateKey,
    bool useSystemTunnel = true,
    Map<String, String>? resolvedHosts,
  }) {
    final (host, port) = _splitHostPort(bundle.endpoint);
    final peerHost = _peerHost(host, resolvedHosts);
    final clientAddr = bundle.address.contains('/')
        ? bundle.address
        : '${bundle.address}/32';
    final dnsServer = bundle.dns.isNotEmpty ? bundle.dns : '1.1.1.1';

    return _withClashApi({
      'log': {'level': 'info'},
      'dns': _dnsConfig(
        remoteServer: dnsServer,
        wgTag: wgEndpointTag,
        tunInbound: useSystemTunnel,
        bootstrapDomains: [if (host.isNotEmpty && !_isIpLiteral(host)) host],
      ),
      'inbounds': _inbounds(includeTun: useSystemTunnel),
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'endpoints': [
        {
          'type': 'wireguard',
          'tag': wgEndpointTag,
          'address': [clientAddr],
          'private_key': clientPrivateKey,
          'mtu': 1280,
          'peers': [
            {
              'address': peerHost,
              'port': port,
              'public_key': bundle.serverPublicKey,
              'allowed_ips': ['0.0.0.0/0', '::/0'],
              'persistent_keepalive_interval': 25,
            },
          ],
        },
      ],
      'route': _route(finalTag: wgEndpointTag, wgServerHost: peerHost),
    });
  }

  /// Stealth carriers reuse the node-provided sing-box profile (loopback WG peer).
  static Map<String, dynamic> _buildStealth({
    required CredentialBundle bundle,
    required Transport transport,
    required String clientPrivateKey,
    bool useSystemTunnel = true,
    Map<String, String>? resolvedHosts,
  }) {
    final profile =
        jsonDecode(jsonEncode(bundle.singboxProfile)) as Map<String, dynamic>;
    final endpoints =
        (profile['endpoints'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (endpoints.isEmpty) {
      throw StateError(
        'credential bundle has no sing-box endpoints for stealth',
      );
    }
    final wg = endpoints.first;
    wg['private_key'] = clientPrivateKey;
    if (bundle.address.isNotEmpty) {
      wg['address'] = [
        bundle.address.contains('/') ? bundle.address : '${bundle.address}/32',
      ];
    }
    final peers = (wg['peers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (peers.isNotEmpty && bundle.serverPublicKey.isNotEmpty) {
      peers.first['public_key'] = bundle.serverPublicKey;
    }

    switch (transport) {
      case Transport.vlessReality:
        wg['detour'] = carrierVlessTag;
        break;
      case Transport.hysteria2:
        wg['detour'] = carrierHy2Tag;
        break;
      case Transport.wireguard:
        break;
    }

    final dnsServer = bundle.dns.isNotEmpty ? bundle.dns : '1.1.1.1';
    final profileRoute =
        (profile['route'] as Map?)?.cast<String, dynamic>() ?? const {};
    final extraRules =
        (profileRoute['rules'] as List?)?.cast<Map<String, dynamic>>() ??
        const [];

    final outbounds =
        ((profile['outbounds'] as List?)?.cast<Map<String, dynamic>>() ?? [])
            .map((o) => Map<String, dynamic>.from(o))
            .toList();
    // Node profiles ship carrier outbounds only; local bypass rules need `direct`.
    if (!outbounds.any((o) => o['tag'] == 'direct')) {
      outbounds.add({'type': 'direct', 'tag': 'direct'});
    }
    _patchStealthOutbounds(
      outbounds,
      transport,
      bundle,
      resolvedHosts: resolvedHosts,
    );

    // Dial the carrier (VLESS/Hy2) on the underlying network, not through the TUN.
    final carrierHost = _carrierBypassHost(outbounds, transport, bundle);
    final bypassHost = carrierHost == null
        ? null
        : _peerHost(carrierHost, resolvedHosts);
    // Only the carrier host is dialed on the physical network in stealth — the
    // inner WG peer is the node-local loopback, so bundle.endpoint's host never
    // needs a bootstrap resolver here.
    final bootstrapDomains = <String>{
      if (carrierHost != null &&
          carrierHost.isNotEmpty &&
          !_isIpLiteral(carrierHost))
        carrierHost,
    };

    return _withClashApi({
      'log': {'level': 'info'},
      'dns': _dnsConfig(
        remoteServer: dnsServer,
        wgTag: wgEndpointTag,
        tunInbound: useSystemTunnel,
        bootstrapDomains: bootstrapDomains.toList(),
      ),
      'inbounds': _inbounds(includeTun: useSystemTunnel),
      'endpoints': endpoints,
      'outbounds': outbounds,
      'route': _route(
        finalTag: wgEndpointTag,
        wgServerHost: bypassHost ?? carrierHost,
        extraRules: extraRules,
      ),
    });
  }

  /// Ensures carrier outbounds carry REALITY/TLS params (from [bundle.vlessUri]
  /// when the cached profile is stale or incomplete).
  static void _patchStealthOutbounds(
    List<Map<String, dynamic>> outbounds,
    Transport transport,
    CredentialBundle bundle, {
    Map<String, String>? resolvedHosts,
  }) {
    for (final ob in outbounds) {
      final tag = ob['tag']?.toString() ?? '';
      if (transport == Transport.vlessReality && tag == carrierVlessTag) {
        _patchVlessFromUri(ob, bundle.vlessUri);
      }
      final server = ob['server']?.toString() ?? '';
      if (server.isNotEmpty) {
        ob['server'] = _peerHost(server, resolvedHosts);
      }
    }
  }

  static void _patchVlessFromUri(
    Map<String, dynamic> outbound,
    String vlessUri,
  ) {
    if (vlessUri.isEmpty) return;
    final m = RegExp(
      r'^vless://([^@]+)@([^:/?#]+):(\d+)\?([^#]*)',
    ).firstMatch(vlessUri);
    if (m == null) return;
    final uuid = m.group(1) ?? '';
    final host = m.group(2) ?? '';
    final port = int.tryParse(m.group(3) ?? '') ?? 443;
    final q = Uri.splitQueryString(m.group(4) ?? '');
    if (uuid.isNotEmpty) outbound['uuid'] = uuid;
    if (host.isNotEmpty) outbound['server'] = host;
    outbound['server_port'] = port;
    if (q['flow']?.isNotEmpty == true) outbound['flow'] = q['flow'];
    final tls = Map<String, dynamic>.from(
      (outbound['tls'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    tls['enabled'] = true;
    tls['server_name'] = q['sni'] ?? tls['server_name'] ?? 'www.microsoft.com';
    tls['utls'] = {'enabled': true, 'fingerprint': q['fp'] ?? 'chrome'};
    final reality = Map<String, dynamic>.from(
      (tls['reality'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    if (q['pbk']?.isNotEmpty == true) reality['public_key'] = q['pbk'];
    if (q['sid']?.isNotEmpty == true) reality['short_id'] = q['sid'];
    reality['enabled'] = true;
    tls['reality'] = reality;
    outbound['tls'] = tls;
  }

  static String? _carrierBypassHost(
    List<Map<String, dynamic>> outbounds,
    Transport transport,
    CredentialBundle bundle,
  ) {
    final tag = switch (transport) {
      Transport.vlessReality => carrierVlessTag,
      Transport.hysteria2 => carrierHy2Tag,
      Transport.wireguard => null,
    };
    if (tag != null) {
      for (final ob in outbounds) {
        if (ob['tag'] == tag) {
          final host = ob['server']?.toString() ?? '';
          if (host.isNotEmpty) return host;
        }
      }
    }
    final (host, _) = _splitHostPort(bundle.endpoint);
    return host.isNotEmpty ? host : null;
  }

  // NOTE: the pinned sing-box (v1.11.15) rejects unknown DNS fields at config
  // decode — validate additions with `bin/sing-box/<os>/sing-box check` first.
  static Map<String, dynamic> _dnsConfig({
    required String remoteServer,
    required String wgTag,
    required bool tunInbound,
    List<String> bootstrapDomains = const [],
  }) {
    // Native TUN: bootstrap resolver on the underlying network so peer
    // hostnames can be resolved before the WireGuard endpoint is up.
    final servers = <Map<String, dynamic>>[
      {'tag': 'dns-direct', 'address': '1.1.1.1', 'detour': 'direct'},
      {'tag': 'dns-remote', 'address': remoteServer, 'detour': wgTag},
    ];
    final rules = <Map<String, dynamic>>[
      for (final domain in bootstrapDomains)
        if (domain.isNotEmpty)
          {
            'domain': [domain],
            'server': 'dns-direct',
          },
    ];
    return {
      'servers': servers,
      if (rules.isNotEmpty) 'rules': rules,
      'final': 'dns-remote',
      'strategy': 'prefer_ipv4',
    };
  }

  static List<Map<String, dynamic>> _inbounds({required bool includeTun}) {
    final inbounds = <Map<String, dynamic>>[];
    if (includeTun) {
      inbounds.add({
        'type': 'tun',
        'tag': 'tun-in',
        'address': [tunAddress],
        'auto_route': true,
        'strict_route': true,
        'stack': 'gvisor',
        'sniff': true,
      });
    }
    inbounds.add({
      'type': 'mixed',
      'tag': localMixedInboundTag,
      'listen': localProxyHost,
      'listen_port': localProxyPort,
      'sniff': true,
    });
    return inbounds;
  }

  /// sing-box `ip_cidr` rules require literal IPs; hostnames must use `domain`.
  static bool _isIpLiteral(String host) {
    if (host.contains(':')) {
      // IPv6 — reject zone id and bracketed forms.
      final h = host.replaceAll(RegExp(r'^\[|\]$'), '');
      return RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(h);
    }
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static Map<String, dynamic> _directBypassRule(String host) {
    if (_isIpLiteral(host)) {
      final cidr = host.contains(':') ? '$host/128' : '$host/32';
      return {
        'ip_cidr': [cidr],
        'outbound': 'direct',
      };
    }
    return {
      'domain': [host],
      'outbound': 'direct',
    };
  }

  /// Local/bypass rules that must run before [final]. Tunnel DNS capture comes
  /// first so queries to [tunDnsAddress] reach sing-box's DNS module locally.
  /// (sing-box config action name: `hijack-dns`.)
  static List<Map<String, dynamic>> _localRouteRules({String? wgServerHost}) {
    final rules = <Map<String, dynamic>>[
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {
        'ip_cidr': ['127.0.0.0/8'],
        'outbound': 'direct',
      },
    ];
    if (wgServerHost != null &&
        wgServerHost.isNotEmpty &&
        wgServerHost != '127.0.0.1') {
      rules.insert(0, _directBypassRule(wgServerHost));
    }
    return rules;
  }

  static Map<String, dynamic> _route({
    required String finalTag,
    String? wgServerHost,
    List<Map<String, dynamic>> extraRules = const [],
  }) => {
    'rules': [..._localRouteRules(wgServerHost: wgServerHost), ...extraRules],
    'final': finalTag,
    'auto_detect_interface': true,
  };

  static (String, int) _splitHostPort(String hostPort) {
    // Bracketed IPv6 with port: [2001:db8::1]:51820
    final v6 = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(hostPort);
    if (v6 != null) {
      return (v6.group(1)!, int.tryParse(v6.group(2)!) ?? 51820);
    }
    if (hostPort.startsWith('[') && hostPort.endsWith(']')) {
      return (hostPort.substring(1, hostPort.length - 1), 51820);
    }
    // Bare IPv6 (multiple colons, no brackets) has no port to split off —
    // lastIndexOf(':') would otherwise truncate the address.
    if (hostPort.indexOf(':') != hostPort.lastIndexOf(':')) {
      return (hostPort, 51820);
    }
    final i = hostPort.lastIndexOf(':');
    if (i < 0) return (hostPort, 51820);
    final host = hostPort.substring(0, i);
    final port = int.tryParse(hostPort.substring(i + 1)) ?? 51820;
    return (host, port);
  }

  /// Blocks all traffic when the VPN tunnel drops unexpectedly.
  ///
  /// Desktop (proxy-only) uses the local mixed inbound so the system proxy is
  /// pointed at a dead end; mobile uses the TUN to block system-wide.
  static Map<String, dynamic> killSwitchBlockConfig() {
    if (PlatformCapabilities.usesDesktopVpnRunner) {
      return _withClashApi({
        'log': {'level': 'warn'},
        'inbounds': [
          {
            'type': 'mixed',
            'tag': localMixedInboundTag,
            'listen': localProxyHost,
            'listen_port': localProxyPort,
            'sniff': true,
          },
        ],
        'outbounds': [
          {'type': 'block', 'tag': 'block'},
        ],
        'route': {'final': 'block', 'auto_detect_interface': true},
      });
    }

    return {
      'log': {'level': 'warn'},
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': [tunAddress],
          'auto_route': true,
          'strict_route': true,
          'stack': 'gvisor',
        },
        {
          'type': 'mixed',
          'tag': localMixedInboundTag,
          'listen': localProxyHost,
          'listen_port': localProxyPort,
          'sniff': true,
        },
      ],
      'outbounds': [
        {'type': 'block', 'tag': 'block'},
      ],
      'route': {'final': 'block', 'auto_detect_interface': true},
    };
  }
}
