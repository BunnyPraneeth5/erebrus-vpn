import 'dart:convert';

import 'gateway_config.dart';
import '../auth/auth_repository.dart';
import '../auth/session_exception.dart';
import '../auth/session_transport.dart';
import 'gateway_http.dart';
import 'vpn_models.dart';

export 'gateway_config.dart'
    show kDefaultGatewayUrl, kGatewayUrl, kTrialPeriodDays, resolveGatewayUrl;

/// Thin HTTP client for the Erebrus gateway discovery + provisioning APIs.
class GatewayClient {
  GatewayClient({
    String? baseUrl,
    this._bearerToken,
    AuthRepository? sessions,
    SessionSender? sender,
  }) : _base = GatewayHttp.normalizeBase(baseUrl ?? resolveGatewayUrl()),
       sessions = sessions ?? AuthRepository(gatewayUrl: baseUrl),
       _send = sender ?? sendSessionRequest;

  final Uri _base;
  String? _bearerToken;

  AuthRepository sessions;
  final SessionSender _send;

  void setBearerToken(String? token) => _bearerToken = token;

  String get baseUrl {
    final port = _base.hasPort ? ':${_base.port}' : '';
    return '${_base.scheme}://${_base.host}$port';
  }

  Future<List<VpnNode>> fetchNodes() async {
    GatewayException? lastError;
    for (final query in const [
      {'status': 'online'},
      null,
    ]) {
      try {
        final decoded = await _getJson('/api/v2/nodes', query: query);
        return _parseNodes(decoded);
      } on GatewayException catch (e) {
        lastError = e;
        final is404 =
            e.message.contains('404') ||
            e.message.toLowerCase().contains('not found');
        if (!is404) rethrow;
      }
    }
    throw lastError ??
        GatewayException('Gateway registry not found at $baseUrl');
  }

  /// Fetches the nodes belonging to every org the signed-in user is a member of
  /// (`GET /api/v2/operator/nodes`). Includes private org nodes. Each node carries
  /// an embedded `org` summary used to group nodes by organization. Requires a
  /// bearer token; returns an empty list when unauthenticated.
  Future<List<VpnNode>> fetchOrgNodes() async {
    if (_bearerToken == null && await sessions.restore() == null) {
      return const [];
    }
    final decoded = await _getJson('/api/v2/operator/nodes');
    return _parseNodes(decoded);
  }

