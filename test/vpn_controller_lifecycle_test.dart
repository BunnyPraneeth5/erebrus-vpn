import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:erebrus_vpn/settings/app_settings_controller.dart';
import 'package:erebrus_vpn/settings/split_tunnel_config.dart';
import 'package:erebrus_vpn/vpn/singbox_engine.dart';
import 'package:erebrus_vpn/vpn/vpn_controller.dart';
import 'package:erebrus_vpn/vpn/vpn_models.dart';

class LifecycleEngine implements SingboxEngine {
  final events = StreamController<VpnStage>.broadcast(sync: true);
  VpnStage current = VpnStage.connected;
  bool blocking = false;
  bool verified = true;
  bool failStart = false;
  bool failStop = false;
  bool connectOnStart = true;
  bool stopBeforeStart = false;
  int starts = 0;
  int blockingChecks = 0;
  Completer<void>? stopping;
  Completer<void>? starting;
  Completer<bool>? verification;
  Completer<bool>? connectionVerification;
  final stopPreserved = <bool>[];
  final startPreserved = <bool>[];
  final splitConfigs = <SplitTunnelConfig>[];

  @override
  Future<bool> prepare() async => true;

  @override
  Stream<VpnStage> get onStage => events.stream;
  @override
  Stream<VpnStats> get onStats => const Stream.empty();
  @override
  bool get isBlocking => blocking && current == VpnStage.connected;
  @override
  Future<VpnStage> stage() async => current;
  @override
  Future<bool> verifyConnection() async => connectionVerification == null
      ? verified && !blocking && current == VpnStage.connected
      : connectionVerification!.future;
  @override
  Future<bool> verifyBlocking() async {
    blockingChecks++;
    return verification == null ? verified && isBlocking : verification!.future;
  }

  @override
  Future<void> stop({bool preserveProxy = false}) async {
    stopPreserved.add(preserveProxy);
    await stopping?.future;
    if (failStop) throw StateError('stop failed');
    current = VpnStage.disconnected;
    blocking = false;
    events.add(current);
  }

  @override
  Future<void> start(
    String configJson, {
    String profileName = 'Erebrus',
    SplitTunnelConfig splitTunnel = const SplitTunnelConfig(),
    bool preserveProxy = false,
  }) async {
    if (stopBeforeStart) await stop(preserveProxy: preserveProxy);
    starts++;
    startPreserved.add(preserveProxy);
    splitConfigs.add(splitTunnel);
    await starting?.future;
    if (failStart) throw StateError('start failed');
    blocking = profileName.contains('Kill switch');
    current = connectOnStart ? VpnStage.connected : VpnStage.connecting;
    events.add(current);
  }

