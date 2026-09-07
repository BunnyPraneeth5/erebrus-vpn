import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../platform/desktop_browser.dart';
import '../../platform/platform_capabilities.dart';
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
  int generation = 0;
  Future<void>? pendingLoad;
  bool canGoBack = false;
  bool canGoForward = false;

  /// Created lazily — Android WebView init is expensive and must not run off-screen.
  WebViewController get controller =>
      _controller ?? (throw StateError('Browser is not ready'));

  /// True while the tab is showing the private start page (no web content).
  bool get isStart => url == kStartPage || url.isEmpty;
}

/// Multi-tab in-app browser over the tunnel. Tabs start on the private start
/// page and load real pages through [webview_flutter] on navigation.
class BrowserController extends GetxController {
  BrowserController({
    Future<WebViewController> Function()? controllerFactory,
    Future<void> Function()? prepareDesktop,
    Future<void> Function(WebViewController)? secureDesktop,
    Future<void> Function(WebViewController)? disposeDesktop,
    Future<void> Function(WebViewController, bool)? desktopVisibility,
  }) : _controllerFactory =
           controllerFactory ??
           (PlatformCapabilities.usesDesktopVpnRunner
               ? DesktopBrowser.createController
               : () async => WebViewController()),
       _prepareDesktop = prepareDesktop ?? DesktopBrowser.prepare,
       _secureDesktop = secureDesktop ?? DesktopBrowser.secure,
       _disposeDesktop = disposeDesktop ?? DesktopBrowser.disposeController,
       _desktopVisibility = desktopVisibility ?? DesktopBrowser.setVisibility;

  final Future<WebViewController> Function() _controllerFactory;
  final Future<void> Function() _prepareDesktop;
  final Future<void> Function(WebViewController) _secureDesktop;
  final Future<void> Function(WebViewController) _disposeDesktop;
  final Future<void> Function(WebViewController, bool) _desktopVisibility;
  final protectionAvailable = false.obs;
  final routeCovered = false.obs;
  final browserError = RxnString();
  final List<Worker> _workers = [];
  bool _closed = false;
  bool _disposalFailed = false;
  int _nextTabId = 0;

  bool get _desktop => PlatformCapabilities.usesDesktopVpnRunner;
  bool get _protected =>
      Get.isRegistered<VpnController>() &&
      Get.find<VpnController>().isProtected;
  bool get _canBrowse =>
      !_closed && !_disposalFailed && (!_desktop || _protected);
  bool get canMountBrowser =>
      !_closed &&
      !_disposalFailed &&
      shellTabVisible.value &&
      !routeCovered.value &&
      (!_desktop || protectionAvailable.value);

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

  @override
  void onInit() {
    super.onInit();
    if (tabs.isEmpty) addTab();
    protectionAvailable.value = !_desktop || _protected;
    if (Get.isRegistered<VpnController>()) {
      final vpn = Get.find<VpnController>();
      if (_desktop) {
        _workers.add(
          everAll([
            vpn.stage,
            vpn.tunnelHealthy,
            vpn.killSwitchBlocking,
            vpn.killSwitchEngaging,
          ], (_) => _protectionChanged()),
        );
      } else {
        _workers.add(ever(vpn.stage, (_) => _debouncedReloadForTunnelChange()));
      }
    }
  }

  @override
  void onClose() {
    _closed = true;
    _tunnelReloadDebounce?.cancel();
    for (final worker in _workers) {
      worker.dispose();
    }
    for (final tab in tabs) {
      _release(tab);
    }
    super.onClose();
  }

  void _protectionChanged() {
    final available = _protected;
    final wasAvailable = protectionAvailable.value;
    protectionAvailable.value = available;
    if (!available) {
      isLoading.value = false;
      for (final tab in tabs) {
        _release(tab);
      }
      tabs.refresh();
    } else if (!wasAvailable && canMountBrowser) {
      unawaited(_loadActiveTabIfNeeded());
    }
  }

  Future<void> _dispose(WebViewController controller) async {
    if (!_desktop) return;
    await runZonedGuarded<Future<void>>(() async {
      try {
        await _disposeDesktop(controller);
      } catch (error) {
        _disposalError(error);
      }
    }, (error, _) => _disposalError(error));
  }

  void _disposalError(Object error) {
    debugPrint('[Browser] disposal failed: $error');
    if (_closed) return;
    _disposalFailed = true;
    browserError.value =
        'Could not close the secure browser. Restart the app before browsing again.';
    for (final tab in tabs) {
      _release(tab);
    }
    tabs.refresh();
  }

  void _clearError() {
    if (!_disposalFailed) browserError.value = null;
  }

  void _release(BrowserTab tab) {
    tab.generation++;
    tab.pendingLoad = null;
    tab.configured = false;
    tab.canGoBack = false;
    tab.canGoForward = false;
    final controller = tab._controller;
    tab._controller = null;
    if (controller != null) unawaited(_dispose(controller));
  }

