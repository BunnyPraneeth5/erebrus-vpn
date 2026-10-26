import 'dart:convert';
import 'dart:io';

import 'package:erebrus_vpn/auth/session_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Uri origin;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = Uri.parse('http://127.0.0.1:${server.port}');
  });
  tearDown(() => server.close(force: true));

  for (final path in ['/api/v2/auth/refresh', '/api/v2/auth/logout']) {
    test(
      '$path sends JSON without a bearer and makes exactly one attempt',
      () async {
        var calls = 0;
        final serving = server.first.then((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(
            request.headers.value(HttpHeaders.authorizationHeader),
            isNull,
          );
          expect(request.headers.contentType!.mimeType, 'application/json');
          expect(jsonDecode(await utf8.decodeStream(request)), {
            'refresh_token': 'secret',
          });
          request.response.statusCode = path.endsWith('/logout') ? 204 : 503;
          await request.response.close();
        });
        final response = await sendSessionRequest(
          'POST',
          origin.resolve(path),
          body: '{"refresh_token":"secret"}',
        );
        await serving;
        expect(response.status, path.endsWith('/logout') ? 204 : 503);
        expect(calls, 1);
      },
    );
  }

  for (final dateForm in [false, true]) {
    test(
      'Retry-After ${dateForm ? 'HTTP date' : 'seconds'} is exposed to the coordinator',
      () async {
        final date = DateTime.now().toUtc().add(const Duration(minutes: 5));
        final serving = server.first.then((request) async {
          request.response.statusCode = 429;
          request.response.headers.set(
            HttpHeaders.retryAfterHeader,
            dateForm ? HttpDate.format(date) : '300',
          );
          request.response.write('{"code":"RATE_LIMITED"}');
          await request.response.close();
        });
        final response = await sendSessionRequest(
          'POST',
          origin.resolve('/api/v2/auth/refresh'),
          body: '{}',
        );
        await serving;
        expect(response.status, 429);
        expect(response.retryAt!.difference(date).inSeconds.abs(), lessThan(2));
      },
    );
  }
}
