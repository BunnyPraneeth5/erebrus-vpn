import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/secure_storage.dart';
import 'auth_session.dart';

/// One Keychain/Keystore item is the commit unit for the entire session.
/// Never use the desktop preferences fallback for authentication credentials.
class AuthSessionStore {
  AuthSessionStore({FlutterSecureStorage? storage, String? namespace})
    : _storage = storage ?? ErebrusSecureStorage.instance,
      _sessionKey = namespace == null
          ? kSession
          : '$kSession.${base64Url.encode(utf8.encode(namespace))}';

  final FlutterSecureStorage _storage;
  final String _sessionKey;
  static const kSession = 'com.erebrus.vpn.auth.session.v2';
  static const kToken = 'erebrus_gateway_token';
  static const kWallet = 'erebrus_wallet_address';
  static const kUserId = 'erebrus_user_id';
  static const kRole = 'erebrus_user_role';
  static const kAuthMethod = 'erebrus_auth_method';
  static const kMwaToken = 'erebrus_mwa_auth_token';
  static const _legacyKeys = [
    kToken,
    kWallet,
    kUserId,
    kRole,
    kAuthMethod,
    kMwaToken,
  ];

  Future<StoredAuthSession?> read() async {
    _requireNative();
    final blob = await _storage.read(key: _sessionKey);
    if (blob != null) {
      // A tombstone prevents resurrection from old, partially removed keys.
      final json = jsonDecode(blob) as Map<String, dynamic>;
      if (json['signed_out'] == true) return null;
      return StoredAuthSession.fromJson(json);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final token =
        await _storage.read(key: kToken) ??
        prefs.getString('erebrus_auth_$kToken');
    if (token == null || token.isEmpty) return null;
    Future<String?> legacy(String key) async =>
        await _storage.read(key: key) ?? prefs.getString('erebrus_auth_$key');
    final migrated = StoredAuthSession(
      credentials: AuthSession(
        token: token,
        walletAddress: await legacy(kWallet) ?? '',
        userId: await legacy(kUserId) ?? '',
        role: await legacy(kRole) ?? 'user',
      ),
      authMethod: await legacy(kAuthMethod) ?? 'reown',
      mwaAuthToken: await legacy(kMwaToken),
    );
    await write(migrated);
    return migrated;
  }

  Future<void> write(StoredAuthSession session) async {
    _requireNative();
    await _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));
    await _removeLegacy();
  }

  Future<void> clear() async {
    _requireNative();
    await _storage.write(key: _sessionKey, value: '{"signed_out":true}');
    await _removeLegacy();
  }

  Future<void> _removeLegacy() async {
    // Best effort after the atomic commit; old copies are never authoritative.
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in _legacyKeys) {
        await prefs.remove('erebrus_auth_$key');
        await _storage.delete(key: key);
      }
    } catch (_) {}
  }

  void _requireNative() {
    if (kIsWeb) {
      throw UnsupportedError(
        'Browser login requires a server-side HttpOnly session.',
      );
    }
  }
}

class StoredAuthSession {
  const StoredAuthSession({
    required this.credentials,
    required this.authMethod,
    this.mwaAuthToken,
    this.renewalUncertain = false,
    this.loginRequired = false,
    this.retryAt,
  });
  final AuthSession credentials;
  final String authMethod;
  final String? mwaAuthToken;
  final bool renewalUncertain;
  final bool loginRequired;
  final DateTime? retryAt;
  String get token => credentials.token;
  String get walletAddress => credentials.walletAddress;
  String get userId => credentials.userId;
  String get role => credentials.role;

  StoredAuthSession withCredentials(AuthSession credentials) =>
      StoredAuthSession(
        credentials: credentials,
        authMethod: authMethod,
        mwaAuthToken: mwaAuthToken,
      );
  StoredAuthSession withStatus({
    bool uncertain = false,
    bool loginRequired = false,
    DateTime? retryAt,
  }) => StoredAuthSession(
    credentials: credentials,
    authMethod: authMethod,
    mwaAuthToken: mwaAuthToken,
    renewalUncertain: uncertain,
    loginRequired: loginRequired,
    retryAt: retryAt,
  );
  Map<String, dynamic> toJson() => {
    ...credentials.toJson(),
    'auth_method': authMethod,
    'mwa_auth_token': mwaAuthToken,
    'renewal_uncertain': renewalUncertain,
    'login_required': loginRequired,
    'retry_at': retryAt?.toUtc().toIso8601String(),
  };
  factory StoredAuthSession.fromJson(Map<String, dynamic> json) =>
      StoredAuthSession(
        credentials: AuthSession.fromJson(json),
        authMethod: json['auth_method'] as String,
        mwaAuthToken: json['mwa_auth_token'] as String?,
        renewalUncertain: json['renewal_uncertain'] == true,
        loginRequired: json['login_required'] == true,
        retryAt: DateTime.tryParse('${json['retry_at']}'),
      );
}
