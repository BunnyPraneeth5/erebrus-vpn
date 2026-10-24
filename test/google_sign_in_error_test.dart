import 'package:erebrus_vpn/auth/social_login.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlatformException failure(String message) =>
      PlatformException(code: 'sign_in_failed', message: message);

  test('DEVELOPER_ERROR (10) explains the build is not registered', () {
    final msg = googleSignInErrorMessage(
      failure('com.google.android.gms.common.api.ApiException: 10: '),
    );
    expect(msg, contains('isn\'t set up for this build'));
    expect(msg, isNot(contains('ApiException')));
  });

  test('network error (7) asks for a connection', () {
    final msg = googleSignInErrorMessage(
      failure('com.google.android.gms.common.api.ApiException: 7: '),
    );
    expect(msg, contains('internet connection'));
  });

  test('unknown codes keep the status code for support', () {
    final msg = googleSignInErrorMessage(
      failure('com.google.android.gms.common.api.ApiException: 16: '),
    );
    expect(msg, contains('code 16'));
  });

  test('errors without a status code stay readable', () {
    final msg = googleSignInErrorMessage(
      PlatformException(code: 'network_error'),
    );
    expect(msg, startsWith('Google sign-in failed.'));
  });
}
