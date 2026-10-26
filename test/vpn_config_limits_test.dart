import 'dart:convert';

import 'package:erebrus_vpn/auth/auth_repository.dart';
import 'package:erebrus_vpn/auth/session_transport.dart';
import 'package:erebrus_vpn/vpn/gateway_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _ConfigSessions extends AuthRepository {
  _ConfigSessions({
    required this.configCount,
    this.reconnect = false,
    this.rejectConnection = false,
  }) : super(gatewayUrl: 'https://gateway.test');

  final int configCount;
  final bool reconnect;
  final bool rejectConnection;
  int listRequests = 0;
  int provisionRequests = 0;
  int credentialRequests = 0;

  static const _bundle = {
    'wireguard': {
      'server_public_key': 'server-key',
      'endpoint': '203.0.113.10:51820',
      'address': '10.0.0.2/32',
    },
  };

  @override
  Future<SessionResponse> request(
    String method,
    Uri uri, {
    String? body,
    Map<String, String>? headers,
  }) async {
    if (method == 'GET' && uri.path == '/api/v2/vpn/clients') {
      listRequests++;
      return SessionResponse(
        200,
        jsonEncode(
          List.generate(
            configCount,
            (index) => {
              'id': 'config-$index',
              'node_id': 'selected-node',
              'wg_public_key': reconnect && index == configCount - 1
                  ? 'this-device-key'
                  : 'old-key-$index',
              // Provisioned is not the same as connected.
              'status': 'active',
            },
          ),
        ),
      );
    }
    if (method == 'GET' && uri.path.endsWith('/config')) {
      credentialRequests++;
      return SessionResponse(200, jsonEncode(_bundle));
    }
    if (method == 'POST' && uri.path == '/api/v2/vpn/clients') {
      provisionRequests++;
      if (rejectConnection) {
        return SessionResponse(
          409,
          jsonEncode({
            'error': 'Too many connected devices',
            'code': 'DEVICE_LIMIT_REACHED',
          }),
        );
      }
      return SessionResponse(201, jsonEncode(_bundle));
    }
    throw StateError('Unexpected request: $method ${uri.path}');
  }
}

void main() {
  for (final count in [5, 6, 20]) {
    test('$count saved configs do not block provisioning', () async {
      final sessions = _ConfigSessions(configCount: count);
      final client = GatewayClient(
        baseUrl: 'https://gateway.test',
        sessions: sessions,
      );
      final bundle = await client.provisionClient(
        nodeId: 'selected-node',
        wgPublicKey: 'this-device-key',
        name: 'Laptop',
      );
      expect(bundle.hasWireGuard, isTrue);
      expect(sessions.provisionRequests, 1);
    });
  }

  test(
    'reconnect reuses one of 20 saved configs without creating another',
    () async {
      final sessions = _ConfigSessions(configCount: 20, reconnect: true);
      final client = GatewayClient(
        baseUrl: 'https://gateway.test',
        sessions: sessions,
      );
      final bundle = await client.provisionClient(
        nodeId: 'selected-node',
        wgPublicKey: 'this-device-key',
        name: 'Laptop',
      );
      expect(bundle.hasWireGuard, isTrue);
      expect(sessions.provisionRequests, 0);
      expect(sessions.credentialRequests, 1);
    },
  );

  test(
    'explicit connected-device rejection is not retried through saved configs',
    () async {
      final sessions = _ConfigSessions(configCount: 20, rejectConnection: true);
      final client = GatewayClient(
        baseUrl: 'https://gateway.test',
        sessions: sessions,
      );
      await expectLater(
        client.provisionClient(
          nodeId: 'selected-node',
          wgPublicKey: 'this-device-key',
          name: 'Laptop',
        ),
        throwsA(
          isA<GatewayException>().having(
            (error) => error.code,
            'code',
            'DEVICE_LIMIT_REACHED',
          ),
        ),
      );
      expect(sessions.listRequests, 1);
      expect(sessions.provisionRequests, 1);
      expect(sessions.credentialRequests, 0);
    },
  );
}
