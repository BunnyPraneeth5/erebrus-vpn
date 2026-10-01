import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'gateway_config.dart';
import 'gateway_http.dart';
import 'vpn_models.dart';

export 'gateway_config.dart' show kDefaultGatewayUrl, kGatewayUrl, kTrialPeriodDays, resolveGatewayUrl;

/// Thin HTTP client for the Erebrus gateway discovery + provisioning APIs.
class GatewayClient {
  GatewayClient({String? baseUrl, this._bearerToken})
    : _base = GatewayHttp.normalizeBase(baseUrl ?? resolveGatewayUrl());

  final Uri _base;
  String? _bearerToken;

  /// Notifies the auth owner when a bearer-authenticated gateway call returns
  /// 401. Public failures and permission-denied responses do not trigger it.
  Future<void> Function()? onSessionExpired;

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
        final is404 = e.message.contains('404') || e.message.toLowerCase().contains('not found');
        if (!is404) rethrow;
      }
    }
    throw lastError ?? GatewayException('Gateway registry not found at $baseUrl');
  }

  /// Fetches the nodes belonging to every org the signed-in user is a member of
  /// (`GET /api/v2/operator/nodes`). Includes private org nodes. Each node carries
  /// an embedded `org` summary used to group nodes by organization. Requires a
  /// bearer token; returns an empty list when unauthenticated.
  Future<List<VpnNode>> fetchOrgNodes() async {
    if (_bearerToken == null || _bearerToken!.isEmpty) return const [];
    final decoded = await _getJson('/api/v2/operator/nodes');
    return _parseNodes(decoded);
  }

  /// Fetches the organizations the signed-in user belongs to (`GET /api/v2/orgs`).
  /// Requires a bearer token; returns an empty list when unauthenticated.
  Future<List<VpnOrg>> fetchOrgs() async {
    if (_bearerToken == null || _bearerToken!.isEmpty) return const [];
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
    } on GatewayException {
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
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt == 0) {
        try {
          await GatewayHttp.preflightHost(uri.host);
        } on Object catch (e) {
          lastError = e;
          if (GatewayHttp.isTransientNetworkError(e)) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            continue;
          }
          rethrow;
        }
      }
      final client = GatewayHttp.createClient();
      try {
        final req = await client.openUrl(method, uri);
        GatewayHttp.applyHeaders(req, bearerToken: _bearerToken, jsonBody: body != null);
        if (body != null) {
          final encoded = jsonEncode(body);
          req.contentLength = utf8.encode(encoded).length;
          req.write(encoded);
        }
        final res = await req.close();
        final text = await utf8.decodeStream(res);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          final hadBearer = _bearerToken != null && _bearerToken!.isNotEmpty;
          final error = GatewayException(
            GatewayHttp.errorMessage(res.statusCode, text),
            statusCode: res.statusCode,
            code: GatewayHttp.errorCode(text),
            details: GatewayHttp.errorDetails(text),
          );
          if (hadBearer && error.isSessionExpired) {
            // Do not await here: a 401 may originate inside GatewayController's
            // own refresh operation, while logout also resets that controller.
            // Waiting would create a refresh -> logout -> refresh cycle.
            final callback = onSessionExpired;
            if (callback != null) unawaited(callback());
          }
          throw error;
        }
        if (text.isEmpty) return const {};
        return jsonDecode(text);
      } on SocketException catch (e) {
        lastError = e;
        if (attempt == 0 && GatewayHttp.isTransientNetworkError(e)) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        throw GatewayException('Cannot reach $baseUrl (${e.message})');
      } on TimeoutException catch (e) {
        lastError = e;
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        throw GatewayException('Cannot reach $baseUrl (timed out)');
      } on FormatException {
        throw GatewayException('Gateway returned invalid JSON');
      } finally {
        client.close(force: true);
      }
    }
    throw GatewayException('Cannot reach $baseUrl (${lastError ?? 'unknown error'})');
  }

}

class GatewayException implements Exception {
  GatewayException(this.message, {this.statusCode, this.code, this.details});
  final String message;
  final int? statusCode;
  final String? code;

  /// Optional structured details from the gateway (e.g. device limit counts).
  final Map<String, dynamic>? details;

  bool get isSessionExpired => statusCode == HttpStatus.unauthorized;

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

  /// Paused by the gateway because the plan no longer covers this device.
  bool get isPlanPaused => status == 'suspended_plan_limit';

  factory VpnClientRow.fromJson(Map<String, dynamic> j) => VpnClientRow(
    id: (j['id'] ?? '').toString(),
    nodeId: (j['node_id'] ?? '').toString(),
    wgPublicKey: (j['wg_public_key'] ?? '').toString(),
    status: (j['status'] ?? '').toString(),
  );
}
