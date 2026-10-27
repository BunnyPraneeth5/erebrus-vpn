import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _appMethods = MethodChannel('com.erebrus.vpn/methods');

/// Sends the app to the background without finishing the activity, so the
/// Flutter engine (and the Dart tunnel health / kill-switch monitors) keep
/// running on Android 11 and lower too. Falls back to the default system pop.
Future<void> moveAppToBackground() async {
  try {
    final moved = await _appMethods.invokeMethod<bool>('moveTaskToBack');
    if (moved == true) return;
  } on MissingPluginException {
    // Fall through to the system default.
  } on PlatformException catch (e) {
    debugPrint('[ShellBack] moveTaskToBack failed: $e');
  }
  await SystemNavigator.pop();
}

/// System back (Android button / gesture) for the tabbed [MainShell].
///
/// Tabs are [IndexedStack] index switches on a single route, so without this
/// back has nothing to pop and closes the app. Back steps the browser through
/// web history, then returns to the VPN tab, and only then leaves the app.
class ShellBackScope extends StatelessWidget {
  const ShellBackScope({
    super.key,
    required this.index,
    required this.onSelectTab,
    required this.browserBack,
    this.moveToBackground,
    required this.child,
  });

  static const homeIndex = 0;
  static const browserIndex = 1;

  final int index;
  final ValueChanged<int> onSelectTab;

  /// Steps the browser back one page; false when it has no history.
  final Future<bool> Function() browserBack;

  /// Called for back on the VPN tab. Null leaves it to the system (iOS and
  /// desktop have no root-level back to intercept).
  final Future<void> Function()? moveToBackground;

  final Widget child;

  Future<void> _onBack() async {
    if (index == browserIndex && await browserBack()) return;
    if (index != homeIndex) {
      onSelectTab(homeIndex);
      return;
    }
    await moveToBackground?.call();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: index == homeIndex && moveToBackground == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_onBack());
      },
      child: child,
    );
  }
}
