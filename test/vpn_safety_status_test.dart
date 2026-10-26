import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:erebrus_vpn/platform/platform_capabilities.dart';
import 'package:erebrus_vpn/theme/app_theme.dart';
import 'package:erebrus_vpn/view/browser/browser_session_status.dart';
import 'package:erebrus_vpn/view/home/connect_dial.dart';
import 'package:erebrus_vpn/view/home/diagnostics_sheet.dart';
import 'package:erebrus_vpn/vpn/singbox_engine.dart';
import 'package:erebrus_vpn/vpn/vpn_controller.dart';
import 'package:erebrus_vpn/vpn/vpn_models.dart';

class _NoNetworkEngine implements SingboxEngine {
  @override
  Stream<VpnStage> get onStage => const Stream.empty();

  @override
  Stream<VpnStats> get onStats => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw StateError('Status rendering must not call the engine');
  }
}

class _StatusOnlyController extends VpnController {
  _StatusOnlyController()
    : super(engine: _NoNetworkEngine(), egressProbe: () async => null);
}

String _expectedLabel({
  required VpnStage stage,
  required bool healthy,
  required bool blocking,
  required bool engaging,
  required bool proxy,
}) {
  if (engaging) {
    return proxy ? 'BLOCKING PROXY TRAFFIC' : 'BLOCKING TUNNEL TRAFFIC';
  }
  if (blocking) {
    return proxy ? 'PROXY TRAFFIC BLOCKED' : 'TUNNEL TRAFFIC BLOCKED';
  }
  if (stage == VpnStage.connected) {
    if (!healthy) return 'TUNNEL STALLED';
    return proxy ? 'PROXY CONNECTED' : 'PROTECTED';
  }
  return 'NOT PROTECTED';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
  });

  tearDown(() async {
    Get.reset();
  });

  for (final proxy in [false, true]) {
    for (final stage in VpnStage.values) {
      for (final healthy in [false, true]) {
        for (final blocking in [false, true]) {
          for (final engaging in [false, true]) {
            test('status scope=$proxy stage=$stage healthy=$healthy '
                'blocking=$blocking engaging=$engaging', () {
              final vpn = VpnController(engine: _NoNetworkEngine());
              vpn.stage.value = stage;
              vpn.tunnelHealthy.value = healthy;
              vpn.killSwitchBlocking.value = blocking;
              vpn.killSwitchEngaging.value = engaging;
              vpn.activeTransport.value = Transport.wireguard;
              final protected =
                  stage == VpnStage.connected &&
                  healthy &&
                  !blocking &&
                  !engaging;
              final expected = _expectedLabel(
                stage: stage,
                healthy: healthy,
                blocking: blocking,
                engaging: engaging,
                proxy: proxy,
              );
              final status = vpnSafetyStatus(vpn, proxyScoped: proxy);
              expect(vpn.isProtected, protected);
              expect(status.isProtected, protected);
              expect(status.label, expected);
              expect(status.color == AppColors.success, protected);

              final browser = browserSessionStatus(vpn, proxyScoped: proxy);
              expect(browser.tint == AppColors.success, protected);
              expect(
                browser.label.contains('PRIVATE SESSION'),
                protected && !proxy,
              );
              if (protected) {
                expect(
                  browser.label,
                  '${proxy ? 'PROXY CONNECTED' : 'PRIVATE SESSION'} · WIREGUARD',
                );
              } else if (engaging || blocking || stage == VpnStage.connected) {
                expect(browser.label, expected);
              } else if (stage == VpnStage.connecting) {
                expect(browser.label, 'CONNECTING · WIREGUARD');
              } else if (stage == VpnStage.disconnecting) {
                expect(browser.label, 'STOPPING · WIREGUARD');
              } else {
                expect(browser.label, 'NOT PROTECTED');
              }

              final diagnostics = diagnosticsSafetyLabel(
                status,
                proxyScoped: proxy,
              );
              expect(diagnostics.contains('ENCRYPTED'), protected);
              expect(
                diagnostics.contains('TUNNEL ACTIVE'),
                protected && !proxy,
              );
              expect(
                diagnostics,
                protected
                    ? proxy
                          ? 'PROXY CONNECTED · PROXIED TRAFFIC ENCRYPTED'
                          : 'TUNNEL ACTIVE · TRAFFIC ENCRYPTED'
                    : expected,
              );
            });
          }
        }
      }
    }
  }

  testWidgets(
    'dial gates its verified icon and labels for every safety state',
    (tester) async {
      final vpn = VpnController(engine: _NoNetworkEngine());
      for (final proxy in [false, true]) {
        for (final stage in VpnStage.values) {
          for (final healthy in [false, true]) {
            for (final blocking in [false, true]) {
              for (final engaging in [false, true]) {
                vpn.stage.value = stage;
                vpn.tunnelHealthy.value = healthy;
                vpn.killSwitchBlocking.value = blocking;
                vpn.killSwitchEngaging.value = engaging;
                final status = vpnSafetyStatus(vpn, proxyScoped: proxy);
                await tester.pumpWidget(
                  MaterialApp(
                    home: Scaffold(
                      body: Center(
                        child: ConnectDial(
                          stage: stage,
                          status: status,
                          durationLabel: '00:12',
                        ),
                      ),
                    ),
                  ),
                );
                expect(
                  find.byIcon(Icons.verified_user),
                  status.isProtected ? findsOneWidget : findsNothing,
                );
                expect(
                  find.text('PROTECTED'),
                  status.isProtected && !proxy ? findsOneWidget : findsNothing,
                );
                expect(
                  find.text('PROXY CONNECTED'),
                  status.isProtected && proxy ? findsOneWidget : findsNothing,
                );
                if (engaging || blocking || stage == VpnStage.connected) {
                  expect(find.text(status.label), findsOneWidget);
                }
                expect(tester.takeException(), isNull);
              }
            }
          }
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('connected stage alone cannot give a dial a protection claim', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: ConnectDial(
              stage: VpnStage.connected,
              durationLabel: '00:12',
            ),
          ),
        ),
      ),
    );
    expect(find.text('NOT PROTECTED'), findsOneWidget);
    expect(find.byIcon(Icons.verified_user), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'browser strip and uninjected dial react to health and enforcement changes',
    (tester) async {
      final vpn = Get.put<VpnController>(_StatusOnlyController());
      vpn.stage.value = VpnStage.connected;
      vpn.activeTransport.value = Transport.wireguard;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                BrowserSessionStrip(),
                ConnectDial(stage: VpnStage.connected, durationLabel: '00:12'),
              ],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.verified_user), findsOneWidget);

      vpn.tunnelHealthy.value = false;
      await tester.pump();
      expect(find.text('TUNNEL STALLED'), findsNWidgets(2));
      expect(find.byIcon(Icons.verified_user), findsNothing);
      expect(find.textContaining('PRIVATE SESSION'), findsNothing);

      vpn.tunnelHealthy.value = true;
      vpn.killSwitchEngaging.value = true;
      await tester.pump();
      expect(find.text(vpnSafetyStatus(vpn).label), findsNWidgets(2));
      expect(find.byIcon(Icons.verified_user), findsNothing);
      expect(find.textContaining('TRAFFIC BLOCKED'), findsNothing);

      vpn.killSwitchBlocking.value = true;
      vpn.killSwitchEngaging.value = false;
      await tester.pump();
      expect(find.text(vpnSafetyStatus(vpn).label), findsNWidgets(2));
      expect(find.byIcon(Icons.verified_user), findsNothing);

      vpn.killSwitchBlocking.value = false;
      vpn.stage.value = VpnStage.error;
      await tester.pump();
      expect(find.text('NOT PROTECTED'), findsNWidgets(2));
      expect(find.textContaining('PRIVATE SESSION'), findsNothing);
      expect(find.byIcon(Icons.verified_user), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'diagnostics retract encryption claims when health or blocking changes',
    (tester) async {
      final vpn = Get.put<VpnController>(_StatusOnlyController());
      vpn.stage.value = VpnStage.connected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDiagnosticsSheet(context),
                child: const Text('Diagnostics'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Diagnostics'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(
          diagnosticsSafetyLabel(
            vpnSafetyStatus(vpn),
            proxyScoped: PlatformCapabilities.usesDesktopVpnRunner,
          ),
        ),
        findsOneWidget,
      );
      if (PlatformCapabilities.usesDesktopVpnRunner) {
        expect(
          find.text(
            'Only traffic using the system proxy is covered; apps that bypass it are not blocked.',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('TUNNEL ACTIVE'), findsNothing);
      }

      vpn.tunnelHealthy.value = false;
      await tester.pump();
      expect(find.textContaining('ENCRYPTED'), findsNothing);
      expect(find.text('TUNNEL STALLED'), findsWidgets);

      vpn.killSwitchEngaging.value = true;
      await tester.pump();
      expect(find.textContaining('ENCRYPTED'), findsNothing);
      expect(find.textContaining('TRAFFIC BLOCKED'), findsNothing);
      expect(find.text('Verifying enforcement…'), findsOneWidget);

      vpn.killSwitchBlocking.value = true;
      vpn.killSwitchEngaging.value = false;
      await tester.pump();
      expect(find.text(vpnSafetyStatus(vpn).label), findsWidgets);
      expect(find.textContaining('ENCRYPTED'), findsNothing);
      vpn.onClose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
