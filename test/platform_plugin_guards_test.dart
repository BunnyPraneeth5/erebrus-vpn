import 'dart:io';

import 'package:erebrus_vpn/auth/social_login.dart';
import 'package:erebrus_vpn/platform/android_split_tunnel.dart';
import 'package:erebrus_vpn/vpn/singbox_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  final unsupportedDesktop = Platform.isWindows || Platform.isLinux;

  test('desktop Google logout does not invoke a missing plugin', () async {
    const channel = MethodChannel('plugins.flutter.io/google_sign_in');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await googleSignOut();

    expect(calls, isEmpty);
  }, skip: !unsupportedDesktop);

  test('unsupported desktops never offer native Apple sign-in', () async {
    expect(await appleSignInSupported(), isFalse);
  }, skip: !unsupportedDesktop);

  test('unsupported Apple sign-in fails before plugin dispatch', () async {
    await expectLater(appleCredential(), throwsA(isA<SocialLoginException>()));
  }, skip: !unsupportedDesktop);

  test('non-Apple On Demand never invokes the sing-box channel', () async {
    const channel = MethodChannel('dev.erebrus/singbox');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await SingboxEngine.instance.setOnDemandEnabled(true), isFalse);
    expect(calls, isEmpty);
  }, skip: Platform.isIOS || Platform.isMacOS);

  test('non-Android app listing never invokes the sing-box channel', () async {
    const channel = MethodChannel('dev.erebrus/singbox');
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return <dynamic>[];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await AndroidSplitTunnel.listApps(), isEmpty);
    expect(calls, isEmpty);
  }, skip: Platform.isAndroid);
}
