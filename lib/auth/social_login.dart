import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_config.dart';
import 'runtime_config.dart';

/// Thin wrappers around the native OIDC providers. Each returns the provider's
/// id_token (a JWT the gateway verifies) or `null` when the user cancels.
/// Callers gate these on availability so an unconfigured provider is never
/// invoked.

/// Whether native Google sign-in can run. iOS uses its bundle-specific client
/// id while the returned token targets the configured gateway/server client.
bool get googleSignInSupported =>
    RuntimeConfig.googleServerClientId.isNotEmpty &&
    (Platform.isAndroid || (Platform.isIOS && kGoogleIosClientId.isNotEmpty));

/// Whether Apple sign-in can run: native on iOS/macOS, or a configured Services
/// id elsewhere.
Future<bool> appleSignInSupported() async {
  if (Platform.isIOS || Platform.isMacOS) {
    try {
      return await SignInWithApple.isAvailable();
    } catch (_) {
      return false;
    }
  }
  return (kIsWeb || Platform.isAndroid) && kAppleServiceId.isNotEmpty;
}

/// Runs the Google sign-in sheet and returns an id_token, or null if cancelled.
Future<String?> googleIdToken() async {
  final google = GoogleSignIn(
    clientId: Platform.isIOS ? kGoogleIosClientId : null,
    serverClientId: RuntimeConfig.googleServerClientId,
    scopes: const ['email'],
  );
  final account = await google.signIn();
  if (account == null) return null; // user dismissed the chooser
  final auth = await account.authentication;
  final token = auth.idToken;
  if (token == null || token.isEmpty) {
    throw const SocialLoginException('Google did not return an identity token');
  }
  return token;
}

/// Runs Apple sign-in and returns every value the gateway validates.
Future<AppleLoginCredential?> appleCredential() async {
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    throw const SocialLoginException(
      'Apple sign-in is not supported on this platform',
    );
  }
  final useWebRelay = !(Platform.isIOS || Platform.isMacOS);
  final nonce = generateNonce();
  final state = 'vpn.${generateNonce()}';
  try {
    final cred = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      webAuthenticationOptions: useWebRelay && kAppleServiceId.isNotEmpty
          ? WebAuthenticationOptions(
              clientId: kAppleServiceId,
              redirectUri: Uri.parse(kAppleRedirectUri),
            )
          : null,
      nonce: nonce,
      state: state,
    );
    final token = cred.identityToken;
    if (token == null || token.isEmpty) {
      throw const SocialLoginException(
        'Apple did not return an identity token',
      );
    }
    if (cred.authorizationCode.isEmpty) {
      throw const SocialLoginException(
        'Apple did not return an authorization code',
      );
    }
    if (cred.state != state) {
      throw const SocialLoginException(
        'Apple sign-in state mismatch — please try again',
      );
    }
    return AppleLoginCredential(
      identityToken: token,
      authorizationCode: cred.authorizationCode,
      nonce: nonce,
      state: state,
    );
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    throw SocialLoginException(
      e.message.isEmpty ? 'Apple sign-in failed' : e.message,
    );
  }
}

class AppleLoginCredential {
  const AppleLoginCredential({
    required this.identityToken,
    required this.authorizationCode,
    required this.nonce,
    required this.state,
  });

  final String identityToken;
  final String authorizationCode;
  final String nonce;
  final String state;
}

/// Best-effort sign-out from the Google session (so the chooser shows next time).
Future<void> googleSignOut() async {
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) return;
  try {
    await GoogleSignIn().signOut();
  } catch (e) {
    debugPrint('[social] google signOut: $e');
  }
}

class SocialLoginException implements Exception {
  const SocialLoginException(this.message);
  final String message;
  @override
  String toString() => message;
}
