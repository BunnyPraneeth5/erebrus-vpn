import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../auth/wallet_auth_controller.dart';
import '../../guest/guest_config_store.dart';
import '../../settings/app_settings_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/premium_widgets.dart';
import '../../vpn/singbox_engine.dart';
import '../../vpn/vpn_controller.dart';
import '../../vpn/vpn_models.dart';
import '../browser/browser_controller.dart';
import '../browser/browser_view.dart';
import '../guest/guest_connect_view.dart';
import '../home/connect_dial.dart';
import '../home/connect_view.dart';
import '../home/diagnostics_sheet.dart';
import '../home/server_sheet.dart';
import '../layout/desktop_layout.dart';
import '../layout/desktop_screen.dart';
import '../settings/settings_view.dart';

/// The authenticated app shell: VPN / BROWSER / SETTINGS, with the design's
/// frosted bottom tab bar. The server picker and diagnostics open as sheets.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _autoConnectAttempted = false;
  Worker? _autoConnectWorker;
  late final List<Widget> _tabs;

  void _go(int i) {
    if (_index == i) return;
    setState(() => _index = i);
    if (Get.isRegistered<BrowserController>()) {
      Get.find<BrowserController>().setShellTabVisible(i == 1);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabs = [
      const DesktopScreen(child: _HomeTab()),
      const DesktopScreen(
        layout: DesktopContentLayout.browser,
        child: BrowserView(),
      ),
      const DesktopScreen(child: SettingsView()),
    ];
    _autoConnectWorker = everAll([
      Get.find<AppSettingsController>().autoConnectOnLaunch,
      Get.find<WalletAuthController>().sessionReady,
      Get.find<WalletAuthController>().entitlement,
      Get.find<GuestConfigController>().selectedId,
      Get.find<VpnController>().selectedNode,
    ], (_) => _tryAutoConnect());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryAutoConnect());
    if (Get.isRegistered<BrowserController>()) {
      Get.find<BrowserController>().setShellTabVisible(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoConnectWorker?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final vpn = Get.find<VpnController>();
      final settings = Get.find<AppSettingsController>();
      final auth = Get.find<WalletAuthController>();
      if (auth.isAuthenticated) {
        unawaited(auth.refreshEntitlement());
      }
      unawaited(
        vpn.syncWithNative().then((_) {
          settings.pingDiagnosticsIfEnabled(vpn: vpn);
        }),
      );
    }
  }

  void _tryAutoConnect() {
    if (_autoConnectAttempted) return;
    final settings = Get.find<AppSettingsController>();
    final auth = Get.find<WalletAuthController>();
    final vpn = Get.find<VpnController>();
    final guest = Get.find<GuestConfigController>();
    if (vpn.isConnected) {
      _autoConnectAttempted = true;
      return;
    }
    if (!settings.autoConnectOnLaunch.value) return;
    if (vpn.isConnected || vpn.isBusy || vpn.killSwitchBlocking.value) return;

    if (auth.isAuthenticated) {
      if (!auth.sessionReady.value ||
          !auth.canConnectVpn(vpn.selectedNode.value)) {
        return;
      }
      if (vpn.selectedNode.value == null) return;
      _autoConnectAttempted = true;
      vpn.connect();
    } else {
      final config = guest.selected;
      if (config == null) return;
      final node = config.toNode();
      vpn.selectNode(node);
      _autoConnectAttempted = true;
      vpn.connect(
        node: node,
        providedBundle: config.bundle,
        clientPrivateKey: config.clientPrivateKey,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final useSideRail = DesktopLayout.useSideRail(
      MediaQuery.sizeOf(context).width,
    );

    return Scaffold(
      extendBody: false,
      backgroundColor: AppColors.bg,
      body: Row(
        children: [
          if (useSideRail) ...[_DesktopSidebar(index: _index, onTap: _go)],
          Expanded(
            child: IndexedStack(index: _index, children: _tabs),
          ),
        ],
      ),
      bottomNavigationBar: useSideRail
          ? null
          : _NavBar(index: _index, onTap: _go),
    );
  }
}

/// Home tab router: stable widget so [MainShell] does not rebuild it on every
/// bottom-nav tap. Switches between authenticated and guest UIs reactively.
class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final auth = Get.find<WalletAuthController>();
      return auth.isAuthenticated
          ? ConnectView(
              onOpenServers: () => showServerSheet(context),
              onOpenDiagnostics: () => showDiagnosticsSheet(context),
              onGoSettings: () {
                final shell = context
                    .findAncestorStateOfType<_MainShellState>();
                shell?._go(2);
              },
            )
          : const GuestConnectView();
    });
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (icon: Icons.shield, label: 'VPN'),
    (icon: Icons.explore, label: 'BROWSER'),
    (icon: Icons.tune, label: 'SETTINGS'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: DesktopLayout.sidebarWidth,
      padding: const EdgeInsets.fromLTRB(14, 22, 14, 18),
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(right: BorderSide(color: AppColors.stroke)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const BrandLogo(size: 28, radius: 8),
                const SizedBox(width: 9),
                Text(
                  'EREBRUS VPN',
                  style: mono(
                    size: 12,
                    weight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 34),
          Padding(
            padding: const EdgeInsets.only(left: 10, bottom: 9),
            child: Text(
              'WORKSPACE',
              style: mono(
                size: 10,
                weight: FontWeight.w600,
                color: AppColors.textDim,
                letterSpacing: 1.4,
              ),
            ),
          ),
          for (var i = 0; i < _items.length; i++) ...[
            _DesktopNavItem(
              icon: _items[i].icon,
              label: _items[i].label,
              selected: i == index,
              onTap: () => onTap(i),
            ),
            if (i != _items.length - 1) const SizedBox(height: 6),
          ],
          const Spacer(),
          Obx(() {
            final vpn = Get.find<VpnController>();
            return _DesktopConnectionCard(
              status: vpnSafetyStatus(vpn),
              detail: vpn.killSwitchEngaging.value
                  ? 'Verifying enforcement…'
                  : vpn.killSwitchBlocking.value
                  ? 'Open VPN to reconnect'
                  : vpn.isProtected
                  ? vpn.activeTransport.value?.label ?? 'Connection verified'
                  : switch (vpn.stage.value) {
                      VpnStage.connecting => 'Connecting…',
                      VpnStage.disconnecting => 'Disconnecting…',
                      VpnStage.connected => 'Connection health check failed',
                      VpnStage.error => 'Connection error · open VPN to retry',
                      _ => 'Ready to connect',
                    },
              onTap: () => onTap(0),
            );
          }),
        ],
      ),
    );
  }
}

