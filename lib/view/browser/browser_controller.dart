import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../vpn/vpn_controller.dart';
import 'browser_link_menu.dart';

/// The private start page (the "Sovereign web." service grid). New tabs open
/// here; navigating to a real URL hands off to the WebView.
const kStartPage = 'erebrus://home';
const kStartTitle = 'Erebrus Home';

/// Private web search provider (Brave).
const kBraveSearch = 'https://search.brave.com/search?q=';

/// Fallback web home if a real page is requested without a URL.
const kBrowserHome = 'https://search.brave.com';

class BrowserTab {
  BrowserTab({
    required this.id,
    required this.url,
    this.title = 'New tab',
    this._controller,
  }); // ignore: prefer_initializing_formals

  final String id;
  String url;
  String title;
  WebViewController? _controller;
  bool configured = false;
  bool canGoBack = false;
  bool canGoForward = false;

  /// Created lazily — Android WebView init is expensive and must not run off-screen.
  WebViewController get controller => _controller ??= WebViewController();

  /// True while the tab is showing the private start page (no web content).
  bool get isStart => url == kStartPage || url.isEmpty;
}

/// Multi-tab in-app browser over the tunnel. Tabs start on the private start
/// page and load real pages through [webview_flutter] on navigation.
class BrowserController extends GetxController {
  final tabs = <BrowserTab>[].obs;
  final activeIndex = 0.obs;
  final addressBar = kStartPage.obs;
  final isLoading = false.obs;

  BrowserTab get activeTab {
    if (tabs.isEmpty) throw StateError('BrowserController has no tabs');
    return tabs[activeIndex.value.clamp(0, tabs.length - 1)];
  }

  /// True while the shell's BROWSER bottom-nav tab is selected.
  final shellTabVisible = false.obs;

  /// Set by [BrowserView] to present the native link long-press menu.
  void Function(BrowserLinkHit hit)? linkContextMenuHandler;

  Timer? _tunnelReloadDebounce;

  /// Last page-initiated new-tab request, used to drop duplicate posts (a
  /// page can fire both a `_blank` click and `window.open` for one gesture).
  String? _lastPageNewTabUrl;
  DateTime _lastPageNewTabAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void onInit() {
    super.onInit();
    if (tabs.isEmpty) addTab();
    if (Get.isRegistered<VpnController>()) {
      final vpn = Get.find<VpnController>();
      ever(vpn.stage, (_) => _debouncedReloadForTunnelChange());
    }
  }

  @override
  void onClose() {
    _tunnelReloadDebounce?.cancel();
    super.onClose();
  }

  void _debouncedReloadForTunnelChange() {
    _tunnelReloadDebounce?.cancel();
    _tunnelReloadDebounce = Timer(const Duration(milliseconds: 500), reload);
  }

  void addTab({String? url, bool activate = true}) {
    final u = url == null ? kStartPage : normalizeInput(url);
    final tab = BrowserTab(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: u,
      title: kStartTitle,
    );
    tabs.add(tab);
    if (activate) {
      activeIndex.value = tabs.length - 1;
      addressBar.value = u;
    }
    tabs.refresh();
    if (!tab.isStart && shellTabVisible.value && activate) {
      unawaited(_loadActiveTabIfNeeded());
    }
  }

