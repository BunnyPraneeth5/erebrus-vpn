import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ui';

import '../vpn/gateway_config.dart';
import '../vpn/gateway_http.dart';
import 'auth_session.dart';
import 'auth_session_store.dart';
import 'session_exception.dart';
import 'session_transport.dart';

/// The registered owner is the only isolate allowed to read/rotate credentials.
/// All gateway clients (including background Flutter isolates) use this broker.
/// The name is local to this app's engine, never an Erebrus-wide credential pool.
class AuthRepository {
  AuthRepository({
    AuthSessionStore? store,
    String? gatewayUrl,
    SessionSender? sender,
    DateTime Function()? clock,
    String? brokerName,
  }) : _store =
           store ??
           AuthSessionStore(
             namespace: GatewayHttp.normalizeBase(
               gatewayUrl ?? resolveGatewayUrl(),
             ).toString(),
           ),
       _base = GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl()),
       _send = sender ?? sendSessionRequest,
       _now = clock ?? DateTime.now,
       _brokerName =
           brokerName ??
           'com.erebrus.vpn.auth.${GatewayHttp.normalizeBase(gatewayUrl ?? resolveGatewayUrl())}';

  final AuthSessionStore _store;
  final Uri _base;
  final SessionSender _send;
  final DateTime Function() _now;
  final String _brokerName;
  ReceivePort? _owner;
  Future<void> _queue = Future.value();
  final Map<String, List<SendPort>> _tokenWaiters = {};
  StoredAuthSession? _current;
  StoredAuthSession? _uncommittedReplacement;
  bool _loaded = false;
  int _generation = 0;
  void Function(StoredAuthSession?)? onChanged;

  Future<dynamic> _call(
    String command, [
    Map<String, dynamic> args = const {},
  ]) async {
    var port = IsolateNameServer.lookupPortByName(_brokerName);
    if (port == null) {
      if (RootIsolateToken.instance == null) {
        throw AuthException(
          'Initialize the session owner on the main isolate first.',
          code: 'SESSION_OWNER_UNAVAILABLE',
        );
      }
      final owner = ReceivePort();
      if (IsolateNameServer.registerPortWithName(owner.sendPort, _brokerName)) {
        _owner = owner;
        owner.listen(_receive);
        port = owner.sendPort;
      } else {
        owner.close();
        port = IsolateNameServer.lookupPortByName(_brokerName);
      }
    }
    if (port == null) throw AuthException('Session coordinator unavailable.');
    final reply = ReceivePort();
    try {
      port.send([command, args, reply.sendPort]);
      final result = await reply.first as Map;
      if (result['error'] == true) {
        throw AuthException(
          result['message'] as String,
          statusCode: result['status'] as int?,
          code: result['code'] as String?,
          retryAt: DateTime.tryParse('${result['retryAt']}'),
        );
      }
      return result['value'];
    } finally {
      reply.close();
    }
  }

  void _receive(dynamic message) {
    final command = message[0] as String;
    final args = Map<String, dynamic>.from(message[1] as Map);
    final reply = message[2] as SendPort;
    // Invalidate pending protected requests immediately, even while rotation is
    // on the wire. The queued logout still revokes the replacement credential.
    if (command == 'logout' || command == 'install') {
      if (command == 'install' && args['generation'] != _generation) {
        reply.send({
          'error': true,
          'message': 'Account changed during sign-in.',
          'code': 'SESSION_CHANGED',
        });
        return;
      }
      args['operationGeneration'] = ++_generation;
      if (command == 'logout') onChanged?.call(null);
    }
    final requestedGeneration = _generation;
    // Fan out one result (including failures) to every concurrent waiter. A
    // definite pre-send network failure must not start N refresh attempts.
    final tokenKey = command == 'token'
        ? '$requestedGeneration:${args['generation']}:${args['rejected']}'
        : null;
    if (tokenKey != null) {
      final waiting = _tokenWaiters[tokenKey];
      if (waiting != null) {
        waiting.add(reply);
        return;
      }
      _tokenWaiters[tokenKey] = [reply];
    }
    void complete(Map<String, dynamic> result) {
      final waiting = tokenKey == null
          ? [reply]
          : _tokenWaiters.remove(tokenKey)!;
      for (final recipient in waiting) {
        recipient.send(result);
      }
    }

    _queue = _queue.then((_) async {
      try {
        final value = await _execute(command, args, requestedGeneration);
        complete({'value': value});
      } on AuthException catch (e) {
        complete({
          'error': true,
          'message': e.message,
          'status': e.statusCode,
          'code': e.code,
          'retryAt': e.retryAt?.toIso8601String(),
        });
      } catch (_) {
        // Platform/storage errors can contain sensitive values. Never forward
        // their text into UI error messages or logs.
        complete({
          'error': true,
          'message': 'Secure session operation failed.',
          'code': 'SESSION_STORAGE_ERROR',
        });
      }
    });
  }

  Future<void> _load() async {
    if (_loaded) return;
    _current = await _store.read();
    _loaded = true;
  }

  Future<dynamic> _execute(
    String command,
    Map<String, dynamic> args,
    int requestedGeneration,
  ) async {
    await _load();
    switch (command) {
      case 'generation':
        _checkGeneration(requestedGeneration);
        return _generation;
      case 'snapshot':
        return _current?.toJson();
      case 'terminate':
        _checkGeneration(args['generation'] as int);
        await _store.clear();
        _current = null;
        if (_generation == args['generation']) {
          ++_generation;
          onChanged?.call(null);
        }
        return null;
      case 'check':
        _checkGeneration(args['generation'] as int);
        return null;
      case 'install':
        final generation = args['operationGeneration'] as int;
        _checkGeneration(generation);
        final session = StoredAuthSession.fromJson(
          Map<String, dynamic>.from(args['session'] as Map),
        );
        if (session.token.isEmpty ||
            (session.credentials.isRefreshable &&
                !session.credentials.isComplete)) {
          throw AuthException(
            'The gateway returned incomplete session credentials.',
          );
        }
        final previous = _uncommittedReplacement ?? _current;
        var revocationConfirmed = true;
        if (previous != null &&
            previous.credentials.refreshToken !=
                session.credentials.refreshToken) {
          revocationConfirmed = await _revoke(
            previous,
          ); // Serializes with rotation.
        }
        _checkGeneration(generation);
        await _store.write(session);
        _current = session;
        _uncommittedReplacement = null;
        if (_generation == generation) onChanged?.call(session);
        _checkGeneration(generation);
        return revocationConfirmed;
      case 'logout':
        final previous = _uncommittedReplacement ?? _current;
        final confirmed = previous == null || await _revoke(previous);
        await _store.clear();
        _current = null;
        _uncommittedReplacement = null;
        onChanged?.call(null);
        return confirmed;
      case 'token':
        _checkGeneration(requestedGeneration);
        if (args['generation'] != null) {
          _checkGeneration(args['generation'] as int);
        }
        final rejected = args['rejected'] as String?;
        if (_current == null) {
          throw AuthException('Sign in first.', code: 'LOGIN_REQUIRED');
        }
        final credentials = _current!.credentials;
        final force = rejected != null && rejected == credentials.token;
        if (!credentials.isRefreshable ||
            force ||
            credentials.expiresAt == null ||
            !credentials.expiresAt!.isAfter(
              _now().add(const Duration(seconds: 60)),
            )) {
          await _renew();
        }
        _checkGeneration(requestedGeneration);
        return {'token': _current!.token, 'generation': _generation};
      default:
        throw StateError('Unknown session command');
    }
  }

  void _checkGeneration(int expected) {
    if (_generation != expected) {
      throw AuthException(
        'Account changed during request.',
        code: 'SESSION_CHANGED',
      );
    }
  }

  Future<bool> _revoke(StoredAuthSession session) async {
    if (!session.credentials.isRefreshable) return false;
    try {
      final response = await _send(
        'POST',
        GatewayHttp.apiUri(_base, path: '/api/v2/auth/logout'),
        body: jsonEncode({'refresh_token': session.credentials.refreshToken}),
      );
      return response.status == 204 ||
          response.code == 'SESSION_REVOKED' ||
          response.code == 'REFRESH_TOKEN_REUSED';
    } catch (_) {
      return false;
    }
  }

  Future<void> _renew() async {
    final generation = _generation;
    final stored = _current!;
    final credentials = stored.credentials;
    if (stored.loginRequired || stored.renewalUncertain) {
      throw AuthException(
        stored.renewalUncertain
            ? 'Session renewal could not be confirmed. Sign in once to continue safely.'
            : 'Please sign in once to renew this login.',
        code: 'LOGIN_REQUIRED',
      );
    }
    final retryAt = stored.retryAt;
    if (retryAt != null && retryAt.isAfter(_now())) {
      throw AuthException(
        'Please wait before retrying session renewal.',
        statusCode: 429,
        retryAt: retryAt,
      );
    }
    final legacy = !credentials.isRefreshable;
    // Commit a write-ahead marker before sending a single-use credential. A
    // killed process, lost response, or failed replacement write cannot replay it.
    final pending = stored.withStatus(uncertain: true);
    await _store.write(pending);
    _current = pending;
    late final SessionResponse response;
    try {
      response = await _send(
        'POST',
        GatewayHttp.apiUri(
          _base,
          path: legacy ? '/api/v2/auth/session' : '/api/v2/auth/refresh',
        ),
        bearerToken: legacy ? credentials.token : null,
        body: legacy
            ? '{}'
            : jsonEncode({'refresh_token': credentials.refreshToken}),
      );
    } on SessionTransportException catch (e) {
      if (!e.mayHaveCommitted) {
        // DNS/connect failure before submission: a later foreground request is
        // safe to try again. Never automatically retry within this operation.
        await _store.write(stored);
        _current = stored;
      }
      rethrow;
    }
    if (!response.ok) {
      final rawError = response.error;
      var message = rawError.message.replaceAll(
        credentials.token,
        '[redacted]',
      );
      if (credentials.isRefreshable) {
        message = message.replaceAll(credentials.refreshToken!, '[redacted]');
      }
      final error = AuthException(
        message,
        statusCode: rawError.statusCode,
        code: rawError.code,
        retryAt: rawError.retryAt,
      );
      if (error.isSessionExpired) {
        await _store.clear();
        _current = null;
        if (_generation == generation) {
          ++_generation;
          onChanged?.call(null);
        }
      } else if (response.status < 500) {
        // A definite rejection did not consume the credential. 5xx is uncertain.
        final next = stored.withStatus(
          loginRequired:
              legacy &&
              (response.status == 401 ||
                  response.code == 'SESSION_ALREADY_REFRESHABLE'),
          retryAt:
              response.retryAt ??
              (response.status == 429
                  ? _now().add(const Duration(seconds: 60))
                  : null),
        );
        await _store.write(next);
        _current = next;
      }
      throw error;
    }
    final replacement = AuthSession.fromJson(
      response.json,
      now: _now(),
      walletAddress: stored.walletAddress,
    );
    if (!replacement.isComplete ||
        (!legacy &&
            (replacement.refreshToken == credentials.refreshToken ||
                replacement.sessionId != credentials.sessionId ||
                replacement.userId != credentials.userId))) {
      throw AuthException(
        'Gateway returned an incomplete replacement session. Sign in again.',
        code: 'LOGIN_REQUIRED',
      );
    }
    final next = stored.withCredentials(replacement);
    _uncommittedReplacement = next;
    await _store.write(
      next,
    ); // Must finish before any waiting request proceeds.
    _current = next;
    _uncommittedReplacement = null;
    if (_generation == generation) onChanged?.call(next);
  }

  Future<int> generation() async => await _call('generation') as int;
  Future<StoredAuthSession?> restore() async {
    final value = await _call('snapshot');
    return value == null
        ? null
        : StoredAuthSession.fromJson(Map<String, dynamic>.from(value as Map));
  }

  Future<void> ensureFresh() async {
    await _call('token');
  }

  Future<bool> install(
    StoredAuthSession session, {
    required int generation,
  }) async {
    return await _call('install', {
          'session': session.toJson(),
          'generation': generation,
        })
        as bool;
  }

  Future<bool> logout() async => await _call('logout') as bool;

  Future<SessionResponse> request(
    String method,
    Uri uri, {
    String? body,
    Map<String, String>? headers,
  }) async {
    if (uri.origin != _base.origin ||
        !uri.path.startsWith('${_base.path}/api/v2/')) {
      throw AuthException('Refusing to send a session to another gateway.');
    }
    if (const [
      '/auth/refresh',
      '/auth/logout',
      '/auth/session',
    ].any(uri.path.endsWith)) {
      throw AuthException(
        'Session endpoints must use the session coordinator.',
      );
    }
    final ticket = Map<String, dynamic>.from(await _call('token') as Map);
    final generation = ticket['generation'] as int;
    var token = ticket['token'] as String;
    var response = await _send(
      method,
      uri,
      bearerToken: token,
      body: body,
      headers: headers,
    );
    await _call('check', {'generation': generation});
    if (response.status == 401 && response.code == 'ACCESS_TOKEN_EXPIRED') {
      final renewed = Map<String, dynamic>.from(
        await _call('token', {'rejected': token, 'generation': generation})
            as Map,
      );
      token = renewed['token'] as String;
      response = await _send(
        method,
        uri,
        bearerToken: token,
        body: body,
        headers: headers,
      );
      await _call('check', {'generation': generation});
    }
    // Only credential/session revocation codes may clear auth. Business 401s
    // remain ordinary errors, including an expiry on the single allowed retry.
    if (response.error.isSessionExpired) {
      await _call('terminate', {'generation': generation});
    }
    return response;
  }

  /// Only used by tests/engine shutdown, never dispose the app's live owner.
  void dispose() {
    if (_owner != null) {
      IsolateNameServer.removePortNameMapping(_brokerName);
      _owner!.close();
      _owner = null;
    }
  }
}
