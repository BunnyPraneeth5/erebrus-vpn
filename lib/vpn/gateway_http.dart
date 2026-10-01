import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dnslib/dnslib.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gateway_config.dart';

/// Shared HTTP helpers for gateway discovery, VPN, and auth clients.
abstract final class GatewayHttp {
  static const _connectTimeout = Duration(seconds: 12);
  static const _lookupRetries = 3;
  static const _lookupRetryDelay = Duration(milliseconds: 350);
  static const _defaultDohPort = 443;
  static const _defaultDohPath = '/dns-query';

  /// Gateway [HttpClient] — DNS preflight only (do not use [HttpClient.connectionFactory]
  /// for HTTPS here; it breaks SNI and the gateway returns 404).
  static HttpClient createClient() {
    final client = HttpClient();
    client.connectionTimeout = _connectTimeout;
    client.idleTimeout = const Duration(seconds: 15);
    return client;
  }

  /// Warm system DNS before HTTPS — retries help on cold-start Android / Seeker.
  static Future<void> preflightHost(String host) async {
    if (host.isEmpty || InternetAddress.tryParse(host) != null) return;
    await resolveHost(host);
  }

  /// System DNS with backoff, then the user-selected DNS-over-HTTPS provider.
  static Future<List<InternetAddress>> resolveHost(String host) async {
    Object? lastError;
    for (var attempt = 0; attempt < _lookupRetries; attempt++) {
      try {
        final result = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 6));
        if (result.isNotEmpty) return result;
      } catch (e) {
        lastError = e;
        if (attempt < _lookupRetries - 1) {
          await Future<void>.delayed(_lookupRetryDelay * (attempt + 1));
        }
      }
    }

    final resolver = await _selectedResolver();
    if (resolver == null) {
      throw lastError ??
          const SocketException('System DNS failed and DoH is disabled');
    }

    try {
      final viaDoh = await _resolveViaDoh(host, resolver);
      debugPrint('[Gateway] DNS fallback (DoH) resolved $host → ${viaDoh.first.address}');
      return viaDoh;
    } catch (e) {
      throw lastError ?? e;
    }
  }

  static Future<String?> _selectedResolver() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('settings.dns_resolver');
      if (value == null || value.isEmpty || value == 'system') return null;
      return value;
    } catch (e) {
      debugPrint('[Gateway] could not read DNS resolver setting: $e');
      return null;
    }
  }

  static Future<List<InternetAddress>> _resolveViaDoh(String host, String resolver) async {
    final dnsServer = _createDnsServer(resolver);
    final records = await DNSClient.query(
      domain: host,
      dnsRecordType: DNSRecordTypes.findByName('A'),
      dnsServer: dnsServer,
      timeout: 8000,
    );
    final ipv4 = records
        .whereType<AResponseRecord>()
        .map((r) => r.ip)
        .where((a) => a.type == InternetAddressType.IPv4)
        .toList();
    if (ipv4.isEmpty) throw SocketException('DoH returned no IPv4 for $host');
    return ipv4;
  }

  static DNSServer _createDnsServer(String resolver) {
    return switch (resolver) {
      'cloudflare' => DNSServer(
        host: 'cloudflare-dns.com',
        port: _defaultDohPort,
        protocol: DNSProtocol.doh,
        path: _defaultDohPath,
      ),
      'quad9' => DNSServer(
        host: 'dns.quad9.net',
        port: _defaultDohPort,
        protocol: DNSProtocol.doh,
        path: _defaultDohPath,
      ),
      'adguard' => DNSServer(
        host: 'dns.adguard-dns.com',
        port: _defaultDohPort,
        protocol: DNSProtocol.doh,
        path: _defaultDohPath,
      ),
      _ => _parseCustomDnsServer(resolver),
    };
  }

  static DNSServer _parseCustomDnsServer(String url) {
    final uri = Uri.tryParse(url) ?? Uri.parse('https://dns.google$_defaultDohPath');
    return DNSServer(
      host: uri.host,
      port: uri.hasPort ? uri.port : _defaultDohPort,
      protocol: DNSProtocol.doh,
      path: uri.path.isEmpty ? _defaultDohPath : uri.path,
    );
  }

  static bool isTransientNetworkError(Object error) {
    if (error is! SocketException) return error is TimeoutException;
    final m = error.message.toLowerCase();
    return m.contains('failed host lookup') ||
        m.contains('no address associated') ||
        m.contains('network is unreachable') ||
        m.contains('connection timed out') ||
        m.contains('connection reset');
  }

  static void applyHeaders(
    HttpClientRequest req, {
    String? bearerToken,
    bool jsonBody = false,
  }) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    req.headers.set('X-Erebrus-Client', gatewayClientHeader());
    if (bearerToken != null && bearerToken.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearerToken');
    }
    if (jsonBody) {
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    }
  }

  static String errorMessage(int status, String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final msg = j['error'] ?? j['message'] ?? j['detail'];
        if (msg != null) return msg.toString();
      }
    } catch (_) {}
    return switch (status) {
      404 => 'Gateway registry not found (404)',
      401 => 'Gateway authentication failed (401)',
      403 => 'Gateway access denied (403)',
      _ => 'Gateway error ($status)',
    };
  }

  /// Stable machine-readable code from the gateway error envelope, when one
  /// was supplied. HTTP status remains authoritative for session handling.
  static String? errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['code']?.toString().trim();
        if (code != null && code.isNotEmpty) return code;
      }
    } catch (_) {}
    return null;
  }

  /// Optional `details` object from the gateway error envelope (e.g. the
  /// device `limit` / `used` counts on VPN_DEVICE_LIMIT).
  static Map<String, dynamic>? errorDetails(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['details'] is Map) {
        return Map<String, dynamic>.from(decoded['details'] as Map);
      }
    } catch (_) {}
    return null;
  }

  static Uri normalizeBase(String url) {
    final trimmed = url.trim();
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.parse(withScheme);
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty || path == '/') {
      return uri.replace(path: '', query: null, fragment: null);
    }
    return uri.replace(path: path, query: null, fragment: null);
  }

  static Uri apiUri(
    Uri base, {
    required String path,
    Map<String, String>? query,
  }) {
    final segment = path.startsWith('/') ? path : '/$path';
    final root = base.path.isEmpty || base.path == '/' ? '' : base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$root$segment', queryParameters: query);
  }
}
