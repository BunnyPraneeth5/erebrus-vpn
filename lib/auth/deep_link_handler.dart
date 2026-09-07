import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_web_auth.dart';
import 'wallet_auth_controller.dart';

/// Routes `erebrusvpn://` callbacks — desktop PASETO auth and mobile Reown envelopes.
class DeepLinkHandler {
  static const _methodChannel = MethodChannel('com.erebrus.vpn/methods');
  static const _eventChannel = EventChannel('com.erebrus.vpn/events');

  static WalletAuthController? _auth;
  static String? _pendingLink;

  @visibleForTesting
  static void resetForTesting() {
    _auth = null;
    _pendingLink = null;
  }

  static void initListener() {
    if (kIsWeb) return;
    try {
      _eventChannel.receiveBroadcastStream().listen(_onLink, onError: _onError);
    } catch (e) {
      debugPrint('[DeepLinkHandler] initListener $e');
    }
  }

  static void bind(WalletAuthController auth) {
    if (kIsWeb) return;
    _auth = auth;
    final pendingLink = _pendingLink;
    _pendingLink = null;
    if (pendingLink != null) {
      unawaited(_onLink(pendingLink).catchError(_onError));
    }
  }

  static Future<void> checkInitialLink() async {
    if (kIsWeb) return;
    try {
      final link = await _methodChannel.invokeMethod<String>('initialLink');
      await _onLink(link);
    } on MissingPluginException {
      return;
    } catch (e) {
      debugPrint('[DeepLinkHandler] checkInitialLink $e');
    }
  }

  static Future<void> _onLink(dynamic link) async {
    if (link == null) return;
    final url = link.toString();
    final auth = _auth;
    if (auth == null) {
      _pendingLink = url;
      debugPrint('[DeepLinkHandler] auth not bound for $url');
      return;
    }

    if (DesktopWebAuth.isAuthCallback(url)) {
      await auth.handleWebAuthCallback(url);
      return;
    }

    final modal = auth.appKitModal;
    if (modal == null) {
      debugPrint('[DeepLinkHandler] unhandled link (no Reown session): $url');
      return;
    }
    final handled = await modal.dispatchEnvelope(url);
    if (!handled) {
      debugPrint('[DeepLinkHandler] Reown did not handle: $url');
    }
  }

  static void _onError(dynamic error) {
    debugPrint('[DeepLinkHandler] $error');
  }
}
