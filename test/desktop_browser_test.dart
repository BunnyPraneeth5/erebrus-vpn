import 'dart:async';

import 'package:erebrus_vpn/platform/desktop_browser.dart';
import 'package:erebrus_vpn/platform/platform_capabilities.dart';
import 'package:erebrus_vpn/view/browser/browser_controller.dart';
import 'package:erebrus_vpn/view/browser/browser_view.dart';
import 'package:erebrus_vpn/vpn/vpn_controller.dart';
import 'package:erebrus_vpn/vpn/singbox_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

class _BrowserEngine implements SingboxEngine {
  @override
  Stream<VpnStage> get onStage => const Stream.empty();

  @override
  Stream<VpnStats> get onStats => const Stream.empty();

  @override
  Future<bool> verifyConnection() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vpn extends VpnController {
  _Vpn() : super(engine: _BrowserEngine(), egressProbe: () async => null);
}

class _Platform extends WebViewPlatform {
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => WindowsPlatformNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(key: ValueKey('fake-native-browser'));
}

class _WebView extends PlatformWebViewController {
  _WebView(this.events)
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final List<String> events;
  final urls = <String>[];
  WindowsPlatformNavigationDelegate? delegate;
  bool disposed = false;
  Completer<void>? configuration;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {
    events.add('javascript');
    await configuration?.future;
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    events.add('channel');
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate value,
  ) async {
    delegate = value as WindowsPlatformNavigationDelegate;
    events.add('delegate');
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    expect(disposed, isFalse);
    urls.add(params.uri.toString());
    events.add('load');
  }

  @override
  Future<String?> getTitle() async {
    events.add('title');
    return 'Example';
  }

  @override
  Future<bool> canGoBack() async => true;

  @override
  Future<bool> canGoForward() async => true;

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> reload() async => events.add('reload');

  @override
  Future<void> goBack() async => events.add('back');

  @override
  Future<void> goForward() async => events.add('forward');
}

Future<void> _flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final desktop = PlatformCapabilities.usesDesktopVpnRunner;
  late _Vpn vpn;
  late BrowserController browser;
  late List<String> events;
  late List<_WebView> views;
  WebViewPlatform? previousPlatform;

  BrowserController makeBrowser({
    Future<void> Function()? prepare,
    Future<void> Function(WebViewController)? secure,
    Future<WebViewController> Function()? factory,
  }) {
    final controller = BrowserController(
      prepareDesktop:
          prepare ??
          () async {
            events.add('prepare');
          },
      secureDesktop:
          secure ??
          (controller) async {
            await controller.getTitle();
            events.add('secure');
          },
      controllerFactory:
          factory ??
          () async {
            events.add('create');
            final view = _WebView(events);
            views.add(view);
            return WebViewController.fromPlatform(view);
          },
      disposeDesktop: (controller) async {
        final view = controller.platform as _WebView;
        view.disposed = true;
        events.add('dispose');
      },
      desktopVisibility: (_, visible) async {
        events.add('visible:$visible');
      },
    );
    Get.put(controller);
    controller.setShellTabVisible(true);
    return controller;
  }

  setUp(() {
    Get.testMode = true;
    previousPlatform = WebViewPlatform.instance;
    WebViewPlatform.instance = _Platform();
    vpn = _Vpn();
    Get.put<VpnController>(vpn);
    events = [];
    views = [];
  });