  /// Fetches the organizations the signed-in user belongs to (`GET /api/v2/orgs`).
  /// Requires a bearer token; returns an empty list when unauthenticated.
  Future<List<VpnOrg>> fetchOrgs() async {
    if (_bearerToken == null && await sessions.restore() == null) {
      return const [];
    }
    final decoded = await _getJson('/api/v2/orgs');
    final list = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['orgs'] as List?) : null) ?? const [];
    return list
        .map((e) => VpnOrg.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((o) => o.slug.isNotEmpty)
        .toList();
  }

  List<VpnNode> _parseNodes(dynamic decoded) {
    final list = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['nodes'] as List?) : null) ?? const [];
    return list
        .map((e) => VpnNode.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((n) => n.id.isNotEmpty)
        .toList();
  }

  Future<CredentialBundle> provisionClient({
    required String nodeId,
    required String wgPublicKey,
    required String name,
  }) async {
    // Reconnect: reuse the gateway client row + refresh credentials instead of
    // minting a new peer id (avoids node UNIQUE wg_public_key collisions).
    final existing = await fetchExistingClientBundle(
      nodeId: nodeId,
      wgPublicKey: wgPublicKey,
    );
    if (existing != null) return existing;

    try {
      final decoded = await _postJson('/api/v2/vpn/clients', {
        'name': name,
        'node_id': nodeId,
        'wg_public_key': wgPublicKey,
      });
      return CredentialBundle.fromJson(_unwrapBundle(decoded));
    } on GatewayException catch (e) {
      if (e.blocksProvisioningFallback) rethrow;
      final reused = await fetchExistingClientBundle(
        nodeId: nodeId,
        wgPublicKey: wgPublicKey,
      );
      if (reused != null) return reused;
      rethrow;
    }
  }

  /// Returns credentials for an existing gateway client row (same node + WG key).
  Future<CredentialBundle?> fetchExistingClientBundle({
    required String nodeId,
    required String wgPublicKey,
  }) async {
    try {
      final clients = await listVpnClients();
      for (final c in clients) {
        if (c.nodeId != nodeId || c.wgPublicKey != wgPublicKey) continue;
        if (c.status == 'deleting') continue;
        return await fetchClientConfig(c.id);
      }
    } on GatewayException catch (e) {
      if (e.blocksAuthenticatedRequest) rethrow;
    } catch (_) {}
    return null;
  }

  Future<List<VpnClientRow>> listVpnClients() async {
    final decoded = await _getJson('/api/v2/vpn/clients');
    final list = decoded is List
        ? decoded
        : (decoded is Map ? (decoded['clients'] as List?) : null) ?? const [];
    return list
        .map((e) => VpnClientRow.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<CredentialBundle> fetchClientConfig(String clientId) async {
    final decoded = await _getJson('/api/v2/vpn/clients/$clientId/config');
    return CredentialBundle.fromJson(_unwrapBundle(decoded));
  }

  static Map<String, dynamic> _unwrapBundle(dynamic decoded) {
    if (decoded is! Map) {
      throw GatewayException('Unexpected provision response shape');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map.containsKey('wireguard') || map.containsKey('singbox_profile')) {
      return map;
    }
    for (final key in const ['client', 'data', 'bundle', 'credentials']) {
      final nested = map[key];
      if (nested is Map) return Map<String, dynamic>.from(nested);
    }
    return map;
  }

  Future<dynamic> _getJson(String path, {Map<String, String>? query}) =>
      _request('GET', path, query: query);

  Future<dynamic> _postJson(String path, Map<String, dynamic> body) =>
      _request('POST', path, body: body);

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = GatewayHttp.apiUri(_base, path: path, query: query);
    final encoded = body == null ? null : jsonEncode(body);
    try {
      final repository = sessions;
      final response = path != '/api/v2/nodes'
          ? await repository.request(method, uri, body: encoded)
          : await _send(method, uri, body: encoded);
      if (!response.ok) {
        throw GatewayException(
          response.error.message,
          statusCode: response.status,
          code: response.code,
          retryAt: response.retryAt,
        );
      }
      return response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } on AuthException catch (e) {
      throw GatewayException(
        e.message,
        statusCode: e.statusCode,
        code: e.code,
        retryAt: e.retryAt,
      );
    } on FormatException {
      throw GatewayException('Gateway returned invalid JSON');
    }
  }
}

class GatewayException implements Exception {
  GatewayException(this.message, {this.statusCode, this.code, this.retryAt});
  final String message;
  final int? statusCode;
  final String? code;
  final DateTime? retryAt;

  bool get isSessionExpired => const {
    'REFRESH_TOKEN_INVALID',
    'REFRESH_TOKEN_REUSED',
    'SESSION_REVOKED',
  }.contains(code);

  /// A quota rejection is authoritative; cached configs must not bypass it.
  bool get isDeviceLimitReached => code == 'DEVICE_LIMIT_REACHED';

  bool get blocksProvisioningFallback =>
      blocksAuthenticatedRequest || isDeviceLimitReached;

  bool get blocksAuthenticatedRequest =>
      isSessionExpired ||
      statusCode == 401 ||
      code == 'SESSION_CHANGED' ||
      code == 'LOGIN_REQUIRED' ||
      code == 'SESSION_STORAGE_ERROR' ||
      code == 'SESSION_OWNER_UNAVAILABLE';

  @override
  String toString() => message;
}

/// A gateway-side VPN client row (`GET /api/v2/vpn/clients`).
class VpnClientRow {
  VpnClientRow({
    required this.id,
    required this.nodeId,
    required this.wgPublicKey,
    required this.status,
  });

  final String id;
  final String nodeId;
  final String wgPublicKey;
  final String status;

  factory VpnClientRow.fromJson(Map<String, dynamic> j) => VpnClientRow(
    id: (j['id'] ?? '').toString(),
    nodeId: (j['node_id'] ?? '').toString(),
    wgPublicKey: (j['wg_public_key'] ?? '').toString(),
    status: (j['status'] ?? '').toString(),
  );
}
