import 'dart:io';

import 'package:erebrus_vpn/view/browser/browser_controller.dart';
import 'package:erebrus_vpn/view/browser/browser_link_menu.dart';
import 'package:erebrus_vpn/view/browser/browser_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  final secureDesktop = Platform.isWindows || Platform.isLinux;

  test(
    'desktop URLs are retained but never loaded without protection',
    () async {
      final controller = BrowserController();
      controller.addTab();
      controller.setShellTabVisible(true);

      await controller.navigate('https://example.com');
      controller.addTab(url: 'https://example.com');
      controller.selectTab(0);
      await controller.searchPrivateWeb('privacy');
      controller.openInNewTab('https://example.com');
      controller.openInBackgroundTab('https://example.com');
      await controller.reload();
      await controller.goBack();
      await controller.goForward();

      expect(controller.tabs.every((tab) => !tab.isStart), isTrue);
      expect(controller.protectionAvailable.value, isFalse);
      expect(controller.tabs.every((tab) => !tab.configured), isTrue);
      controller.onClose();
    },
    skip: !secureDesktop,
  );

  testWidgets('desktop starts locally and asks for VPN before browsing', (
    tester,
  ) async {
    Get.testMode = true;
    addTearDown(Get.reset);
    final controller = Get.put(BrowserController());
    await tester.pumpWidget(const MaterialApp(home: BrowserView()));

    expect(find.text('Sovereign web.'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    controller.setShellTabVisible(true);
    await controller.navigate('https://example.com');
    await tester.pump();
    expect(find.text('Connect VPN to browse securely'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !secureDesktop);

  for (final throwsError in [false, true]) {
    testWidgets('external browser failure is shown (throws=$throwsError)', (
      tester,
    ) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async {
        if (throwsError) throw PlatformException(code: 'launch-failed');
        return false;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final controller = BrowserController();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showBrowserLinkContextMenu(
                  context,
                  controller,
                  const BrowserLinkHit(url: 'https://example.com', label: ''),
                ),
                child: const Text('Show link menu'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show link menu'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open in external browser'));
      await tester.tap(find.text('Open in external browser'));
      await tester.pumpAndSettle();

      expect(find.text('Could not open the external browser'), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.onClose();
    });
  }

  group('BrowserController.normalizeInput', () {
    test('searches Brave for single-word and natural-language queries', () {
      expect(
        BrowserController.normalizeInput('privacy'),
        '${kBraveSearch}privacy',
      );
      expect(
        BrowserController.normalizeInput('private search engine'),
        '${kBraveSearch}private%20search%20engine',
      );
    });

    test('navigates directly to domains, IPs and localhost', () {
      expect(
        BrowserController.normalizeInput('erebrus.io'),
        'https://erebrus.io',
      );
      expect(
        BrowserController.normalizeInput('192.168.1.1:8080/status'),
        'https://192.168.1.1:8080/status',
      );
      expect(
        BrowserController.normalizeInput('localhost:3000'),
        'https://localhost:3000',
      );
    });

    test('preserves explicit HTTP and HTTPS URLs', () {
      expect(
        BrowserController.normalizeInput('https://fast.com/'),
        'https://fast.com/',
      );
      expect(
        BrowserController.normalizeInput('http://localhost:8080'),
        'http://localhost:8080',
      );
    });

    test('keeps the Erebrus start page', () {
      expect(BrowserController.normalizeInput(''), kStartPage);
      expect(BrowserController.normalizeInput(kStartPage), kStartPage);
    });
  });
}
