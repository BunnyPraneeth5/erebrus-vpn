import 'package:erebrus_vpn/view/browser/browser_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  group('BrowserController.isWebUrl', () {
    test('accepts only http(s) URLs with a host', () {
      expect(BrowserController.isWebUrl('https://erebrus.io/a'), isTrue);
      expect(BrowserController.isWebUrl('http://localhost:3000'), isTrue);
      expect(BrowserController.isWebUrl('about:blank'), isFalse);
      expect(BrowserController.isWebUrl('javascript:void(0)'), isFalse);
      expect(BrowserController.isWebUrl('data:text/html,hi'), isFalse);
      expect(BrowserController.isWebUrl(''), isFalse);
    });
  });
}
