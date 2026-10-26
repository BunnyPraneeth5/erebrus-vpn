import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:reown_appkit/reown_appkit.dart';

import 'dart:async';

import 'auth/deep_link_handler.dart';
import 'auth/runtime_config.dart';
import 'auth/wallet_auth_controller.dart';
import 'guest/guest_config_store.dart';
import 'platform/desktop_browser.dart';
import 'platform/desktop_shell.dart';
import 'platform/platform_capabilities.dart';
import 'settings/app_settings_controller.dart';
import 'theme/app_theme.dart';
import 'view/auth/desktop_auth_host.dart';
import 'view/auth/reown_host.dart';
import 'view/root_view.dart';
import 'view/browser/browser_controller.dart';
import 'vpn/gateway_controller.dart';
import 'vpn/vpn_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RuntimeConfig.load();
  DeepLinkHandler.initListener();
  if (PlatformCapabilities.isMobile) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }
  Get.put(VpnController(), permanent: true);
  Get.put(AppSettingsController(), permanent: true);
  await Get.find<AppSettingsController>().load();
  Get.put(GuestConfigController(), permanent: true);
  Get.put(BrowserController(), permanent: true);
  final auth = WalletAuthController();
  Get.put(auth, permanent: true);
  await auth.detectDevice();
  await auth.loadPersistedSession();
  unawaited(auth.loadAuthMethods());
  Get.put(GatewayController(), permanent: true);
  // Refresh nodes and native state after the first frame so the app renders faster.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Get.find<GatewayController>().refreshNodes();
    await Get.find<VpnController>().syncWithNative();
  });
  Timer.periodic(const Duration(minutes: 5), (_) {
    if (Get.isRegistered<AppSettingsController>()) {
      Get.find<AppSettingsController>().pingDiagnosticsIfEnabled(
        vpn: Get.isRegistered<VpnController>()
            ? Get.find<VpnController>()
            : null,
      );
    }
  });
  debugPrint(
    '[Erebrus] started — platform=${PlatformCapabilities.platformLabel} '
    'solanaMobile=${auth.isSolanaMobileDevice.value}, session restored',
  );
  runApp(
    ErebrusVpnApp(
      usesReown: auth.usesReown,
      usesWebLogin: auth.usesWebLogin,
      useDesktopShell: PlatformCapabilities.supportsTray,
    ),
  );
}

class ErebrusVpnApp extends StatelessWidget {
  const ErebrusVpnApp({
    super.key,
    required this.usesReown,
    required this.usesWebLogin,
    required this.useDesktopShell,
  });

  final bool usesReown;
  final bool usesWebLogin;
  final bool useDesktopShell;

  @override
  Widget build(BuildContext context) {
    Widget shell = const RootView();
    if (usesWebLogin) shell = DesktopAuthHost(child: shell);
    if (usesReown) shell = ReownHost(child: shell);
    final home = useDesktopShell ? DesktopShell(child: shell) : shell;

    final app = GetMaterialApp(
      title: 'Erebrus VPN',
      navigatorObservers: [browserRouteObserver],
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: home,
    );

    if (!usesReown) return app;

    return ReownAppKitModalTheme(isDarkMode: true, child: app);
  }
}
