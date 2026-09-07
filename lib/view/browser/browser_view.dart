import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../platform/desktop_browser.dart';
import '../../platform/platform_capabilities.dart';
import '../../theme/app_theme.dart';
import '../../theme/premium_widgets.dart';
import 'browser_controller.dart';
import 'browser_link_menu.dart';
import 'browser_session_status.dart';

/// In-app private browser: tab strip, omnibox, the private start page (service
/// grid) and the WebView for real pages, all over the dVPN tunnel.
///
/// The native WebView platform view is mounted only while the BROWSER tab is
/// selected in [MainShell]'s [IndexedStack] — embedding it in a hidden
/// IndexedStack child freezes many Android devices.
class BrowserView extends StatefulWidget {
  const BrowserView({super.key});

  @override
  State<BrowserView> createState() => _BrowserViewState();
}

class _BrowserViewState extends State<BrowserView> with RouteAware {
  late final BrowserController _c;
  ModalRoute<dynamic>? _route;
  int _routeGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route == route) return;
    browserRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) browserRouteObserver.subscribe(this, route);
    _c.setRouteCovered(route != null && !route.isCurrent);
  }

  @override
  void didPushNext() {
    _routeGeneration++;
    _c.setRouteCovered(true);
  }

  @override
  void didPopNext() {
    final generation = ++_routeGeneration;
    final departing = browserRouteObserver.departingRoute;
    if (!PlatformCapabilities.usesDesktopVpnRunner || departing == null) {
      _c.setRouteCovered(false);
      return;
    }
    unawaited(
      departing.then((_) {
        if (mounted &&
            generation == _routeGeneration &&
            _route?.isCurrent == true) {
          _c.setRouteCovered(false);
        }
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    _c = Get.isRegistered<BrowserController>()
        ? Get.find<BrowserController>()
        : Get.put(BrowserController());
    _c.linkContextMenuHandler = _onLinkContextMenu;
  }

  @override
  void dispose() {
    browserRouteObserver.unsubscribe(this);
    _c.linkContextMenuHandler = null;
    _c.setShellTabVisible(false);
    super.dispose();
  }

  void _onLinkContextMenu(BrowserLinkHit hit) {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    showBrowserLinkContextMenu(context, _c, hit);
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformCapabilities.supportsEmbeddedBrowser) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.web_asset_off,
                    size: 40,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Embedded browser unavailable',
                    textAlign: TextAlign.center,
                    style: grotesk(size: 20, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'In-app browsing is not supported on this platform. '
                    'VPN controls remain available.',
                    textAlign: TextAlign.center,
                    style: grotesk(size: 14, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final c = _c;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Obx(() {
              c.tabs.length; // observe
              c.activeIndex.value;
              return _TabStrip(controller: c);
            }),
            Obx(() {
              c.addressBar.value; // observe
              return _Omnibox(controller: c);
            }),
            const BrowserSessionStrip(),
            Expanded(
              child: Obx(() {
                c.tabs.length;
                c.activeIndex.value;
                c.addressBar.value;
                if (c.tabs.isEmpty) return const SizedBox.shrink();
                final tab = c.activeTab;
                if (tab.isStart) return const _StartPage();
                if (PlatformCapabilities.usesDesktopVpnRunner &&
                    !c.protectionAvailable.value) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Connect VPN to browse securely',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final error = c.browserError.value;
                if (error != null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(error, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: c.reload,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                if (!c.canMountBrowser || !tab.configured) {
                  // Shell is on VPN/Settings — keep Flutter-only UI in the tree.
                  return _PendingWebPage(
                    url: tab.url,
                    loading: c.isLoading.value,
                  );
                }
                if (PlatformCapabilities.usesDesktopVpnRunner) {
                  return Column(
                    children: [
                      SizedBox(
                        height: 2,
                        child: c.isLoading.value
                            ? const LinearProgressIndicator(
                                backgroundColor: Colors.transparent,
                                color: AppColors.accent,
                              )
                            : null,
                      ),
                      Expanded(
                        child: _DesktopWebPage(
                          key: ValueKey('${tab.id}:${tab.generation}'),
                          browser: c,
                          tab: tab,
                        ),
                      ),
                    ],
                  );
                }
                return Stack(
                  children: [
                    WebViewWidget(
                      key: ValueKey('${tab.id}:${tab.generation}'),
                      controller: tab.controller,
                    ),
                    if (c.isLoading.value)
                      const LinearProgressIndicator(
                        minHeight: 2,
                        backgroundColor: Colors.transparent,
                        color: AppColors.accent,
                      ),
                  ],
                );
              }),
            ),
            _ControlBar(controller: c),
          ],
        ),
      ),
    );
  }
}

/// Shown when a tab has a URL but the BROWSER shell tab is not visible.
class _PendingWebPage extends StatelessWidget {
  const _PendingWebPage({required this.url, required this.loading});
  final String url;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            if (loading) const SizedBox(height: 16),
            Text(
              'Ready to load',
              style: grotesk(size: 16, weight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              url,
              textAlign: TextAlign.center,
              style: mono(size: 12, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopWebPage extends StatefulWidget {
  const _DesktopWebPage({super.key, required this.browser, required this.tab});

  final BrowserController browser;
  final BrowserTab tab;

  @override
  State<_DesktopWebPage> createState() => _DesktopWebPageState();
}

class _DesktopWebPageState extends State<_DesktopWebPage> {
  @override
  void initState() {
    super.initState();
    unawaited(_showWhenLaidOut());
  }

  @override
  void activate() {
    super.activate();
    unawaited(_showWhenLaidOut());
  }

  Future<void> _showWhenLaidOut() async {
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) await widget.browser.showNativeTab(widget.tab);
  }

  @override
  Widget build(BuildContext context) =>
      WebViewWidget(controller: widget.tab.controller);
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.controller});
  final BrowserController controller;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        children: [
          ...List.generate(controller.tabs.length, (i) {
            final tab = controller.tabs[i];
            final active = controller.activeIndex.value == i;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => controller.selectTab(i),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 150),
                  padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: active
                        ? AppColors.surface3
                        : const Color(0xFF101014),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                      color: active
                          ? AppColors.accent.withValues(alpha: 0.35)
                          : AppColors.stroke,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: active
                              ? AppColors.accent
                              : const Color(0xFF4A4A52),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          tab.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: grotesk(
                            size: 12.5,
                            weight: FontWeight.w500,
                            color: active
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => controller.closeTab(i),
                        child: const Icon(
                          Icons.close,
                          size: 13,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          GestureDetector(
            onTap: () => controller.addTab(),
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.strokeHi),
              ),
              child: const Icon(
                Icons.add,
                size: 17,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Omnibox extends StatefulWidget {
  const _Omnibox({required this.controller});
  final BrowserController controller;
  @override
  State<_Omnibox> createState() => _OmniboxState();
}

class _OmniboxState extends State<_Omnibox> {
  late final TextEditingController _text;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.controller.addressBar.value);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rawUrl = widget.controller.addressBar.value;
    // Don't surface the internal start-page scheme (erebrus://home) in the
    // address bar — keep it blank so the "Search or enter address" hint shows.
    final url = rawUrl == kStartPage ? '' : rawUrl;
    if (!_focus.hasFocus && _text.text != url) _text.text = url;
    final desktop = PlatformCapabilities.isDesktop;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Row(
        children: [
          if (desktop) ...[
            _DesktopBrowserButton(
              icon: Icons.arrow_back,
              tooltip: 'Back',
              onTap: widget.controller.goBack,
            ),
            const SizedBox(width: 6),
            _DesktopBrowserButton(
              icon: Icons.arrow_forward,
              tooltip: 'Forward',
              onTap: widget.controller.goForward,
            ),
            const SizedBox(width: 6),
            _DesktopBrowserButton(
              icon: Icons.home_outlined,
              tooltip: 'Home',
              onTap: widget.controller.goHome,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: AppColors.stroke),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      style: mono(
                        size: 13,
                        weight: FontWeight.w400,
                        color: const Color(0xFFC8C7C2),
                      ),
                      cursorColor: AppColors.accent,
                      textInputAction: TextInputAction.go,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Search or enter address',
                      ),
                      onSubmitted: (v) => widget.controller.navigate(v),
                    ),
                  ),
                  GestureDetector(
                    onTap: widget.controller.reload,
                    child: const Icon(
                      Icons.refresh,
                      size: 17,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopBrowserButton extends StatelessWidget {
  const _DesktopBrowserButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Icon(icon, size: 18, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _StartPage extends StatefulWidget {
  const _StartPage();

  @override
  State<_StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<_StartPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  BrowserController get _browser => Get.isRegistered<BrowserController>()
      ? Get.find<BrowserController>()
      : Get.put(BrowserController());

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submitSearch() {
    final query = _search.text;
    if (query.trim().isEmpty) return;
    _browser.searchPrivateWeb(query);
    _search.clear();
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final screenSize = MediaQuery.sizeOf(context);
    final compact = screenSize.width < 380;
    final tightHeight = screenSize.height < 700;
    final toolColumns = PlatformCapabilities.isDesktop ? 3 : 2;
    final services = <_Service>[
      _Service(
        'Speed Test',
        'Download, upload & latency',
        'https://fast.com/',
        Icons.speed,
        AppColors.accent,
        AppColors.accent.withValues(alpha: 0.14),
      ),
      _Service(
        'Public IP',
        'Verify VPN exit location',
        'https://ipinfo.io/what-is-my-ip',
        Icons.public,
        const Color(0xFF7E96F0),
        AppColors.ethereum.withValues(alpha: 0.16),
      ),
      _Service(
        'DNS Leak',
        'Check exposed resolvers',
        'https://www.dnsleaktest.com/',
        Icons.dns_outlined,
        AppColors.shared,
        AppColors.shared.withValues(alpha: 0.16),
      ),
      _Service(
        'WebRTC Leak',
        'Check browser IP exposure',
        'https://browserleaks.com/webrtc',
        Icons.visibility_outlined,
        AppColors.success,
        AppColors.success.withValues(alpha: 0.16),
      ),
      _Service(
        'IPv6 Test',
        'Check IPv6 routing',
        'https://test-ipv6.com/',
        Icons.route_outlined,
        const Color(0xFFB07CFF),
        AppColors.solana.withValues(alpha: 0.18),
      ),
      _Service(
        'Connection Info',
        'DNS & data-center details',
        'https://1.1.1.1/help',
        Icons.hub_outlined,
        AppColors.warn,
        AppColors.warn.withValues(alpha: 0.16),
      ),
    ];

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        22,
        tightHeight ? 4 : 8,
        22,
        16 + bottomInset,
      ),
      children: [
        Text(
          'Sovereign web.',
          style: grotesk(
            size: compact || tightHeight ? 28 : 32,
            weight: FontWeight.w600,
            letterSpacing: -0.8,
          ),
        ),
        SizedBox(height: tightHeight ? 12 : 18),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.stroke),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, size: 18, color: AppColors.textMuted),
              const SizedBox(width: 11),
              Expanded(
                child: TextField(
                  controller: _search,
                  focusNode: _focus,
                  style: grotesk(
                    size: 14,
                    weight: FontWeight.w400,
                    color: AppColors.textPrimary,
                  ),
                  cursorColor: AppColors.accent,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search the private web…',
                    hintStyle: grotesk(
                      size: 14,
                      weight: FontWeight.w400,
                      color: AppColors.textMuted,
                    ),
                  ),
                  onSubmitted: (_) => _submitSearch(),
                ),
              ),
              _SearchActionButton(
                icon: Icons.arrow_forward,
                tooltip: 'Search',
                onTap: () => _submitSearch(),
              ),
            ],
          ),
        ),
        SizedBox(height: tightHeight ? 14 : 22),
        Text(
          'NETWORK TOOLS',
          style: mono(
            size: 11,
            weight: FontWeight.w500,
            color: AppColors.textMuted,
            letterSpacing: 11 * 0.12,
          ),
        ),
        SizedBox(height: tightHeight ? 8 : 12),
        GridView.count(
          crossAxisCount: toolColumns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          mainAxisExtent: tightHeight ? 70 : 80,
          children: [
            for (final s in services)
              _ServiceCard(
                service: s,
                onTap: () {
                  _browser.navigate(s.url);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _SearchActionButton extends StatelessWidget {
  const _SearchActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: AppColors.accent),
        ),
      ),
    );
  }
}

class _Service {
  const _Service(
    this.title,
    this.sub,
    this.url,
    this.icon,
    this.color,
    this.chip,
  );
  final String title;
  final String sub;
  final String url;
  final IconData icon;
  final Color color;
  final Color chip;
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({required this.service, required this.onTap});
  final _Service service;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.stroke),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: service.chip,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(service.icon, size: 16, color: service.color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    service.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: grotesk(size: 13, weight: FontWeight.w600),
                  ),
                  Text(
                    service.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: grotesk(
                      size: 11,
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

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.controller});
  final BrowserController controller;

  void _showMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.refresh,
                color: AppColors.textSecondary,
              ),
              title: Text(
                'Reload page',
                style: grotesk(size: 15, weight: FontWeight.w600),
              ),
              onTap: () {
                Navigator.pop(ctx);
                controller.reload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add, color: AppColors.textSecondary),
              title: Text(
                'New tab',
                style: grotesk(size: 15, weight: FontWeight.w600),
              ),
              onTap: () {
                Navigator.pop(ctx);
                controller.addTab();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.open_in_new,
                color: AppColors.textSecondary,
              ),
              title: Text(
                'Open in new tab',
                style: grotesk(size: 15, weight: FontWeight.w600),
              ),
              onTap: () {
                Navigator.pop(ctx);
                final tab = controller.activeTab;
                if (tab.isStart) {
                  controller.addTab();
                  return;
                }
                controller.openInNewTab(tab.url);
              },
            ),
            ListTile(
              leading: const Icon(Icons.tab, color: AppColors.textSecondary),
              title: Text(
                'All tabs',
                style: grotesk(size: 15, weight: FontWeight.w600),
              ),
              onTap: () {
                Navigator.pop(ctx);
                showBrowserTabsSheet(context, controller);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.strokeSoft)),
        ),
        child: Obx(() {
          controller.activeIndex.value;
          controller.tabs.length;
          final tab = controller.activeTab;
          final onWeb = !tab.isStart && tab.configured;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _CtlIcon(
                Icons.arrow_back,
                onTap: controller.goBack,
                enabled: onWeb && tab.canGoBack,
              ),
              _CtlIcon(
                Icons.arrow_forward,
                onTap: controller.goForward,
                enabled: onWeb && tab.canGoForward,
              ),
              _CtlIcon(Icons.home_outlined, onTap: controller.goHome),
              GestureDetector(
                onTap: () => showBrowserTabsSheet(context, controller),
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.strokeHi),
                  ),
                  child: Text(
                    '${controller.tabs.length}',
                    style: mono(
                      size: 11,
                      weight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              _CtlIcon(Icons.more_horiz, onTap: () => _showMenu(context)),
            ],
          );
        }),
      ),
    );
  }
}