  tearDown(() async {
    Get.reset();
    if (previousPlatform != null) WebViewPlatform.instance = previousPlatform;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DesktopBrowser.channel, null);
  });

  test(
    'only verified VPN protection permits native preparation and navigation',
    () async {
      browser = makeBrowser();
      await browser.navigate('https://example.com');
      expect(views, isEmpty);
      expect(browser.activeTab.url, 'https://example.com');
      vpn.killSwitchEngaging.value = true;
      vpn.stage.value = VpnStage.connected;
      await _flush();
      expect(views, isEmpty);
      vpn.killSwitchEngaging.value = false;
      await _flush();
      expect(browser.protectionAvailable.value, isTrue);
      expect(events, [
        'prepare',
        'create',
        'title',
        'secure',
        'javascript',
        'channel',
        'delegate',
        'load',
      ]);
      expect(views.single.urls, ['https://example.com']);
      final delegate = views.single.delegate!;
      expect(
        await delegate.onNavigationRequest!(
          const NavigationRequest(
            url: 'https://example.com/frame',
            isMainFrame: false,
          ),
        ),
        NavigationDecision.navigate,
      );
      expect(browser.tabs.length, 1);
      for (final url in [
        'file:///secret',
        'javascript:alert(1)',
        'mailto:test@example.com',
        'data:text/html,test',
      ]) {
        expect(
          await delegate.onNavigationRequest!(
            NavigationRequest(url: url, isMainFrame: true),
          ),
          NavigationDecision.prevent,
        );
      }
      expect(
        await delegate.onNavigationRequest!(
          const NavigationRequest(url: 'about:blank', isMainFrame: true),
        ),
        NavigationDecision.navigate,
      );
      delegate.onPageFinished!('https://example.com');
      await _flush();
      expect(browser.activeTab.title, 'Example');
      await browser.goBack();
      await browser.goForward();
      await browser.reload();
      expect(events, containsAll(['back', 'forward', 'reload']));
    },
    skip: !desktop,
  );

  for (final reason in ['health', 'engaging', 'blocking', 'disconnected']) {
    test(
      '$reason immediately unmounts and disposes while preserving URL',
      () async {
        vpn.stage.value = VpnStage.connected;
        browser = makeBrowser();
        await browser.navigate('https://example.com');
        final old = views.single;
        switch (reason) {
          case 'health':
            vpn.tunnelHealthy.value = false;
          case 'engaging':
            vpn.killSwitchEngaging.value = true;
          case 'blocking':
            vpn.killSwitchBlocking.value = true;
          case 'disconnected':
            vpn.stage.value = VpnStage.disconnected;
        }
        expect(browser.protectionAvailable.value, isFalse);
        expect(browser.canMountBrowser, isFalse);
        expect(browser.activeTab.configured, isFalse);
        expect(browser.activeTab.url, 'https://example.com');
        await _flush();
        expect(old.disposed, isTrue);
        final count = events.where((e) => e == 'load').length;
        await browser.reload();
        await browser.goBack();
        await browser.goForward();
        expect(events.where((e) => e == 'load').length, count);
        vpn.tunnelHealthy.value = true;
        vpn.killSwitchEngaging.value = false;
        vpn.killSwitchBlocking.value = false;
        vpn.stage.value = VpnStage.connected;
        await _flush();
        expect(views.last, isNot(same(old)));
        expect(views.last.urls, ['https://example.com']);
      },
      skip: !desktop,
    );
  }

  for (final failure in ['configure', 'secureViews', 'exception']) {
    test(
      'native $failure failure never loads directly and can retry',
      () async {
        vpn.stage.value = VpnStage.connected;
        var fail = true;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(DesktopBrowser.channel, (
          call,
        ) async {
          events.add('native:${call.method}');
          if (fail && failure == 'exception') {
            throw PlatformException(code: 'unavailable');
          }
          return !(fail && call.method == failure);
        });
        browser = makeBrowser(
          prepare: DesktopBrowser.prepare,
          secure: DesktopBrowser.secure,
        );
        await browser.navigate('https://example.com');
        await _flush();
        expect(browser.browserError.value, isNotNull);
        expect(events, isNot(contains('load')));
        expect(views.every((view) => view.disposed), isTrue);
        fail = false;
        await browser.reload();
        expect(browser.browserError.value, isNull);
        expect(events, contains('load'));
      },
      skip: !desktop,
    );
  }

  test('closing during controller creation disposes the late result', () async {
    vpn.stage.value = VpnStage.connected;
    final created = Completer<WebViewController>();
    browser = makeBrowser(factory: () => created.future);
    final loading = browser.navigate('https://example.com');
    await _flush();
    browser.closeTab(0);
    final lateView = _WebView(events);
    created.complete(WebViewController.fromPlatform(lateView));
    await loading;
    expect(lateView.disposed, isTrue);
    expect(lateView.urls, isEmpty);
    expect(browser.activeTab.isStart, isTrue);
  }, skip: !desktop);

  for (final action in [
    'close',
    'select',
    'home',
    'disconnect',
    'cover',
    'hidden',
    'replace',
    'shutdown',
  ]) {
    test('$action fences pending native readiness', () async {
      vpn.stage.value = VpnStage.connected;
      final ready = Completer<void>();
      browser = makeBrowser(secure: (_) => ready.future);
      final loading = browser.navigate('https://example.com');
      await _flush();
      final view = views.single;
      switch (action) {
        case 'close':
          browser.closeTab(0);
        case 'select':
          browser.addTab();
        case 'home':
          await browser.goHome();
        case 'disconnect':
          vpn.tunnelHealthy.value = false;
        case 'cover':
          browser.setRouteCovered(true);
        case 'hidden':
          browser.setShellTabVisible(false);
        case 'replace':
          unawaited(browser.navigate('https://replacement.example'));
        case 'shutdown':
          browser.onClose();
      }
      ready.complete();
      await loading;
      await _flush();
      expect(view.disposed, isTrue);
      expect(view.urls, isEmpty);
    }, skip: !desktop);
  }

  test(
    'closing during awaited configuration prevents subsequent operations',
    () async {
      vpn.stage.value = VpnStage.connected;
      final configuration = Completer<void>();
      final view = _WebView(events)..configuration = configuration;
      browser = makeBrowser(
        factory: () async => WebViewController.fromPlatform(view),
      );
      final loading = browser.navigate('https://example.com');
      await _flush();
      expect(events, contains('javascript'));
      browser.closeTab(0);
      configuration.complete();
      await loading;
      expect(view.disposed, isTrue);
      expect(events, isNot(contains('channel')));
      expect(events, isNot(contains('load')));
    },
    skip: !desktop,
  );

  test(
    'closing inactive tabs preserves selection and shutdown disposes all views',
    () async {
      vpn.stage.value = VpnStage.connected;
      browser = makeBrowser();
      await browser.navigate('https://first.example');
      browser.addTab(url: 'https://second.example');
      await _flush();
      final selected = browser.activeTab;
      browser.closeTab(0);
      await _flush();
      expect(browser.activeTab, same(selected));
      expect(views.first.disposed, isTrue);
      browser.onClose();
      await _flush();
      expect(views.every((view) => view.disposed), isTrue);
      final count = views.length;
      vpn.stage.value = VpnStage.disconnected;
      vpn.stage.value = VpnStage.connected;
      await _flush();
      expect(views.length, count);
    },
    skip: !desktop,
  );

  testWidgets(
    'readiness failure displays retry instead of mounting a browser',
    (tester) async {
      vpn.stage.value = VpnStage.connected;
      var ready = false;
      browser = makeBrowser(
        prepare: () async {
          if (!ready) throw StateError('Secure proxy unavailable');
        },
      );
      await browser.navigate('https://example.com');
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [browserRouteObserver],
          home: const BrowserView(),
        ),
      );
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byKey(const ValueKey('fake-native-browser')), findsNothing);
      ready = true;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-native-browser')), findsOneWidget);
      expect(tester.takeException(), isNull);
      browser.onClose();
      vpn.onClose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !desktop,
  );

  testWidgets('reparented native browser restores its visibility', (
    tester,
  ) async {
    vpn.stage.value = VpnStage.connected;
    browser = makeBrowser();
    await browser.navigate('https://example.com');
    final key = GlobalKey();
    var left = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [browserRouteObserver],
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Row(
              children: [
                Expanded(
                  child: left ? BrowserView(key: key) : const SizedBox(),
                ),
                Expanded(
                  child: left ? const SizedBox() : BrowserView(key: key),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    final shown = events.where((event) => event == 'visible:true').length;
    expect(shown, greaterThan(0));
    update(() => left = false);
    await tester.pump();
    await tester.pump();
    expect(
      events.where((event) => event == 'visible:true').length,
      greaterThan(shown),
    );
    expect(views.length, 1);
    expect(tester.takeException(), isNull);
    browser.onClose();
    vpn.onClose();
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !desktop);

  testWidgets(
    'modal routes hide native overlay and protection loss unmounts it',
    (tester) async {
      vpn.stage.value = VpnStage.connected;
      browser = makeBrowser();
      await browser.navigate('https://example.com');
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [browserRouteObserver],
          home: const BrowserView(),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-native-browser')), findsOneWidget);
      expect(events, contains('visible:true'));
      final dialog = showDialog<void>(
        context: tester.element(find.byType(BrowserView)),
        builder: (_) => const AlertDialog(title: Text('Covering browser')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(browser.routeCovered.value, isTrue);
      expect(find.byKey(const ValueKey('fake-native-browser')), findsNothing);
      expect(events, contains('visible:false'));
      navigator.currentState!.pop();
      await dialog;
      await tester.pump();
      expect(browser.routeCovered.value, isTrue);
      expect(find.byKey(const ValueKey('fake-native-browser')), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(browser.routeCovered.value, isFalse);
      expect(find.byKey(const ValueKey('fake-native-browser')), findsOneWidget);
      vpn.tunnelHealthy.value = false;
      await tester.pump();
      expect(find.byKey(const ValueKey('fake-native-browser')), findsNothing);
      expect(find.text('Connect VPN to browse securely'), findsOneWidget);
      browser.onClose();
      vpn.onClose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !desktop,
  );
}
