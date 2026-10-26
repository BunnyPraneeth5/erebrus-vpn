import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_web_auth.dart';
import 'wallet_auth_controller.dart';

/// Routes `erebrusvpn://` callbacks — desktop PASETO auth and mobile Reown envelopes.
class DeepLinkHandler {
  static const _methodChannel = MethodChannel('com.erebrus.vpn/methods');
  static const _eventChannel = EventChannel('com.erebrus.vpn/events');

  static WalletAuthController? _auth;

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
  }

  static void checkInitialLink() {
    if (kIsWeb) return;
    try {
      _methodChannel.invokeMethod<void>('initialLink');
    } catch (e) {
      debugPrint('[DeepLinkHandler] checkInitialLink $e');
    }
  }

  static Future<void> _onLink(dynamic link) async {
    if (link == null) return;
    final url = link.toString();
    final auth = _auth;
    if (auth == null) {
      debugPrint('[DeepLinkHandler] auth not bound');
      return;
    }

    if (DesktopWebAuth.isAuthCallback(url)) {
      await auth.handleWebAuthCallback(url);
      return;
    }

    final modal = auth.appKitModal;
    if (modal == null) {
      debugPrint('[DeepLinkHandler] unhandled link (no Reown session)');
      return;
    }
    final handled = await modal.dispatchEnvelope(url);
    if (!handled) {
      debugPrint('[DeepLinkHandler] Reown did not handle link');
    }
  }

  static void _onError(dynamic error) {
    debugPrint('[DeepLinkHandler] $error');
  }
}
