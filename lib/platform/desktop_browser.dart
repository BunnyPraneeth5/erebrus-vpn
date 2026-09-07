import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

final browserRouteObserver = BrowserRouteObserver();

class BrowserRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  Future<void>? departingRoute;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    departingRoute = route is TransitionRoute<dynamic>
        ? route.completed.then<void>((_) {})
        : null;
    super.didPop(route, previousRoute);
  }
}

class DesktopBrowser {
  static const channel = MethodChannel('dev.erebrus/browser');

  static Future<void> prepare() async {
    if (await channel.invokeMethod<bool>('configure') != true) {
      throw StateError('The secure browser proxy could not be configured.');
    }
  }

  static Future<WebViewController> createController() async {
    final support = await getApplicationSupportDirectory();
    final profile = Directory(
      '${support.path}${Platform.pathSeparator}Erebrus browser profile',
    );
    await profile.create(recursive: true);
    return WebViewController.fromPlatformCreationParams(
      WindowsWebViewControllerCreationParams(userDataFolder: profile.path),
    );
  }

  static Future<void> secure(WebViewController controller) async {
    await controller.getTitle();
    await setVisibility(controller, false);
    if (await channel.invokeMethod<bool>('secureViews') != true) {
      throw StateError(
        'Browser network and WebRTC protection could not be verified.',
      );
    }
  }

  static Future<void> setVisibility(
    WebViewController controller,
    bool visible,
  ) async {
    final platform = controller.platform;
    if (platform is WindowsPlatformWebViewController) {
      await platform.controller.setVisibility(visible);
    }
  }

  static Future<void> disposeController(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is! WindowsPlatformWebViewController) return;
    try {
      await platform.controller.setVisibility(false);
    } finally {
      try {
        await platform.controller.cancelNavigate();
      } finally {
        await WidgetsBinding.instance.endOfFrame;
        await platform.controller.dispose();
      }
    }
  }

  static Future<void> configureController(
    WebViewController controller,
    NavigationDelegate delegate,
    String channelName,
    void Function(JavaScriptMessage) onMessage,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) return;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    if (!isCurrent()) return;
    final platform = controller.platform;
    if (platform is WindowsPlatformWebViewController) {
      await platform.controller.addJavaScriptChannel(
        channelName,
        onMessageReceived: onMessage,
      );
      if (!isCurrent()) return;
      await platform.controller.setNavigationDelegate(
        WinNavigationDelegate(
          onNavigationRequest: delegate.onNavigationRequest,
          onPageStarted: delegate.onPageStarted,
          onPageFinished: delegate.onPageFinished,
          onWebResourceError: delegate.onWebResourceError,
        ),
      );
    } else {
      await controller.addJavaScriptChannel(
        channelName,
        onMessageReceived: onMessage,
      );
      if (!isCurrent()) return;
      await controller.setNavigationDelegate(delegate);
    }
  }
}
