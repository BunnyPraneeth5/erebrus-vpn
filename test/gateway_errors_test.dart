import 'package:erebrus_vpn/auth/gateway_auth_client.dart';
import 'package:erebrus_vpn/vpn/gateway_client.dart';
import 'package:erebrus_vpn/vpn/gateway_errors.dart';
import 'package:erebrus_vpn/vpn/gateway_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only explicit revocation codes terminate authentication', () {
    final expired = AuthException(
      'invalid or expired token',
      statusCode: 401,
      code: 'SESSION_REVOKED',
    );
    final forbidden = AuthException('access denied', statusCode: 403);

    expect(expired.isSessionExpired, isTrue);
    expect(expired.code, 'SESSION_REVOKED');
    expect(
      AuthException('business error', statusCode: 401).isSessionExpired,
      isFalse,
    );
    expect(forbidden.isSessionExpired, isFalse);
  });

  test('gateway errors retain machine-readable envelope details', () {
    const body =
        '{"error":"invalid or expired token","code":"SESSION_EXPIRED"}';
    final error = GatewayException(
      GatewayHttp.errorMessage(401, body),
      statusCode: 401,
      code: GatewayHttp.errorCode(body),
    );

    expect(error.message, 'invalid or expired token');
    expect(error.code, 'SESSION_EXPIRED');
    expect(error.isSessionExpired, isFalse);
  });

  test('friendlyGatewayError maps node unreachable', () {
    final msg = friendlyGatewayError(
      GatewayException('node unreachable — no client created'),
      nodeName: 'erebrus-nexus',
    );
    expect(msg, contains('erebrus-nexus'));
    expect(msg, contains('9080'));
  });

  test('friendlyGatewayError maps subscription gate', () {
    final msg = friendlyGatewayError(
      GatewayException('no active subscription — start a trial or subscribe'),
    );
    expect(msg, contains('free trial'));
  });

  test('friendlyGatewayError maps tier gate', () {
    final msg = friendlyGatewayError(
      GatewayException('node requires a higher tier'),
    );
    expect(msg, contains('tier'));
  });

  test('friendlyGatewayError maps private node', () {
    final msg = friendlyGatewayError(
      GatewayException('private node — org membership required'),
    );
    expect(msg, contains('private'));
  });
  test('connected-device admission failure cannot use cached credentials', () {
    final error = GatewayException(
      'Too many connected devices',
      statusCode: 409,
      code: 'DEVICE_LIMIT_REACHED',
    );
    expect(error.isDeviceLimitReached, isTrue);
    expect(error.blocksProvisioningFallback, isTrue);
    expect(friendlyGatewayError(error), contains('disconnect another device'));
    expect(friendlyGatewayError(error), isNot(contains('remove')));
  });

  test('an unrelated conflict is not a connected-device limit', () {
    final error = GatewayException(
      'node is draining',
      statusCode: 409,
      code: 'NODE_DRAINING',
    );
    expect(error.isDeviceLimitReached, isFalse);
    expect(error.blocksProvisioningFallback, isFalse);
    expect(friendlyGatewayError(error), contains('draining'));
  });

  test('legacy config-count rejection does not recommend deleting configs', () {
    final error = GatewayException('client limit reached', statusCode: 409);
    expect(error.isDeviceLimitReached, isFalse);
    expect(friendlyGatewayError(error), contains('Saved configs do not use'));
    expect(
      friendlyGatewayError(error),
      isNot(contains('remove an old device')),
    );
  });
}
