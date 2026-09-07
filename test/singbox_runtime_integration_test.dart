import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:erebrus_vpn/vpn/vpn_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final platform = Platform.isWindows ? 'windows-amd64' : 'linux-amd64';
  final binary = File(
    p.join(
      Directory.current.path,
      'bin',
      'sing-box',
      platform,
      Platform.isWindows ? 'sing-box.exe' : 'sing-box',
    ),
  );
  final canRun =
      (Platform.isWindows || Platform.isLinux) && binary.existsSync();

  test(
    'bundled engine accepts generated hostname WireGuard configuration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'erebrus-config-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = base64Encode(List<int>.filled(32, 1));
      final config = SingboxConfigBuilder.build(
        bundle: CredentialBundle.fromJson({
          'wireguard': {
            'server_public_key': key,
            'endpoint': 'vpn.example.com:51820',
            'address': '10.0.0.2/32',
            'dns': '1.1.1.1',
          },
        }),
        transport: Transport.wireguard,
        clientPrivateKey: key,
        useSystemTunnel: false,
        resolvedHosts: const {},
      );
      final file = File(p.join(directory.path, 'config.json'));
      await file.writeAsString(jsonEncode(config));
      final result = await Process.run(binary.path, ['check', '-c', file.path]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
    },
    skip: !canRun,
  );

  for (final blocked in [false, true]) {
    test(
      'bundled sing-box ${blocked ? 'blocks' : 'forwards'} local proxy traffic',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'erebrus-runtime-test-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final destination = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        var requests = 0;
        destination.listen((request) async {
          requests++;
          request.response.write('local-test-response');
          await request.response.close();
        });
        addTearDown(() => destination.close(force: true));
        final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = reservation.port;
        await reservation.close();

        final config = blocked
            ? SingboxConfigBuilder.killSwitchBlockConfig()
            : <String, dynamic>{
                'inbounds': [
                  {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': port},
                ],
                'outbounds': [
                  {'type': 'direct', 'tag': 'direct'},
                ],
                'route': {'final': 'direct'},
              };
        config['log'] = {'disabled': true};
        config.remove('experimental');
        (config['inbounds'] as List).first['listen_port'] = port;
        final configFile = File(p.join(directory.path, 'config.json'));
        await configFile.writeAsString(jsonEncode(config));
        final validation = await Process.run(binary.path, [
          'check',
          '-c',
          configFile.path,
        ]);
        expect(validation.exitCode, 0, reason: validation.stderr.toString());
        final process = await Process.start(binary.path, [
          'run',
          '-c',
          configFile.path,
        ]);
        final output = StringBuffer();
        final stdout = process.stdout
            .transform(utf8.decoder)
            .listen(output.write);
        final stderr = process.stderr
            .transform(utf8.decoder)
            .listen(output.write);
        int? exitCode;
        final exited = process.exitCode.then((code) => exitCode = code);
        addTearDown(() async {
          process.kill();
          await exited.timeout(const Duration(seconds: 5));
          await stdout.cancel();
          await stderr.cancel();
        });

        var ready = false;
        for (var i = 0; i < 50 && exitCode == null; i++) {
          try {
            final socket = await Socket.connect(
              '127.0.0.1',
              port,
              timeout: const Duration(milliseconds: 100),
            );
            socket.destroy();
            ready = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(ready, isTrue, reason: 'exit=$exitCode $output');

        final uri = Uri.parse('http://127.0.0.1:${destination.port}/test');
        final direct = HttpClient()..findProxy = (_) => 'DIRECT';
        addTearDown(() => direct.close(force: true));
        final control = await (await direct.getUrl(uri)).close();
        expect(await utf8.decoder.bind(control).join(), 'local-test-response');
        final baseline = requests;
        final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
        addTearDown(() => client.close(force: true));
        String? body;
        int? status;
        try {
          await (() async {
            final response = await (await client.getUrl(uri)).close();
            status = response.statusCode;
            body = await utf8.decoder.bind(response).join();
          })().timeout(const Duration(seconds: 3));
        } on IOException {
          if (!blocked) rethrow;
        } on TimeoutException {
          if (!blocked) rethrow;
        }
        if (blocked) {
          expect(status, isNot(200));
          expect(body, isNot('local-test-response'));
          expect(requests, baseline);
        } else {
          expect(status, 200);
          expect(body, 'local-test-response');
          expect(requests, baseline + 1);
        }
      },
      skip: !canRun,
    );
  }
}
