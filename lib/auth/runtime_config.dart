import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'auth_config.dart';

/// Loads secrets from the project-root `.env` bundled as an app asset.
/// Compile-time `--dart-define-from-file` still wins when set.
class RuntimeConfig {
  RuntimeConfig._();

  static final _values = <String, String>{};

  static String get reownProjectId =>
      _firstNonEmpty([kReownProjectId, _values['REOWN_PROJECT_ID']]);

  static bool get hasReownProjectId => reownProjectId.isNotEmpty;

  /// Google web/server client whose audience the gateway validates. A
  /// compile-time override wins, followed by `.env`, then production default.
  static String get googleServerClientId => _firstNonEmpty([
    kGoogleServerClientId,
    _values['GOOGLE_SERVER_CLIENT_ID'],
    kDefaultGoogleServerClientId,
  ]);

  static String get gatewayUrl => _values['GATEWAY_URL'] ?? '';

  /// Shows "Continue with Google" on Android only when explicitly enabled
  /// (`GOOGLE_LOGIN_ENABLED=true` via dart-define or `.env`). Android Google
  /// Sign-In fails with ApiException 10 until the signing key's SHA-1 is
  /// registered for com.erebrus.vpn in Google Cloud, so it defaults to off.
  static bool get googleLoginEnabled =>
      _firstNonEmpty([
        kGoogleLoginEnabledDefine,
        _values['GOOGLE_LOGIN_ENABLED'],
      ]).toLowerCase() ==
      'true';

  /// Erebrus webapp origin for desktop browser sign-in (`.env` may use localhost).
  static String get erebrusWebOrigin =>
      _firstNonEmpty([_values['EREBRUS_WEB_ORIGIN'], kErebrusWebOrigin]);

  /// Origin for Reown / MWA pairing metadata and `{origin}/vpn/logo.png`.
  /// Localhost [erebrusWebOrigin] is ignored — wallets cannot reach loopback.
  static String get erebrusWalletOrigin {
    final origin = erebrusWebOrigin;
    if (_isUnreachableWalletOrigin(origin)) {
      return kErebrusProductionOrigin;
    }
    return origin;
  }

  /// WalletConnect / Reown metadata `url`.
  static String get erebrusSiteUrl =>
      erebrusSiteUrlFromOrigin(erebrusWalletOrigin);

  /// Reown modal + WalletConnect pairing icon (`{origin}/vpn/logo.png`).
  static String get erebrusSiteIcon =>
      erebrusSiteIconFromOrigin(erebrusWalletOrigin);

  /// MWA authorize identity URI (`{origin}/vpn/` + relative `logo.png`).
  static String get erebrusMwaIdentityUrl =>
      erebrusMwaIdentityUrlFromOrigin(erebrusWalletOrigin);

  static bool _isUnreachableWalletOrigin(String origin) {
    final host = Uri.tryParse(origin)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return true;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '0.0.0.0' ||
        host.endsWith('.local') ||
        host.startsWith('10.') ||
        host.startsWith('192.168.') ||
        host.startsWith('172.');
  }

  static Future<void> load() async {
    await _loadDotEnvAsset('.env');
    if (kReownProjectId.isNotEmpty) {
      debugPrint('[Config] REOWN_PROJECT_ID from --dart-define');
    } else if ((_values['REOWN_PROJECT_ID'] ?? '').isNotEmpty) {
      debugPrint('[Config] REOWN_PROJECT_ID loaded from bundled env');
    } else {
      debugPrint('[Config] REOWN_PROJECT_ID missing — add to .env and rebuild');
    }
  }

  static Future<void> _loadDotEnvAsset(String path) async {
    try {
      final raw = await rootBundle.loadString(path);
      _values.addAll(_parseDotEnv(raw));
    } catch (e) {
      debugPrint('[Config] could not load asset $path: $e');
    }
  }

  static Map<String, String> _parseDotEnv(String content) {
    final out = <String, String>{};
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      final i = t.indexOf('=');
      if (i <= 0) continue;
      final key = t.substring(0, i).trim();
      var value = t.substring(i + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      if (value.isNotEmpty) out[key] = value;
    }
    return out;
  }

  static String _firstNonEmpty(List<String?> candidates) {
    for (final c in candidates) {
      final v = c?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }
}