  Future<void> _hide(BrowserTab tab) async {
    if (!_desktop) return;
    if (!tab.configured) {
      _release(tab);
      return;
    }
    final controller = tab._controller;
    if (controller == null) return;
    try {
      await _desktopVisibility(controller, false);
    } catch (error) {
      _release(tab);
      if (!_closed) {
        browserError.value = 'Could not hide the secure browser. Please retry.';
      }
    }
  }

  Future<void> showNativeTab(BrowserTab tab) async {
    final generation = tab.generation;
    if (!_desktop || !tab.configured || !_valid(tab, generation)) return;
    final controller = tab.controller;
    try {
      await _desktopVisibility(controller, true);
      if (!_valid(tab, generation)) await _desktopVisibility(controller, false);
    } catch (error) {
      if (_valid(tab, generation)) {
        browserError.value =
            'The secure browser could not be displayed. Please retry.';
        _release(tab);
        tabs.refresh();
      }
    }
  }

  void setRouteCovered(bool covered) {
    if (_closed || routeCovered.value == covered) return;
    routeCovered.value = covered;
    if (covered) {
      for (final tab in tabs) {
        unawaited(_hide(tab));
      }
    } else if (shellTabVisible.value) {
      unawaited(_loadActiveTabIfNeeded());
    }
  }

  void _debouncedReloadForTunnelChange() {
    _tunnelReloadDebounce?.cancel();
    _tunnelReloadDebounce = Timer(const Duration(milliseconds: 500), reload);
  }