class _DesktopNavItem extends StatelessWidget {
  const _DesktopNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.24)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 12),
              Text(
                label,
                style: mono(
                  size: 11,
                  weight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopConnectionCard extends StatelessWidget {
  const _DesktopConnectionCard({
    required this.status,
    required this.detail,
    required this.onTap,
  });

  final VpnSafetyStatus status;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = status.label;
    final color = status.color;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: status.isProtected
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.45),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: mono(
                      size: 10,
                      weight: FontWeight.w700,
                      color: color,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: grotesk(
                      size: 11.5,
                      weight: FontWeight.w400,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  static const _items = [
    (icon: Icons.shield, label: 'VPN'),
    (icon: Icons.explore, label: 'BROWSER'),
    (icon: Icons.tune, label: 'SETTINGS'),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: EdgeInsets.only(
            top: 12,
            bottom: bottomInset > 0 ? bottomInset : 10,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0C).withValues(alpha: 0.94),
            border: const Border(top: BorderSide(color: AppColors.stroke)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(_items.length, (i) {
              final it = _items[i];
              final active = i == index;
              final color = active ? AppColors.accent : AppColors.textSecondary;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(it.icon, size: 22, color: color),
                      const SizedBox(height: 5),
                      Text(
                        it.label,
                        style: mono(
                          size: 10,
                          weight: FontWeight.w500,
                          color: color,
                          letterSpacing: 10 * 0.05,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