void showBrowserTabsSheet(BuildContext context, BrowserController controller) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.raised,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (_, scrollController) => Obx(() {
        controller.tabs.length;
        controller.activeIndex.value;
        final tabs = controller.tabs;
        final active = controller.activeIndex.value;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  Text(
                    'Tabs',
                    style: grotesk(size: 18, weight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  MonoChip(
                    label: '${tabs.length}',
                    color: AppColors.textSecondary,
                    background: AppColors.surface2,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.add, color: AppColors.textSecondary),
                    tooltip: 'New tab',
                    onPressed: () => controller.addTab(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.strokeSoft),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                itemCount: tabs.length,
                itemBuilder: (_, i) {
                  final tab = tabs[i];
                  final isActive = i == active;
                  final subtitle = tab.isStart ? 'Erebrus home' : tab.url;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isActive ? AppColors.surface3 : AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          controller.selectTab(i);
                          Navigator.pop(ctx);
                        },
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? AppColors.accent.withValues(alpha: 0.35)
                                  : AppColors.stroke,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? AppColors.accent
                                      : AppColors.textMuted,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      tab.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: grotesk(
                                        size: 14.5,
                                        weight: FontWeight.w600,
                                        color: isActive
                                            ? AppColors.textPrimary
                                            : AppColors.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: mono(
                                        size: 11,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  size: 18,
                                  color: AppColors.textMuted,
                                ),
                                onPressed: () => controller.closeTab(i),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      }),
    ),
  );
}

class _CtlIcon extends StatelessWidget {
  const _CtlIcon(this.icon, {required this.onTap, this.enabled = true});
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    return VisibleIconButton(
      icon: icon,
      size: 40,
      iconSize: 20,
      onTap: onTap,
      enabled: enabled,
    );
  }
}