  void addTab({String? url, bool activate = true}) {
    final u = url == null || !PlatformCapabilities.supportsEmbeddedBrowser
        ? kStartPage
        : normalizeInput(url);
    final tab = BrowserTab(id: '${++_nextTabId}', url: u, title: kStartTitle);
    if (activate && tabs.isNotEmpty) unawaited(_hide(activeTab));
    tabs.add(tab);
    if (activate) {
      _clearError();
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
    final selected = activeTab;
    _release(tabs[index]);
    _clearError();
    if (tabs.length <= 1) {
      // Always keep ≥1 tab — closing the last spawns a fresh start page.
      final fresh = BrowserTab(
        id: '${++_nextTabId}',
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
    activeIndex.value = tabs.contains(selected)
        ? tabs.indexOf(selected)
        : index.clamp(0, tabs.length - 1);
    addressBar.value = activeTab.url;
    tabs.refresh();
    if (canMountBrowser) unawaited(_loadActiveTabIfNeeded());
  }

  void selectTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    if (index != activeIndex.value) unawaited(_hide(activeTab));
    _clearError();
    activeIndex.value = index;
    addressBar.value = activeTab.url;
    tabs.refresh();
    if (shellTabVisible.value) unawaited(_loadActiveTabIfNeeded());
  }

  Future<void> goHome() async {
    final tab = activeTab;
    _release(tab);
    _clearError();
    isLoading.value = false;
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
    if (visible) {
      unawaited(_loadActiveTabIfNeeded());
    } else {
      for (final tab in tabs) {
        unawaited(_hide(tab));
      }
    }
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

  /// Opens a link in a new tab without switching away from the current tab.
  void openInBackgroundTab(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    addTab(url: normalizeInput(trimmed), activate: false);
  }

  Future<void> navigate(String input) async {
    if (!PlatformCapabilities.supportsEmbeddedBrowser) return;
    final url = normalizeInput(input);
    if (url == kStartPage) return goHome();
    final tab = activeTab;
    if (tab.pendingLoad != null) _release(tab);
    tab.url = url;
    addressBar.value = url;
    _clearError();
    tabs.refresh();
    await _loadActiveTabIfNeeded(force: true);
  }

  bool _valid(BrowserTab tab, int generation) =>
      _canBrowse &&
      tabs.contains(tab) &&
      tab.generation == generation &&
      tabs.isNotEmpty &&
      activeTab == tab &&
      canMountBrowser &&
      !tab.isStart;

  Future<void> _loadActiveTabIfNeeded({bool force = false}) async {
    if (!PlatformCapabilities.supportsEmbeddedBrowser ||
        tabs.isEmpty ||
        !_canBrowse ||
        !canMountBrowser) {
      return;
    }
    final tab = activeTab;
    if (tab.isStart) return;
    final pending = tab.pendingLoad;
    if (pending != null) {
      await pending;
      return;
    }
    if (tab.configured && !force) return;
    final generation = tab.generation;
    final future = _load(tab, generation);
    tab.pendingLoad = future;
    await future;
    if (tab.generation == generation) tab.pendingLoad = null;
  }

  Future<void> _load(BrowserTab tab, int generation) async {
    try {
      if (!tab.configured) {
        if (_desktop) await _prepareDesktop();
        if (!_valid(tab, generation)) return;
        final controller = await _controllerFactory();
        if (!_valid(tab, generation)) {
          await _dispose(controller);
          return;
        }
        tab._controller = controller;
        if (_desktop) await _secureDesktop(controller);
        if (!_valid(tab, generation)) return;
        await _configure(tab, controller, generation);
        if (!_valid(tab, generation)) return;
        tab.configured = true;
      }
      if (!_valid(tab, generation)) return;
      isLoading.value = true;
      tabs.refresh();
      await tab.controller.loadRequest(Uri.parse(tab.url));
    } catch (error) {
      if (_valid(tab, generation)) {
        browserError.value =
            'Secure browser unavailable. Check the VPN connection and browser runtime, then retry.';
        isLoading.value = false;
        _release(tab);
        tabs.refresh();
      }
      debugPrint('[Browser] initialization or navigation failed: $error');
    }
  }

  Future<void> reload() async {
    if (tabs.isEmpty || !_canBrowse || !canMountBrowser) return;
    final tab = activeTab;
    if (tab.isStart) return;
    _clearError();
    if (!tab.configured) return _loadActiveTabIfNeeded();
    await _runActive((controller) => controller.reload());
  }

  Future<void> goBack() async {
    if (tabs.isEmpty || !activeTab.canGoBack) return;
    await _runActive((controller) => controller.goBack());
  }

  Future<void> goForward() async {
    if (tabs.isEmpty || !activeTab.canGoForward) return;
    await _runActive((controller) => controller.goForward());
  }

  Future<void> _runActive(
    Future<void> Function(WebViewController) action,
  ) async {
    if (tabs.isEmpty) return;
    final tab = activeTab;
    final generation = tab.generation;
    if (!tab.configured || !_valid(tab, generation)) return;
    final controller = tab.controller;
    try {
      await action(controller);
      if (_valid(tab, generation)) {
        await _refreshNavigationState(tab, controller, generation);
      }
    } catch (error) {
      if (_valid(tab, generation)) {
        browserError.value =
            'The secure browser could not navigate. Please retry.';
        _release(tab);
        tabs.refresh();
      }
    }
  }

  Future<void> _refreshNavigationState(
    BrowserTab tab,
    WebViewController controller,
    int generation,
  ) async {
    final back = await controller.canGoBack();
    if (!_valid(tab, generation)) return;
    final forward = await controller.canGoForward();
    if (!_valid(tab, generation)) return;
    tab.canGoBack = back;
    tab.canGoForward = forward;
    tabs.refresh();
  }

  Future<void> _configure(
    BrowserTab tab,
    WebViewController controller,
    int generation,
  ) async {
    await DesktopBrowser.configureController(
      controller,
      NavigationDelegate(
        onPageStarted: (url) {
          if (!_valid(tab, generation)) return;
          isLoading.value = true;
          if (isWebUrl(url)) {
            tab.url = url;
            addressBar.value = url;
          }
        },
        onPageFinished: (url) async {
          if (!_valid(tab, generation) || !isWebUrl(url)) return;
          try {
            isLoading.value = false;
            tab.url = url;
            addressBar.value = url;
            await _refreshNavigationState(tab, controller, generation);
            if (!_valid(tab, generation)) return;
            await _injectLinkContextMenu(controller);
            if (!_valid(tab, generation)) return;
            final title = await controller.getTitle();
            if (!_valid(tab, generation)) return;
            if (title != null && title.isNotEmpty) {
              tab.title = title.length > 24
                  ? '${title.substring(0, 24)}…'
                  : title;
              tabs.refresh();
            }
          } catch (error) {
            debugPrint('[Browser] page metadata failed: $error');
          }
        },
        onWebResourceError: (error) {
          if (!_valid(tab, generation)) return;
          debugPrint(
            '[Browser] resource error: ${error.description} (${error.errorCode})',
          );
          if (error.isForMainFrame != false) {
            isLoading.value = false;
            browserError.value =
                'This page could not be loaded through the secure connection. Please retry.';
            _release(tab);
            tabs.refresh();
          }
        },
        onNavigationRequest: (req) {
          if (!_valid(tab, generation)) return NavigationDecision.prevent;
          if (req.url == 'about:blank') return NavigationDecision.navigate;
          if (!isWebUrl(req.url)) return NavigationDecision.prevent;
          if (!req.isMainFrame && !_desktop) {
            openInNewTab(req.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ),
      kLinkContextMenuChannel,
      (message) {
        if (!_valid(tab, generation)) return;
        final hit = parseBrowserLinkHit(message.message);
        if (hit == null || !isWebUrl(hit.url)) return;
        linkContextMenuHandler?.call(hit);
      },
      () => _valid(tab, generation),
    );
  }

  Future<void> _injectLinkContextMenu(WebViewController controller) async {
    try {
      await controller.runJavaScript(kLinkContextMenuJs);
    } catch (e) {
      debugPrint('[Browser] link menu inject failed: $e');
    }
  }

  static bool isWebUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
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

  static bool _looksLikeWebHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized.contains('.') ||
        normalized.contains(':');
  }
}