  void closeTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    if (tabs.length <= 1) {
      // Always keep ≥1 tab — closing the last spawns a fresh start page.
      final fresh = BrowserTab(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        url: kStartPage,
        title: kStartTitle,
      );
      tabs[0] = fresh;
      activeIndex.value = 0;
      addressBar.value = kStartPage;
      tabs.refresh();
      return;
    }
    tabs.removeAt(index);
    if (activeIndex.value >= tabs.length) {
      activeIndex.value = tabs.length - 1;
    }
    addressBar.value = activeTab.url;
  }

  void selectTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    activeIndex.value = index;
    addressBar.value = activeTab.url;
    tabs.refresh();
    if (shellTabVisible.value) unawaited(_loadActiveTabIfNeeded());
  }

  Future<void> goHome() async {
    final tab = activeTab;
    tab.url = kStartPage;
    tab.title = kStartTitle;
    addressBar.value = kStartPage;
    tab.canGoBack = false;
    tab.canGoForward = false;
    tabs.refresh();
  }

  /// Called when the shell switches to the BROWSER tab. WebView is mounted only
  /// while visible — loads are kicked off here, not while the tab is hidden in
  /// [IndexedStack].
  void setShellTabVisible(bool visible) {
    if (shellTabVisible.value == visible) return;
    shellTabVisible.value = visible;
    if (visible) _loadActiveTabIfNeeded();
  }

  static String braveSearchUrl(String query) {
    return '$kBraveSearch${Uri.encodeComponent(query.trim())}';
  }

  /// Start-page search routes through Brave Search in the active tab.
  Future<void> searchPrivateWeb(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    await navigate(braveSearchUrl(trimmed));
  }

  /// Opens a Brave Search results page in a new browser tab.
  void searchPrivateWebInNewTab(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    addTab(url: braveSearchUrl(trimmed));
  }

  /// Opens [input] in a new browser tab (URL or Brave query).
  void openInNewTab(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    addTab(url: normalizeInput(trimmed));
  }

  /// Opens a link in the active tab.
  Future<void> openLink(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    await navigate(trimmed);
  }

  /// Opens a new tab requested by page content (`target="_blank"`,
  /// `window.open`). Only real http(s) URLs qualify — `about:blank`,
  /// `javascript:` and `data:` pop-ups are dropped rather than spawning
  /// empty tabs.
  void _openPageRequestedTab(String url) {
    final trimmed = url.trim();
    if (!isWebUrl(trimmed)) return;
    final now = DateTime.now();
    if (trimmed == _lastPageNewTabUrl &&
        now.difference(_lastPageNewTabAt) < const Duration(seconds: 1)) {
      return;
    }
    _lastPageNewTabUrl = trimmed;
    _lastPageNewTabAt = now;
    addTab(url: trimmed);
  }

  /// Opens a link in a new tab without switching away from the current tab.
  void openInBackgroundTab(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    addTab(url: normalizeInput(trimmed), activate: false);
  }

  Future<void> navigate(String input) async {
    final url = normalizeInput(input);
    final tab = activeTab;
    tab.url = url;
    addressBar.value = url;
    if (url != kStartPage && shellTabVisible.value) _ensureConfigured(tab);
    tabs.refresh();
    if (url == kStartPage) return;
    if (shellTabVisible.value) await tab.controller.loadRequest(Uri.parse(url));
  }

  Future<void> _loadActiveTabIfNeeded() async {
    final tab = activeTab;
    if (tab.isStart) return;
    _ensureConfigured(tab);
    tabs.refresh();
    await tab.controller.loadRequest(Uri.parse(tab.url));
  }

  void _ensureConfigured(BrowserTab tab) {
    if (tab.configured) return;
    _configure(tab);
    tab.configured = true;
  }

  Future<void> reload() async {
    final tab = activeTab;
    if (tab.isStart || !tab.configured) return;
    await tab.controller.reload();
  }

  Future<void> goBack() async {
    final tab = activeTab;
    if (tab.isStart || !tab.configured || !tab.canGoBack) return;
    await tab.controller.goBack();
    await _refreshNavigationState(tab);
  }

  Future<void> goForward() async {
    final tab = activeTab;
    if (tab.isStart || !tab.configured || !tab.canGoForward) return;
    await tab.controller.goForward();
    await _refreshNavigationState(tab);
  }

  Future<void> _refreshNavigationState(BrowserTab tab) async {
    if (!tab.configured || tab.isStart) {
      tab.canGoBack = false;
      tab.canGoForward = false;
    } else {
      tab.canGoBack = await tab.controller.canGoBack();
      tab.canGoForward = await tab.controller.canGoForward();
    }
    tabs.refresh();
  }

  void _configure(BrowserTab tab) {
    tab.controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        kLinkContextMenuChannel,
        onMessageReceived: (message) {
          final hit = parseBrowserLinkHit(message.message);
          if (hit == null) return;
          linkContextMenuHandler?.call(hit);
        },
      )
      ..addJavaScriptChannel(
        kNewTabChannel,
        onMessageReceived: (message) => _openPageRequestedTab(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => isLoading.value = true,
          onPageFinished: (url) async {
            isLoading.value = false;
            tab.url = url;
            if (tabs.isNotEmpty &&
                tabs[activeIndex.value.clamp(0, tabs.length - 1)] == tab) {
              addressBar.value = url;
            }
            await _refreshNavigationState(tab);
            await _injectLinkContextMenu(tab);
            final title = await tab.controller.getTitle();
            if (title != null && title.isNotEmpty) {
              tab.title = title.length > 24
                  ? '${title.substring(0, 24)}…'
                  : title;
              tabs.refresh();
            }
          },
          onWebResourceError: (error) {
            debugPrint(
              '[Browser] resource error: ${error.description} (${error.errorCode})',
            );
          },
          // Sub-frame navigations (iframes, embeds, about:blank shells) must
          // load in place. New-tab links are routed by the injected script
          // via [kNewTabChannel]; any remaining `_blank` target falls back
          // to loading in this tab.
          onNavigationRequest: (_) => NavigationDecision.navigate,
        ),
      );
  }

  Future<void> _injectLinkContextMenu(BrowserTab tab) async {
    try {
      await tab.controller.runJavaScript(kLinkContextMenuJs);
    } catch (e) {
      debugPrint('[Browser] link menu inject failed: $e');
    }
  }

  /// Resolves browser input to a direct web URL or a Brave Search query.
  ///
  /// Bare domains, IP addresses and localhost navigate directly. Everything
  /// else, including a single word, is treated as a search query.
  static String normalizeInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty || trimmed == kStartPage) return kStartPage;

    final explicitUri = Uri.tryParse(trimmed);
    if (explicitUri != null &&
        (explicitUri.scheme == 'http' || explicitUri.scheme == 'https') &&
        explicitUri.host.isNotEmpty) {
      return trimmed;
    }

    if (!trimmed.contains(RegExp(r'\s'))) {
      final candidate = Uri.tryParse('https://$trimmed');
      if (candidate != null &&
          candidate.host.isNotEmpty &&
          candidate.userInfo.isEmpty &&
          _looksLikeWebHost(candidate.host)) {
        return candidate.toString();
      }
    }

    return braveSearchUrl(trimmed);
  }

  static bool isWebUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static bool _looksLikeWebHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized.contains('.') ||
        normalized.contains(':');
  }
}
