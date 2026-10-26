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

  test('friendlyGatewayError maps missing workspace without trial copy', () {
    final msg = friendlyGatewayError(
      GatewayException(
        'active organization membership is required to use public nodes',
        statusCode: 402,
        code: 'ENTITLEMENT_REQUIRED',
      ),
    );
    expect(msg, isNot(contains('trial')));
    expect(msg, contains('workspace'));
  });

  test('friendlyGatewayError explains the plan device limit with numbers', () {
    const body =
        '{"error":"device limit reached for your plan","code":"VPN_DEVICE_LIMIT","details":{"limit":3,"used":3,"plan_id":"personal.starter"}}';
    final msg = friendlyGatewayError(
      GatewayException(
        GatewayHttp.errorMessage(409, body),
        statusCode: 409,
        code: GatewayHttp.errorCode(body),
        details: GatewayHttp.errorDetails(body),
      ),
    );
    expect(msg, contains('3/3'));
    expect(msg, contains('erebrus.io/pricing'));
  });

  test('friendlyGatewayError explains paused devices and billing holds', () {
    expect(
      friendlyGatewayError(
        GatewayException('paused', statusCode: 409, code: 'VPN_DEVICE_PAUSED'),
      ),
      contains('paused'),
    );
    expect(
      friendlyGatewayError(
        GatewayException('suspended', statusCode: 402, code: 'BILLING_ACCESS_REQUIRED'),
      ),
      contains('billing'),
    );
  });

  test('a draining node is not reported as a device limit', () {
    final msg = friendlyGatewayError(
      GatewayException('node is draining', statusCode: 409, code: 'NODE_DRAINING'),
      nodeName: 'fra-1',
    );
    expect(msg, contains('fra-1'));
    expect(msg, isNot(contains('limit')));
  });

  test('gateway client rows mark plan-paused devices', () {
    final row = VpnClientRow.fromJson({
      'id': 'c1',
      'node_id': 'n1',
      'wg_public_key': 'k',
      'status': 'suspended_plan_limit',
    });
    expect(row.isPlanPaused, isTrue);
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

  test('plan-limit rejections cannot use cached credentials', () {
    for (final code in ['VPN_DEVICE_LIMIT', 'VPN_DEVICE_PAUSED']) {
      final error = GatewayException('rejected', statusCode: 409, code: code);
      expect(error.isPlanLimitRejected, isTrue, reason: code);
      expect(error.blocksProvisioningFallback, isTrue, reason: code);
    }
  });
}
