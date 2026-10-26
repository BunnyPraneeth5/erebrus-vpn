import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:erebrus_vpn/auth/auth_repository.dart';
import 'package:erebrus_vpn/auth/auth_session_store.dart';
import 'package:erebrus_vpn/auth/gateway_auth_client.dart';
import 'package:erebrus_vpn/auth/entitlement_state.dart';
import 'package:erebrus_vpn/auth/desktop_web_auth.dart';
import 'package:erebrus_vpn/auth/session_transport.dart';
import 'package:erebrus_vpn/auth/wallet_auth_controller.dart';
import 'package:erebrus_vpn/vpn/gateway_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryStore extends AuthSessionStore {
  StoredAuthSession? value;
  int writes = 0;
  int readFailures = 0;
  bool failReplacement = false;
  Completer<void>? replacementGate;
  @override
  Future<StoredAuthSession?> read() async {
    if (readFailures > 0) {
      readFailures--;
      throw StateError('Keychain temporarily locked');
    }
    return value;
  }

  @override
  Future<void> write(StoredAuthSession session) async {
    if (session.token == 'access-2') {
      await replacementGate?.future;
      if (failReplacement) throw StateError('secure store locked');
    }
    writes++;
    value = StoredAuthSession.fromJson(session.toJson());
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

final start = DateTime.utc(2026, 10, 19);
Map<String, dynamic> payload(int n, {DateTime? at, String user = 'user'}) => {
  'access_token': 'access-$n',
  'token': 'legacy-alias-$n',
  'token_type': 'Bearer',
  'expires_at': (at ?? start.add(const Duration(hours: 24))).toIso8601String(),
  'expires_in': 86400,
  'refresh_token': 'refresh-$n',
  'refresh_expires_at': start.add(const Duration(days: 30)).toIso8601String(),
  'refresh_expires_in': 2592000,
  'session_id': 'session-$user',
  'user_id': user,
  'role': 'user',
};
StoredAuthSession stored(int n, {DateTime? at, String user = 'user'}) =>
    StoredAuthSession(
      credentials: AuthSession.fromJson(payload(n, at: at, user: user)),
      authMethod: 'email',
    );
SessionResponse jsonResponse(Map<String, dynamic> value) =>
    SessionResponse(200, jsonEncode(value));
SessionResponse error(int status, String code, {DateTime? retryAt}) =>
    SessionResponse(
      status,
      jsonEncode({'code': code, 'error': code}),
      retryAt: retryAt,
    );
final protectedUri = Uri.parse('https://gateway.test/api/v2/account/profile');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var sequence = 0;
  late MemoryStore store;
  late DateTime now;
  late String name;
  late AuthRepository repo;
  late List<String> sent;
  late SessionSender sender;

  AuthRepository create() => AuthRepository(
    store: store,
    clock: () => now,
    brokerName: name,
    gatewayUrl: 'https://gateway.test',
    sender: (method, uri, {bearerToken, body, headers}) => sender(
      method,
      uri,
      bearerToken: bearerToken,
      body: body,
      headers: headers,
    ),
  );

  setUp(() {
    store = MemoryStore();
    now = start;
    name = 'auth-test-${sequence++}';
    sent = [];
    sender = (method, uri, {bearerToken, body, headers}) async {
      sent.add(uri.path);
      if (uri.path.endsWith('/refresh') || uri.path.endsWith('/session')) {
        return jsonResponse(payload(2, at: now.add(const Duration(hours: 24))));
      }
      if (uri.path.endsWith('/logout')) return const SessionResponse(204, '');
      return jsonResponse({'user_id': 'user'});
    };
    repo = create();
  });
  tearDown(() => repo.dispose());

  test(
    'resume retries startup storage failures without deleting credentials',
    () async {
      store.value = stored(1);
      store.readFailures = 1;
      final auth = WalletAuthController(
        repository: repo,
        authClient: GatewayAuthClient(gatewayUrl: 'https://gateway.test'),
      );
      await auth.loadPersistedSession();
      expect(auth.isAuthenticated, isFalse);
      expect(store.value, isNotNull);
      await auth.restoreOnResume();
      expect(auth.isAuthenticated, isTrue);
      expect(auth.bearerToken, 'access-1');
    },
  );

  test('rotation cannot change the session identity', () async {
    store.value = stored(1, at: start);
    sender = (method, uri, {bearerToken, body, headers}) async =>
        jsonResponse(payload(2, user: 'wrong-account'));
    await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
    expect(store.value!.userId, 'user');
    expect(store.value!.renewalUncertain, isTrue);
  });

  test('cancelled desktop callbacks cannot install a session', () async {
    final auth = WalletAuthController(
      repository: repo,
      authClient: GatewayAuthClient(gatewayUrl: 'https://gateway.test'),
    );
    DesktopWebAuth.buildLoginUrl();
    final state = DesktopWebAuth.pendingState!;
    await auth.handleWebAuthCallback(
      'erebrusvpn://auth?token=old&user_id=old&wallet=old&state=$state',
    );
    expect(await repo.restore(), isNull);
    expect(auth.isAuthenticated, isFalse);
    expect(sent, isEmpty);
    DesktopWebAuth.clearPendingState();
  });

  test(
    'late email login response after logout cannot restore the old account',
    () async {
      store.value = stored(1);
      final started = Completer<void>();
      final release = Completer<SessionResponse>();
      final auth = WalletAuthController(
        repository: repo,
        authClient: GatewayAuthClient(
          gatewayUrl: 'https://gateway.test',
          sender: (method, uri, {bearerToken, body, headers}) async {
            started.complete();
            return release.future;
          },
        ),
      );
      await auth.loadPersistedSession();
      final login = auth.verifyEmailLoginCode(
        email: 'email@example.test',
        code: '123456',
      );
      await started.future;
      await auth.signOut();
      release.complete(jsonResponse(payload(3)));
      await login;
      expect(auth.isAuthenticated, isFalse);
      expect(await repo.restore(), isNull);
      expect(store.value, isNull);
    },
  );

  test(
    'malformed login response cannot expose credentials in parser errors',
    () {
      final response = SessionResponse(
        200,
        '{"refresh_token":"private-secret"',
      );
      expect(
        () => response.json,
        throwsA(
          isA<AuthException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('private-secret')),
          ),
        ),
      );
    },
  );

  test('renewal error text redacts known credentials', () async {
    store.value = stored(1, at: start);
    sender = (method, uri, {bearerToken, body, headers}) async =>
        const SessionResponse(
          400,
          '{"error":"reject refresh-1 and access-1","code":"BUSINESS_ERROR"}',
        );
    await expectLater(
      repo.ensureFresh(),
      throwsA(
        isA<AuthException>().having(
          (e) => e.message,
          'message',
          allOf(isNot(contains('refresh-1')), isNot(contains('access-1'))),
        ),
      ),
    );
  });

  test('opaque token aliases and response expiry metadata are retained', () {
    final model = AuthSession.fromJson(payload(1));
    expect(model.token, 'access-1');
    expect(model.expiresAt, start.add(const Duration(hours: 24)));
    expect(model.refreshExpiresIn, 2592000);
    final relative = AuthSession.fromJson({
      'token': 'v4.local.not-a-jwt',
      'expires_in': 7,
      'refresh_expires_in': 15,
    }, now: start);
    expect(relative.expiresAt, start.add(const Duration(seconds: 7)));
    expect(relative.refreshExpiresAt, start.add(const Duration(seconds: 15)));
  });

  test(
    'restart after more than 24 hours rotates and restores the replacement',
    () async {
      store.value = stored(1);
      now = start.add(const Duration(hours: 25));
      await repo.restore();
      await repo.ensureFresh();
      expect(store.value!.token, 'access-2');
      expect(store.value!.credentials.refreshToken, 'refresh-2');
      repo.dispose();
      repo = create();
      await repo.ensureFresh();
      expect(sent.where((p) => p.endsWith('/refresh')), hasLength(1));
    },
  );

  test('60 second boundary refreshes; fresh requests do not rotate', () async {
    store.value = stored(1);
    now = start
        .add(const Duration(hours: 24))
        .subtract(const Duration(seconds: 61));
    await repo.ensureFresh();
    expect(sent, isEmpty);
    now = now.add(const Duration(seconds: 1));
    await repo.ensureFresh();
    expect(sent, ['/api/v2/auth/refresh']);
  });

  test(
    'concurrent clients release only after the rotated session is persisted',
    () async {
      store.value = stored(1, at: start);
      store.replacementGate = Completer<void>();
      final reached = Completer<void>();
      sender = (method, uri, {bearerToken, body, headers}) async {
        sent.add(uri.path);
        if (uri.path.endsWith('/refresh')) {
          expect(bearerToken, isNull);
          expect(jsonDecode(body!), {'refresh_token': 'refresh-1'});
          reached.complete();
          return jsonResponse(payload(2));
        }
        expect(store.value!.token, 'access-2');
        expect(bearerToken, 'access-2');
        return jsonResponse({'user_id': 'user'});
      };
      final requests = List.generate(
        12,
        (_) => repo.request('GET', protectedUri),
      );
      await reached.future;
      await Future<void>.delayed(Duration.zero);
      expect(sent, ['/api/v2/auth/refresh']);
      store.replacementGate!.complete();
      await Future.wait(requests);
      expect(sent.where((p) => p.endsWith('/refresh')), hasLength(1));
    },
  );

  test(
    'ACCESS_TOKEN_EXPIRED retries once with identical body and idempotency key',
    () async {
      store.value = stored(1);
      final requests = <String?>[];
      final tokens = <String?>[];
      sender = (method, uri, {bearerToken, body, headers}) async {
        if (uri.path.endsWith('/refresh')) return jsonResponse(payload(2));
        requests.add(body);
        tokens.add(bearerToken);
        expect(headers, {'Idempotency-Key': 'purchase-123'});
        return error(401, 'ACCESS_TOKEN_EXPIRED');
      };
      final response = await repo.request(
        'POST',
        protectedUri,
        body: '{"checkout":"unchanged"}',
        headers: {'Idempotency-Key': 'purchase-123'},
      );
      expect(response.status, 401);
      expect(requests, [
        '{"checkout":"unchanged"}',
        '{"checkout":"unchanged"}',
      ]);
      expect(tokens, ['access-1', 'access-2']);
      expect(store.value, isNotNull);
    },
  );

  test('late 401 reuses another request’s replacement', () async {
    store.value = stored(1);
    final lateResponse = Completer<SessionResponse>();
    final firstStarted = Completer<void>();
    var protected = 0;
    sender = (method, uri, {bearerToken, body, headers}) async {
      sent.add(uri.path);
      if (uri.path.endsWith('/refresh')) return jsonResponse(payload(2));
      if (bearerToken == 'access-1') {
        if (protected++ == 0) {
          firstStarted.complete();
          return lateResponse.future;
        }
        return error(401, 'ACCESS_TOKEN_EXPIRED');
      }
      return jsonResponse({'ok': true});
    };
    final first = repo.request('GET', protectedUri);
    await firstStarted.future;
    await repo.request('GET', protectedUri);
    lateResponse.complete(error(401, 'ACCESS_TOKEN_EXPIRED'));
    await first;
    expect(sent.where((p) => p.endsWith('/refresh')), hasLength(1));
  });

  for (final code in [
    'REFRESH_TOKEN_INVALID',
    'REFRESH_TOKEN_REUSED',
    'SESSION_REVOKED',
  ]) {
    test('$code terminates the session', () async {
      store.value = stored(1, at: start);
      sender = (method, uri, {bearerToken, body, headers}) async =>
          error(401, code);
      await expectLater(
        repo.ensureFresh(),
        throwsA(isA<AuthException>().having((e) => e.code, 'code', code)),
      );
      expect(await repo.restore(), isNull);
      expect(store.value, isNull);
    });
  }

  test('protected business errors including 401/403 preserve login', () async {
    store.value = stored(1);
    for (final status in [400, 401, 403, 429, 500, 503]) {
      sender = (method, uri, {bearerToken, body, headers}) async =>
          error(status, 'BUSINESS_ERROR');
      final response = await repo.request('GET', protectedUri);
      expect(response.status, status);
      expect((await repo.restore())!.token, 'access-1');
    }
  });

  test('429 honors a persistent Retry-After without dropping auth', () async {
    store.value = stored(1, at: start);
    var attempts = 0;
    sender = (method, uri, {bearerToken, body, headers}) async {
      if (attempts++ == 0) {
        return error(
          429,
          'RATE_LIMITED',
          retryAt: start.add(const Duration(minutes: 3)),
        );
      }
      return jsonResponse(payload(2));
    };
    await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
    repo.dispose();
    repo = create();
    await expectLater(
      repo.ensureFresh(),
      throwsA(
        isA<AuthException>().having(
          (e) => e.retryAt,
          'retryAt',
          start.add(const Duration(minutes: 3)),
        ),
      ),
    );
    expect(attempts, 1);
    expect(store.value, isNotNull);
    now = start.add(const Duration(minutes: 3));
    await repo.ensureFresh();
    expect(attempts, 2);
  });

  for (final failure in [
    'offline',
    'timeout',
    '500',
    '503',
    'invalid response',
  ]) {
    test(
      '$failure during rotation never replays the credential, even after restart',
      () async {
        store.value = stored(1, at: start);
        var attempts = 0;
        sender = (method, uri, {bearerToken, body, headers}) async {
          attempts++;
          if (failure == 'offline') throw AuthException('offline');
          if (failure == 'timeout') throw TimeoutException('uncertain');
          if (failure == 'invalid response') {
            return const SessionResponse(200, '{}');
          }
          return error(int.parse(failure), 'UNAVAILABLE');
        };
        await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
        repo.dispose();
        repo = create();
        await expectLater(
          repo.ensureFresh(),
          throwsA(
            isA<AuthException>().having(
              (e) => e.code,
              'code',
              'LOGIN_REQUIRED',
            ),
          ),
        );
        expect(attempts, 1);
        expect(store.value!.userId, 'user');
        expect(store.value!.renewalUncertain, isTrue);
      },
    );
  }

  test(
    'concurrent waiters share a definite network failure without retrying',
    () async {
      store.value = stored(1, at: start);
      final reached = Completer<void>();
      final release = Completer<void>();
      var attempts = 0;
      sender = (method, uri, {bearerToken, body, headers}) async {
        attempts++;
        reached.complete();
        await release.future;
        throw SessionTransportException(
          'offline before send',
          mayHaveCommitted: false,
        );
      };
      final results = List.generate(
        10,
        (_) => expectLater(
          repo.ensureFresh(),
          throwsA(
            isA<AuthException>().having(
              (e) => e.message,
              'message',
              'offline before send',
            ),
          ),
        ),
      );
      await reached.future;
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await Future.wait(results);
      expect(attempts, 1);
    },
  );

  test(
    'definite offline failure before submission allows later recovery',
    () async {
      store.value = stored(1, at: start);
      var attempts = 0;
      sender = (method, uri, {bearerToken, body, headers}) async {
        if (attempts++ == 0) {
          throw SessionTransportException(
            'offline before send',
            mayHaveCommitted: false,
          );
        }
        return jsonResponse(payload(2));
      };
      await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
      expect(store.value!.renewalUncertain, isFalse);
      await repo.ensureFresh();
      expect(store.value!.token, 'access-2');
    },
  );

  test(
    'session endpoints and foreign origins cannot enter protected interception',
    () async {
      store.value = stored(1);
      for (final uri in [
        Uri.parse('https://another-app.test/api/v2/account/profile'),
        Uri.parse('https://gateway.test/api/v2/auth/refresh'),
        Uri.parse('https://gateway.test/api/v2/auth/logout'),
      ]) {
        await expectLater(
          repo.request('POST', uri),
          throwsA(isA<AuthException>()),
        );
      }
      expect(sent, isEmpty);
    },
  );

  test(
    'controller retains entitlements and profile on offline and business errors',
    () async {
      store.value = stored(1);
      final auth = WalletAuthController(
        repository: repo,
        authClient: GatewayAuthClient(gatewayUrl: 'https://gateway.test'),
      );
      await auth.loadPersistedSession();
      // Drain the startup summary loads before changing the fake response.
      await repo.restore();
      auth.entitlement.value = const EntitlementState(
        entitled: true,
        status: 'active',
      );
      auth.profileName.value = 'Keep me';
      sender = (method, uri, {bearerToken, body, headers}) async =>
          throw AuthException('offline');
      await auth.refreshEntitlement();
      await auth.refreshProfile();
      expect(auth.isAuthenticated, isTrue);
      expect(auth.entitlement.value.entitled, isTrue);
      expect(auth.profileName.value, 'Keep me');
      sender = (method, uri, {bearerToken, body, headers}) async =>
          error(401, 'BUSINESS_ERROR');
      await auth.refreshEntitlement();
      expect(auth.entitlement.value.entitled, isTrue);
    },
  );

  test(
    'failed secure replacement write does not release requests or replay',
    () async {
      store.value = stored(1, at: start);
      store.failReplacement = true;
      await expectLater(
        repo.request('GET', protectedUri),
        throwsA(isA<AuthException>()),
      );
      await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
      expect(sent, ['/api/v2/auth/refresh']);
      expect(store.value!.renewalUncertain, isTrue);
    },
  );

  test('valid legacy bearer is upgraded once and persisted', () async {
    store.value = const StoredAuthSession(
      credentials: AuthSession(
        token: 'legacy',
        userId: 'user',
        role: 'user',
        walletAddress: 'wallet',
      ),
      authMethod: 'reown',
    );
    sender = (method, uri, {bearerToken, body, headers}) async {
      sent.add(uri.path);
      expect(uri.path, '/api/v2/auth/session');
      expect(bearerToken, 'legacy');
      return jsonResponse(payload(2));
    };
    await Future.wait(List.generate(5, (_) => repo.ensureFresh()));
    expect(sent, ['/api/v2/auth/session']);
    expect(store.value!.walletAddress, 'wallet');
    expect(store.value!.credentials.isComplete, isTrue);
  });

  for (final code in ['ACCESS_TOKEN_EXPIRED', 'SESSION_ALREADY_REFRESHABLE']) {
    test(
      'legacy $code requires one login without clearing user data or looping',
      () async {
        store.value = const StoredAuthSession(
          credentials: AuthSession(
            token: 'legacy',
            userId: 'user',
            role: 'user',
            walletAddress: '',
          ),
          authMethod: 'email',
        );
        sender = (method, uri, {bearerToken, body, headers}) async {
          sent.add(uri.path);
          return error(code == 'ACCESS_TOKEN_EXPIRED' ? 401 : 409, code);
        };
        await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
        await expectLater(repo.ensureFresh(), throwsA(isA<AuthException>()));
        expect(sent, hasLength(1));
        expect(store.value!.loginRequired, isTrue);
      },
    );
  }

  test(
    'logout during rotation revokes replacement and discards late results',
    () async {
      store.value = stored(1, at: start);
      final rotating = Completer<void>();
      final release = Completer<SessionResponse>();
      final published = <String?>[];
      repo.onChanged = (s) => published.add(s?.token);
      sender = (method, uri, {bearerToken, body, headers}) async {
        if (uri.path.endsWith('/refresh')) {
          rotating.complete();
          return release.future;
        }
        expect(uri.path.endsWith('/logout'), isTrue);
        expect(jsonDecode(body!), {'refresh_token': 'refresh-2'});
        return const SessionResponse(204, '');
      };
      final request = repo.request('GET', protectedUri);
      final rejected = expectLater(
        request,
        throwsA(
          isA<AuthException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      await rotating.future;
      final logout = repo.logout();
      await Future<void>.delayed(Duration.zero);
      release.complete(jsonResponse(payload(2)));
      expect(await logout, isTrue);
      await rejected;
      expect(store.value, isNull);
      expect(published, isNot(contains('access-2')));
    },
  );

  test(
    'offline explicit logout clears credentials and reports unconfirmed revocation',
    () async {
      store.value = stored(1);
      sender = (method, uri, {bearerToken, body, headers}) async =>
          throw AuthException('offline');
      expect(await repo.logout(), isFalse);
      expect(store.value, isNull);
      expect(await repo.restore(), isNull);
    },
  );

  test(
    'account switching during renewal rejects old work and revokes the replacement',
    () async {
      store.value = stored(1, at: start);
      final generation = await repo.generation();
      final rotating = Completer<void>();
      final release = Completer<SessionResponse>();
      sender = (method, uri, {bearerToken, body, headers}) async {
        if (uri.path.endsWith('/refresh')) {
          rotating.complete();
          return release.future;
        }
        expect(jsonDecode(body!), {'refresh_token': 'refresh-2'});
        return const SessionResponse(204, '');
      };
      final renewal = expectLater(
        repo.ensureFresh(),
        throwsA(isA<AuthException>()),
      );
      await rotating.future;
      final install = repo.install(
        stored(3, user: 'other'),
        generation: generation,
      );
      await Future<void>.delayed(Duration.zero);
      release.complete(jsonResponse(payload(2)));
      await install;
      await renewal;
      expect((await repo.restore())!.userId, 'other');
      await expectLater(
        repo.install(stored(4), generation: generation),
        throwsA(isA<AuthException>()),
      );
      expect(store.value!.userId, 'other');
    },
  );

  test('API clients share renewal for account and VPN calls', () async {
    store.value = stored(1, at: start);
    final auth = GatewayAuthClient(
      gatewayUrl: 'https://gateway.test',
      sessions: repo,
    );
    final vpn = GatewayClient(baseUrl: 'https://gateway.test', sessions: repo);
    sender = (method, uri, {bearerToken, body, headers}) async {
      sent.add(uri.path);
      if (uri.path.endsWith('/refresh')) return jsonResponse(payload(2));
      if (uri.path.endsWith('/clients')) {
        return const SessionResponse(200, '[]');
      }
      return const SessionResponse(200, '{"entitled":true}');
    };
    await Future.wait([
      auth.fetchSubscription('access-1'),
      vpn.listVpnClients(),
    ]);
    expect(sent.where((p) => p.endsWith('/refresh')), hasLength(1));
  });

  test('all native provider responses keep replacement metadata', () async {
    final auth = GatewayAuthClient(
      sender: (method, uri, {bearerToken, body, headers}) async =>
          jsonResponse(payload(1)),
    );
    final responses = await Future.wait([
      auth.authenticate(
        challengeId: 'flow',
        signature: 'sig',
        publicKey: 'wallet',
      ),
      auth.emailLoginVerify(email: 'a@example.test', code: '123456'),
      auth.googleLogin('id-token'),
      auth.appleLogin(
        idToken: 'id',
        authorizationCode: 'code',
        nonce: 'nonce',
        state: 'state',
      ),
    ]);
    for (final response in responses) {
      expect(response.isComplete, isTrue);
      expect(response.token, 'access-1');
      expect(response.refreshToken, 'refresh-1');
    }
  });

  test(
    'startup and lifecycle resume rotate without a background timer',
    () async {
      store.value = stored(1);
      final auth = WalletAuthController(
        repository: repo,
        authClient: GatewayAuthClient(gatewayUrl: 'https://gateway.test'),
      );
      await auth.loadPersistedSession();
      expect(auth.isAuthenticated, isTrue);
      expect(auth.bearerToken, 'access-1');
      now = start.add(const Duration(hours: 25));
      auth.didChangeAppLifecycleState(AppLifecycleState.resumed);
      // Wait behind the queued resume operation, then its protected data calls.
      await repo.restore();
      expect(store.value!.token, 'access-2');
      expect(auth.bearerToken, 'access-2');
      expect(auth.userId.value, 'user');
    },
  );

  test(
    'separate repository proxies coordinate through the app owner',
    () async {
      store.value = stored(1, at: start);
      final proxy = create();
      await Future.wait([repo.ensureFresh(), proxy.ensureFresh()]);
      expect(sent, ['/api/v2/auth/refresh']);
    },
  );

  test(
    'background isolate uses owner without reading secure storage or rotating twice',
    () async {
      store.value = stored(1, at: start);
      await repo.restore(); // Register the engine's owner before spawning work.
      final receive = ReceivePort();
      final isolate = await Isolate.spawn(_backgroundRenew, [
        name,
        receive.sendPort,
      ]);
      final result = await receive.first;
      receive.close();
      isolate.kill();
      expect(result, 'ok');
      expect(sent, ['/api/v2/auth/refresh']);
      expect(store.value!.token, 'access-2');
    },
  );

  test(
    'native storage commits all credentials in one item and removes old prefs',
    () async {
      SharedPreferences.setMockInitialValues({
        'erebrus_auth_${AuthSessionStore.kToken}': 'old-token',
      });
      FlutterSecureStorage.setMockInitialValues({});
      final secure = AuthSessionStore();
      final legacy = await secure.read();
      expect(legacy!.token, 'old-token');
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      await secure.write(stored(2));
      final raw = await ErebrusTestStorage.read();
      expect(raw['refresh_token'], 'refresh-2');
      expect(raw['expires_at'], isNotNull);
      expect((await secure.read())!.credentials.sessionId, 'session-user');
      await secure.clear();
      expect(await secure.read(), isNull);
    },
  );
}

void _backgroundRenew(List<dynamic> args) async {
  final reply = args[1] as SendPort;
  try {
    final repo = AuthRepository(
      brokerName: args[0] as String,
      gatewayUrl: 'https://gateway.test',
    );
    await repo.ensureFresh();
    reply.send('ok');
  } catch (e) {
    reply.send(e.toString());
  }
}

class ErebrusTestStorage {
  static Future<Map<String, dynamic>> read() async => Map<String, dynamic>.from(
    jsonDecode(
          (await const FlutterSecureStorage().read(
            key: AuthSessionStore.kSession,
          ))!,
        )
        as Map,
  );
}
