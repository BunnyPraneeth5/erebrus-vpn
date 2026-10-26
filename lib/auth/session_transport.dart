import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../vpn/gateway_http.dart';
import 'session_exception.dart';

/// Whether the transport knows that no request bytes could have been sent.
/// Unknown failures stay uncertain; callers must never infer safety from text.
class SessionTransportException extends AuthException {
  SessionTransportException(super.message, {required this.mayHaveCommitted});
  final bool mayHaveCommitted;
}

class SessionResponse {
  const SessionResponse(this.status, this.body, {this.retryAt});
  final int status;
  final String body;
  final DateTime? retryAt;
  bool get ok => status >= 200 && status < 300;
  String? get code => GatewayHttp.errorCode(body);
  AuthException get error => AuthException(
    GatewayHttp.errorMessage(status, body),
    statusCode: status,
    code: code,
    retryAt: retryAt,
  );
  Map<String, dynamic> get json {
    if (body.isEmpty) return {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // FormatException.toString includes source text, potentially credentials.
    }
    throw AuthException('Gateway returned an invalid JSON response.');
  }
}

typedef SessionSender =
    Future<SessionResponse> Function(
      String method,
      Uri uri, {
      String? bearerToken,
      String? body,
      Map<String, String>? headers,
    });

/// Exactly one attempt. In particular, a rotation must never be retried by a
/// generic network interceptor after a timeout or lost response.
Future<SessionResponse> sendSessionRequest(
  String method,
  Uri uri, {
  String? bearerToken,
  String? body,
  Map<String, String>? headers,
}) async {
  final client = GatewayHttp.createClient();
  const timeout = Duration(seconds: 20);
  var submitted = false;
  try {
    await GatewayHttp.preflightHost(uri.host);
    final request = await client.openUrl(method, uri).timeout(timeout);
    GatewayHttp.applyHeaders(
      request,
      bearerToken: bearerToken,
      jsonBody: body != null,
    );
    headers?.forEach((key, value) => request.headers.set(key, value));
    if (body != null) {
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      submitted = true;
      request.add(bytes);
    }
    submitted = true;
    final response = await request.close().timeout(timeout);
    final text = await utf8.decodeStream(response).timeout(timeout);
    final retry = response.headers.value(HttpHeaders.retryAfterHeader);
    DateTime? retryAt;
    if (retry != null) {
      final seconds = int.tryParse(retry);
      if (seconds != null) {
        retryAt = DateTime.now().toUtc().add(Duration(seconds: seconds));
      } else {
        try {
          retryAt = HttpDate.parse(retry);
        } catch (_) {}
      }
    }
    return SessionResponse(response.statusCode, text, retryAt: retryAt);
  } on TimeoutException {
    throw SessionTransportException(
      'Gateway request timed out. Check your connection.',
      mayHaveCommitted: submitted,
    );
  } on IOException {
    throw SessionTransportException(
      'Cannot reach the gateway. Check your connection.',
      mayHaveCommitted: submitted,
    );
  } finally {
    client.close(force: true);
  }
}