  void drop([VpnStage terminal = VpnStage.error]) {
    current = terminal;
    events.add(current);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LifecycleSplitSettings extends AppSettingsController {
  @override
  SplitTunnelConfig activeSplitTunnelConfig() => const SplitTunnelConfig(
    enabled: true,
    mode: SplitTunnelMode.exclude,
    packages: ['test.bypass.app'],
  );
}

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LifecycleEngine engine;
  late VpnController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
    Get.put(AppSettingsController());
    engine = LifecycleEngine();
    controller = VpnController(
      engine: engine,
      egressProbe: () async => '203.0.113.1',
    );
    controller.onInit();
  });
  tearDown(() async {
    controller.onClose();
    await engine.events.close();
    Get.reset();
  });

  Future<void> disposeInitialFixture(WidgetTester tester) async {
    await tester.runAsync(() async {
      controller.onClose();
      await engine.events.close();
    });
  }

  Future<void> closeWidgetFixture(
    WidgetTester tester,
    LifecycleEngine widgetEngine,
    VpnController widgetController,
  ) async {
    widgetController.onClose();
    if (widgetEngine.starting?.isCompleted == false) {
      widgetEngine.starting!.complete();
    }
    if (widgetEngine.stopping?.isCompleted == false) {
      widgetEngine.stopping!.complete();
    }
    if (widgetEngine.verification?.isCompleted == false) {
      widgetEngine.verification!.complete(false);
    }
    await tester.pump();
    await widgetEngine.events.close();
    await tester.pump();
  }

  testWidgets(
    'periodic blocking verification revokes proxy claims and recovers only once',
    (tester) async {
      await disposeInitialFixture(tester);
      final engine = LifecycleEngine();
      final controller = VpnController(
        engine: engine,
        egressProbe: () async => '203.0.113.1',
      );
      controller.onInit();
      try {
        engine.blocking = true;
        await controller.syncWithNative();
        expect(controller.killSwitchBlocking.value, isTrue);
        await tester.pump(const Duration(seconds: 5));
        expect(controller.killSwitchBlocking.value, isTrue);
        expect(engine.blockingChecks, 2);
        engine.verified = false;
        engine.starting = Completer<void>();
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(controller.killSwitchBlocking.value, isFalse);
        expect(controller.isProtected, isFalse);
        expect(controller.killSwitchEngaging.value, isTrue);
        expect(engine.starts, 1);
        engine.verified = true;
        engine.starting!.complete();
        await tester.pump();
        expect(controller.killSwitchBlocking.value, isTrue);
        engine.verified = false;
        await tester.pump(const Duration(seconds: 5));
        expect(controller.killSwitchBlocking.value, isFalse);
        expect(controller.error.value, contains('could not be verified'));
        expect(controller.protectionLabel, 'Connection failed');
        expect(engine.starts, 1);
        final checks = engine.blockingChecks;
        await tester.pump(const Duration(seconds: 30));
        expect(engine.blockingChecks, checks);
        expect(engine.starts, 1);
      } finally {
        await closeWidgetFixture(tester, engine, controller);
      }
    },
  );

  testWidgets('disconnect cancels scheduled blocking verification', (
    tester,
  ) async {
    await disposeInitialFixture(tester);
    final engine = LifecycleEngine();
    final controller = VpnController(
      engine: engine,
      egressProbe: () async => '203.0.113.1',
    );
    controller.onInit();
    try {
      engine.blocking = true;
      await controller.syncWithNative();
      final checks = engine.blockingChecks;
      await controller.disconnect();
      engine.verified = false;
      await tester.pump(const Duration(seconds: 30));
      expect(engine.blockingChecks, checks);
      expect(engine.starts, 0);
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(controller.stage.value, VpnStage.disconnected);
    } finally {
      await closeWidgetFixture(tester, engine, controller);
    }
  });

  testWidgets('closing controller cancels blocking verification', (
    tester,
  ) async {
    await disposeInitialFixture(tester);
    final engine = LifecycleEngine();
    final controller = VpnController(
      engine: engine,
      egressProbe: () async => '203.0.113.1',
    );
    controller.onInit();
    try {
      engine.blocking = true;
      await controller.syncWithNative();
      final checks = engine.blockingChecks;
      controller.onClose();
      engine.verified = false;
      await tester.pump(const Duration(seconds: 30));
      expect(engine.blockingChecks, checks);
      expect(engine.starts, 0);
    } finally {
      await closeWidgetFixture(tester, engine, controller);
    }
  });

  testWidgets(
    'pending blocking verification never overlaps or revives after disconnect',
    (tester) async {
      await disposeInitialFixture(tester);
      final engine = LifecycleEngine();
      final controller = VpnController(
        engine: engine,
        egressProbe: () async => '203.0.113.1',
      );
      controller.onInit();
      try {
        engine.blocking = true;
        await controller.syncWithNative();
        engine.verification = Completer<bool>();
        final checks = engine.blockingChecks;
        await tester.pump(const Duration(seconds: 5));
        expect(engine.blockingChecks, checks + 1);
        await tester.pump(const Duration(seconds: 20));
        expect(engine.blockingChecks, checks + 1);
        await controller.disconnect();
        engine.verification!.complete(false);
        await tester.pump();
        await tester.pump(const Duration(seconds: 30));
        expect(engine.blockingChecks, checks + 1);
        expect(engine.starts, 0);
        expect(controller.killSwitchBlocking.value, isFalse);
        expect(controller.killSwitchEngaging.value, isFalse);
        expect(controller.stage.value, VpnStage.disconnected);
        expect(controller.error.value, isNull);
      } finally {
        await closeWidgetFixture(tester, engine, controller);
      }
    },
  );

  test(
    'expected internal stop before blocker startup does not trigger extra recovery',
    () async {
      engine.stopBeforeStart = true;
      await controller.syncWithNative();
      engine.drop();
      await flush();
      expect(controller.killSwitchBlocking.value, isTrue);
      expect(engine.starts, 1);
    },
  );

  test('blocker startup retains the configured split tunnel policy', () async {
    await Get.delete<AppSettingsController>();
    Get.put<AppSettingsController>(LifecycleSplitSettings());
    await controller.syncWithNative();
    engine.drop();
    await flush();
    expect(controller.killSwitchBlocking.value, isTrue);
    expect(engine.splitConfigs.single.enabled, isTrue);
    expect(engine.splitConfigs.single.mode, SplitTunnelMode.exclude);
    expect(engine.splitConfigs.single.packages, ['test.bypass.app']);
  });

  test(
    'connect stays unprotected until persistence and final verification finish',
    () async {
      final saving = Completer<void>();
      final verification = Completer<bool>();
      controller.onClose();
      controller = VpnController(
        engine: engine,
        egressProbe: () async => '203.0.113.1',
        beforeSessionSave: () => saving.future,
      );
      controller.onInit();
      final connection = controller.connect(
        node: VpnNode(
          id: 'test',
          name: 'Test',
          region: 'test',
          did: '',
          protocols: ['wireguard'],
          loadPct: 0,
        ),
        providedBundle: CredentialBundle.fromJson({
          'wireguard': {
            'server_public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'endpoint': '192.0.2.1:51820',
            'address': '10.0.0.2/32',
          },
        }),
        clientPrivateKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      );
      try {
        await flush();
        expect(controller.isProtected, isFalse);
        expect(controller.stage.value, VpnStage.connecting);
        engine.connectionVerification = verification;
        saving.complete();
        await flush();
        expect(controller.isProtected, isFalse);
        expect(controller.tunnelHealthy.value, isFalse);
        expect(controller.stage.value, VpnStage.connecting);
        expect(controller.activeTransport.value, Transport.wireguard);
        final prefs = await SharedPreferences.getInstance();
        final snapshot =
            jsonDecode(prefs.getString('vpn.session.snapshot')!)
                as Map<String, dynamic>;
        expect(snapshot['transport'], 'wireguard');
        verification.complete(true);
        await connection;
        await flush();
        expect(controller.isProtected, isTrue);
        expect(controller.stage.value, VpnStage.connected);
        expect(engine.stopPreserved, everyElement(isTrue));
      } finally {
        controller.onClose();
        if (!saving.isCompleted) {
          saving.complete();
        }
        if (!verification.isCompleted) {
          verification.complete(false);
        }
        await connection;
      }
    },
  );

  test(
    'VPN exit during delayed snapshot save stays unprotected and defers engagement',
    () async {
      final saving = Completer<void>();
      controller.onClose();
      controller = VpnController(
        engine: engine,
        egressProbe: () async => '203.0.113.1',
        beforeSessionSave: () => saving.future,
      );
      controller.onInit();
      final connection = controller.connect(
        node: VpnNode(
          id: 'test',
          name: 'Test',
          region: 'test',
          did: '',
          protocols: ['wireguard'],
          loadPct: 0,
        ),
        providedBundle: CredentialBundle.fromJson({
          'wireguard': {
            'server_public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'endpoint': '192.0.2.1:51820',
            'address': '10.0.0.2/32',
          },
        }),
        clientPrivateKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      );
      await flush();
      expect(controller.isProtected, isFalse);
      expect(controller.tunnelHealthy.value, isFalse);
      expect(controller.stage.value, VpnStage.connecting);
      expect(controller.activeTransport.value, Transport.wireguard);
      engine.drop();
      expect(controller.isProtected, isFalse);
      expect(controller.stage.value, VpnStage.connecting);
      await flush();
      expect(engine.starts, 1);
      saving.complete();
      await connection;
      await flush();
      expect(engine.starts, 2);
      expect(controller.killSwitchBlocking.value, isTrue);
      expect(controller.isProtected, isFalse);
      expect(controller.activeTransport.value, isNull);
      expect(engine.stopPreserved, everyElement(isTrue));
    },
  );

  test(
    'blocker exit during sync snapshot save revokes blocking and recovers once',
    () async {
      final saving = Completer<void>();
      controller.onClose();
      controller = VpnController(
        engine: engine,
        egressProbe: () async => '203.0.113.1',
        beforeSessionSave: () => saving.future,
      );
      controller.onInit();
      controller.selectNode(
        VpnNode(
          id: 'test',
          name: 'Test',
          region: 'test',
          did: '',
          protocols: ['wireguard'],
          loadPct: 0,
        ),
      );
      SharedPreferences.setMockInitialValues({
        'vpn.session.snapshot': jsonEncode({'kill_switch_active': true}),
      });
      final syncing = controller.syncWithNative();
      await flush();
      expect(controller.killSwitchBlocking.value, isTrue);
      engine.drop(VpnStage.disconnected);
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(controller.isProtected, isFalse);
      await flush();
      expect(engine.starts, 1);
      saving.complete();
      await syncing;
      await flush();
      expect(controller.killSwitchBlocking.value, isTrue);
      expect(engine.starts, 2);
      engine.drop();
      await flush();
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(engine.starts, 2);
    },
  );

  test(
    'terminal event during sync verification cannot restore a stale blocking claim',
    () async {
      engine.blocking = true;
      engine.verification = Completer<bool>();
      final syncing = controller.syncWithNative();
      await flush();
      engine.drop();
      engine.failStart = true;
      engine.verification!.complete(true);
      await syncing;
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(controller.isProtected, isFalse);
      expect(controller.stage.value, VpnStage.error);
    },
  );

  test(
    'blocking is not claimed before stop start and verification finish',
    () async {
      await controller.syncWithNative();
      engine.stopping = Completer<void>();
      engine.starting = Completer<void>();
      engine.verification = Completer<bool>();
      engine.drop();
      await flush();
      expect(controller.killSwitchEngaging.value, isTrue);
      expect(controller.killSwitchBlocking.value, isFalse);
      engine.stopping!.complete();
      await flush();
      expect(controller.killSwitchBlocking.value, isFalse);
      engine.starting!.complete();
      await flush();
      expect(controller.isProtected, isFalse);
      expect(controller.killSwitchBlocking.value, isFalse);
      engine.verification!.complete(true);
      await flush();
      expect(controller.killSwitchBlocking.value, isTrue);
      expect(controller.isProtected, isFalse);
      expect(engine.stopPreserved, everyElement(isTrue));
      expect(engine.startPreserved, everyElement(isTrue));
    },
  );

  test('accepted block start must still wait for connected stage', () async {
    await controller.syncWithNative();
    engine.connectOnStart = false;
    engine.drop();
    await flush();
    expect(engine.starts, 1);
    expect(controller.killSwitchEngaging.value, isTrue);
    expect(controller.killSwitchBlocking.value, isFalse);
    expect(controller.isProtected, isFalse);
    engine.current = VpnStage.connected;
    engine.events.add(VpnStage.connected);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(controller.killSwitchBlocking.value, isTrue);
    expect(controller.isProtected, isFalse);
  });

  test(
    'failed blocker start reports failure without claiming blocking',
    () async {
      await controller.syncWithNative();
      engine.failStart = true;
      engine.drop();
      await flush();
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(controller.killSwitchEngaging.value, isFalse);
      expect(controller.error.value, contains('could not be verified'));
      expect(controller.isProtected, isFalse);
      expect(
        controller.protectionLabel.toLowerCase(),
        isNot(contains('protected')),
      );
    },
  );

  test('saved blocking flag must be verified or reestablished', () async {
    SharedPreferences.setMockInitialValues({
      'vpn.session.snapshot': jsonEncode({'kill_switch_active': true}),
    });
    engine.verified = false;
    engine.failStart = true;
    await controller.syncWithNative();
    expect(controller.killSwitchBlocking.value, isFalse);
    expect(controller.isProtected, isFalse);
    expect(controller.stage.value, VpnStage.error);
  });

  test('running block config cannot become protected on sync', () async {
    engine.blocking = true;
    await controller.syncWithNative();
    expect(controller.killSwitchBlocking.value, isTrue);
    expect(controller.isProtected, isFalse);
  });

  test('blocker exit clears claim immediately and retries only once', () async {
    engine.blocking = true;
    await controller.syncWithNative();
    engine.starting = Completer<void>();
    engine.drop();
    expect(controller.killSwitchBlocking.value, isFalse);
    await flush();
    engine.starting!.complete();
    await flush();
    expect(controller.killSwitchBlocking.value, isTrue);
    engine.drop();
    await flush();
    expect(controller.killSwitchBlocking.value, isFalse);
    expect(engine.starts, 1);
  });

  test('disconnect during engagement cannot revive blocker', () async {
    await controller.syncWithNative();
    engine.stopping = Completer<void>();
    engine.drop();
    await flush();
    final disconnect = controller.disconnect();
    engine.stopping!.complete();
    await disconnect;
    await flush();
    expect(engine.starts, 0);
    expect(controller.killSwitchBlocking.value, isFalse);
    expect(controller.killSwitchEngaging.value, isFalse);
    expect(controller.stage.value, VpnStage.disconnected);
    expect(engine.stopPreserved.last, isFalse);
  });

  test(
    'disconnect during delayed start waits and stops the obsolete blocker',
    () async {
      await controller.syncWithNative();
      engine.starting = Completer<void>();
      engine.drop();
      await flush();
      expect(engine.starts, 1);
      final disconnect = controller.disconnect();
      engine.starting!.complete();
      await disconnect;
      await flush();
      expect(engine.current, VpnStage.disconnected);
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(controller.killSwitchEngaging.value, isFalse);
      expect(controller.stage.value, VpnStage.disconnected);
      engine.current = VpnStage.connected;
      engine.events.add(VpnStage.connected);
      await flush();
      expect(controller.isProtected, isFalse);
    },
  );

  test('failed stop does not proceed to a replacement start', () async {
    await controller.syncWithNative();
    engine.failStop = true;
    engine.drop();
    await flush();
    expect(engine.starts, 0);
    expect(controller.killSwitchBlocking.value, isFalse);
    expect(controller.error.value, contains('could not be verified'));
  });

  test(
    'failed verification does not claim blocking after a successful start',
    () async {
      await controller.syncWithNative();
      engine.verified = false;
      engine.drop();
      await flush();
      expect(engine.starts, 1);
      expect(controller.killSwitchBlocking.value, isFalse);
      expect(controller.killSwitchEngaging.value, isFalse);
      expect(controller.error.value, contains('could not be verified'));
    },
  );

  test('system routing verification failure prevents protected sync', () async {
    engine.verified = false;
    await controller.syncWithNative();
    expect(controller.isProtected, isFalse);
    expect(controller.stage.value, VpnStage.error);
    expect(controller.activeTransport.value, isNull);
  });

  test('terminal error clears protected state without kill switch', () async {
    Get.find<AppSettingsController>().killSwitchEnabled.value = false;
    await controller.syncWithNative();
    await flush();
    expect(controller.isProtected, isTrue);
    engine.drop();
    expect(controller.isProtected, isFalse);
    expect(controller.isConnected, isFalse);
    expect(controller.activeTransport.value, isNull);
    expect(controller.protectionLabel, 'Connection failed');
  });

  test('first egress failure removes protected state', () async {
    controller.onClose();
    controller = VpnController(engine: engine, egressProbe: () async => null);
    controller.onInit();
    await controller.syncWithNative();
    await flush();
    expect(controller.tunnelHealthy.value, isFalse);
    expect(controller.isProtected, isFalse);
  });
}
