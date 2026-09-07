import 'package:erebrus_vpn/auth/deep_link_handler.dart';
import 'package:erebrus_vpn/auth/wallet_auth_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reown_appkit/reown_appkit.dart';

class _TestAuthController extends WalletAuthController {
  final links = <String>[];

  @override
  Future<void> handleWebAuthCallback(String url) async {
    links.add(url);
  }
}

class _TestReownModal extends Fake implements ReownAppKitModal {
  final links = <String>[];
  bool failDispatch = false;

  @override
  Future<bool> dispatchEnvelope(String url) async {
    links.add(url);
    if (failDispatch) throw StateError('dispatch failed');
    return true;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const methods = MethodChannel('com.erebrus.vpn/methods');
  const events = MethodChannel('com.erebrus.vpn/events');
  const codec = StandardMethodCodec();
  const firstLink = 'erebrusvpn://auth?token=test-first';
  const latestLink = 'erebrusvpn://auth?token=test-latest';

  Future<void> emitLink(String? link) async {
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope(link),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUpAll(() async {
    messenger.setMockMethodCallHandler(events, (_) async => null);
    DeepLinkHandler.initListener();
    await Future<void>.delayed(Duration.zero);
  });

  setUp(() {
    DeepLinkHandler.resetForTesting();
    messenger.setMockMethodCallHandler(methods, (_) async => null);
  });

  tearDown(() {
    DeepLinkHandler.resetForTesting();
    messenger.setMockMethodCallHandler(methods, null);
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMessageHandler(events.name, null);
  });

  test('replays the latest early event once when auth binds', () async {
    final auth = _TestAuthController();
    await emitLink(firstLink);
    await emitLink(latestLink);
    await emitLink(null);
    expect(auth.links, isEmpty);

    DeepLinkHandler.bind(auth);
    await Future<void>.delayed(Duration.zero);
    expect(auth.links, [latestLink]);

    DeepLinkHandler.bind(auth);
    await Future<void>.delayed(Duration.zero);
    expect(auth.links, [latestLink]);
  });

  test('delivers events immediately after binding', () async {
    final auth = _TestAuthController();
    DeepLinkHandler.bind(auth);

    await emitLink(firstLink);
    await emitLink(latestLink);

    expect(auth.links, [firstLink, latestLink]);
  });

  test('buffers an Android initial-link result before binding', () async {
    messenger.setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'initialLink');
      return firstLink;
    });
    await DeepLinkHandler.checkInitialLink();
    final auth = _TestAuthController();

    DeepLinkHandler.bind(auth);
    await Future<void>.delayed(Duration.zero);

    expect(auth.links, [firstLink]);
  });

  test('delivers an Android initial-link result after binding', () async {
    final auth = _TestAuthController();
    DeepLinkHandler.bind(auth);
    messenger.setMockMethodCallHandler(methods, (_) async => firstLink);

    await DeepLinkHandler.checkInitialLink();
    await Future<void>.delayed(Duration.zero);

    expect(auth.links, [firstLink]);
  });

  test(
    'does not replay an Android launch event again for a null result',
    () async {
      final auth = _TestAuthController();
      await emitLink(firstLink);
      DeepLinkHandler.bind(auth);

      await DeepLinkHandler.checkInitialLink();
      await Future<void>.delayed(Duration.zero);

      expect(auth.links, [firstLink]);
    },
  );

  test('accepts stream delivery with a null initial-link result', () async {
    final auth = _TestAuthController();
    DeepLinkHandler.bind(auth);
    messenger.setMockMethodCallHandler(methods, (_) async {
      await emitLink(firstLink);
      return null;
    });

    await DeepLinkHandler.checkInitialLink();
    await Future<void>.delayed(Duration.zero);

    expect(auth.links, [firstLink]);
  });

  test('replays an early wallet envelope after Reown is ready', () async {
    const envelope = 'erebrusvpn://wc?envelope=test-envelope';
    final modal = _TestReownModal();
    final auth = _TestAuthController();
    await emitLink(envelope);
    expect(modal.links, isEmpty);

    auth.appKitModal = modal;
    DeepLinkHandler.bind(auth);
    await Future<void>.delayed(Duration.zero);

    expect(modal.links, [envelope]);
    expect(auth.links, isEmpty);
  });

  test('handles asynchronous errors from pending-link replay', () async {
    const envelope = 'erebrusvpn://wc?envelope=test-envelope';
    final modal = _TestReownModal()..failDispatch = true;
    final auth = _TestAuthController()..appKitModal = modal;
    await emitLink(envelope);

    DeepLinkHandler.bind(auth);
    await Future<void>.delayed(Duration.zero);

    expect(modal.links, [envelope]);
    DeepLinkHandler.bind(auth);
    await Future<void>.delayed(Duration.zero);
    expect(modal.links, [envelope]);
  });

  test('ignores a null initial-link response', () async {
    final auth = _TestAuthController();
    DeepLinkHandler.bind(auth);

    await DeepLinkHandler.checkInitialLink();
    await Future<void>.delayed(Duration.zero);

    expect(auth.links, isEmpty);
  });

  test('handles an absent native initial-link channel', () async {
    messenger.setMockMethodCallHandler(methods, null);

    await DeepLinkHandler.checkInitialLink();
    await Future<void>.delayed(Duration.zero);
  });

  test('handles asynchronous native initial-link failures', () async {
    messenger.setMockMethodCallHandler(methods, (_) async {
      await Future<void>.delayed(Duration.zero);
      throw PlatformException(code: 'initial-link-failed');
    });

    await DeepLinkHandler.checkInitialLink();
    await Future<void>.delayed(Duration.zero);
  });
}
