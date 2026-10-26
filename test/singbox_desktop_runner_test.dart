import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:erebrus_vpn/vpn/singbox_desktop_runner.dart';
import 'package:erebrus_vpn/vpn/singbox_engine.dart';
import 'package:erebrus_vpn/vpn/vpn_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _blocking =
    '{"inbounds":[{"type":"mixed"}],"outbounds":[{"type":"block","tag":"block"}],"route":{"final":"block"}}';
const _ordinary =
    '{"inbounds":[{"type":"mixed"}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}';

class _Process extends Fake implements Process {
  final done = Completer<int>();
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  int kills = 0;

  @override
  Future<int> get exitCode => done.future;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    exit(0);
    return true;
  }

  void exit(int code) {
    if (!done.isCompleted) done.complete(code);
  }

  void log(String line) => output.add(utf8.encode('$line\n'));
}

class _Harness {
  final processes = <_Process>[];
  bool proxy = false;
  bool ready = true;
  bool failEnable = false;
  bool ignoreEnable = false;
  bool failDisable = false;
  int disables = 0;
  Completer<void>? enableGate;
  late final runner = SingboxDesktopRunner.testing(
    findBinary: () async => 'fake-sing-box',
    writeConfig: (_) async => 'fake/config.json',
    startProcess: (_, _) async {
      final process = _Process();
      processes.add(process);
      return process;
    },
    endpointReady: () async => ready,
    enableProxy: () async {
      await enableGate?.future;
      if (failEnable) throw StateError('proxy enable failed');
      if (!ignoreEnable) proxy = true;
    },
    disableProxy: () async {
      disables++;
      if (failDisable) throw StateError('proxy disable failed');
      proxy = false;
    },
    proxyEnabled: () async => proxy,
  );

  Future<void> dispose() async {
    failDisable = false;
    await runner.stop();
    runner.dispose();
    for (final process in processes) {
      await process.output.close();
      await process.errors.close();
    }
  }
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  for (final code in [0, 17]) {
    test(
      'unexpected exit $code invalidates immediately and keeps proxy',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.runner.start(_blocking);
        h.processes.single.log('sing-box started');
        await _flush();
        expect(h.runner.stage, 'connected');
        final disables = h.disables;
        h.processes.single.exit(code);
        await _flush();
        expect(h.runner.stage, 'error');
        expect(h.runner.hasRunningProcess, isFalse);
        expect(h.runner.isBlocking, isFalse);
        expect(await h.runner.verifyBlocking(), isFalse);
        expect(h.proxy, isTrue);
        expect(h.disables, disables);
        expect(h.runner.lastError, contains('($code)'));
      },
    );
  }

  test(
    'stdout cannot publish connected while proxy setup is pending',
    () async {
      final h = _Harness()..enableGate = Completer<void>();
      addTearDown(h.dispose);
      final stages = <VpnStage>[];
      final sub = h.runner.onStage.listen(stages.add);
      addTearDown(sub.cancel);
      final starting = h.runner.start(_blocking);
      await _flush();
      h.processes.single.log('sing-box started');
      await _flush();
      expect(h.runner.stage, 'connecting');
      expect(stages, isNot(contains(VpnStage.connected)));
      expect(h.runner.isBlocking, isFalse);
      expect(await h.runner.verifyBlocking(), isFalse);
      h.enableGate!.complete();
      await starting;
      expect(h.runner.stage, 'connected');
      expect(await h.runner.verifyBlocking(), isTrue);
    },
  );

  test(
    'proxy setup failure never publishes connected and preserves routing',
    () async {
      final h = _Harness()..failEnable = true;
      h.proxy = true;
      addTearDown(h.dispose);
      final stages = <VpnStage>[];
      final sub = h.runner.onStage.listen(stages.add);
      addTearDown(sub.cancel);
      await expectLater(
        h.runner.start(_blocking, preserveProxy: true),
        throwsStateError,
      );
      await _flush();
      expect(stages, isNot(contains(VpnStage.connected)));
      expect(h.runner.stage, 'error');
      expect(h.runner.hasRunningProcess, isFalse);
      expect(h.proxy, isTrue);
      expect(h.disables, 0);
    },
  );

  test(
    'unverified proxy setup is rejected even without an enable exception',
    () async {
      final h = _Harness()..ignoreEnable = true;
      addTearDown(h.dispose);
      await expectLater(h.runner.start(_blocking), throwsStateError);
      expect(h.runner.stage, 'error');
      expect(h.runner.hasRunningProcess, isFalse);
      expect(await h.runner.verifyBlocking(), isFalse);
    },
  );

  test(
    'route exceptions cannot be mistaken for a blocking configuration',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final config = jsonDecode(_blocking) as Map<String, dynamic>;
      (config['route'] as Map)['rules'] = [
        {'outbound': 'direct'},
      ];
      await h.runner.start(jsonEncode(config));
      expect(h.runner.isBlocking, isFalse);
      expect(await h.runner.verifyBlocking(), isFalse);
    },
  );

  test('exit while enabling proxy cannot later publish connected', () async {
    final h = _Harness()..enableGate = Completer<void>();
    addTearDown(h.dispose);
    final starting = h.runner.start(_blocking);
    final assertion = expectLater(starting, throwsStateError);
    await _flush();
    h.processes.single.exit(0);
    await _flush();
    expect(h.runner.stage, 'error');
    h.enableGate!.complete();
    await assertion;
    expect(h.runner.stage, 'error');
    expect(h.proxy, isTrue);
  });

  test(
    'explicit stop awaits its exit cleanup before restart can proceed',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.runner.start(_blocking);
      final old = h.processes.single;
      final cleanup = Completer<void>();
      old.output.onCancel = () => cleanup.future;
      var stopped = false;
      final stopping = h.runner
          .stop(preserveProxy: true)
          .then((_) => stopped = true);
      final restarting = h.runner.start(_blocking, preserveProxy: true);
      await _flush();
      expect(stopped, isFalse);
      expect(h.runner.stage, isNot('connected'));
      expect(h.processes, hasLength(1));
      expect(h.proxy, isTrue);
      cleanup.complete();
      await stopping;
      await restarting;
      old.log('FATAL stale old process');
      old.errors.add(utf8.encode('ERROR stale stderr\n'));
      await _flush();
      expect(h.runner.stage, 'connected');
      expect(h.runner.hasRunningProcess, isTrue);
      expect(h.runner.lastError, isNull);
      expect(await h.runner.verifyBlocking(), isTrue);
      expect(h.processes.last.kills, 0);
      await h.runner.stop();
      expect(h.runner.stage, 'disconnected');
      expect(h.proxy, isFalse);
      expect(h.runner.lastError, isNull);
    },
  );

  test('unexpected exit cleanup is drained before replacing process', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.runner.start(_blocking);
    final old = h.processes.single;
    final cleanup = Completer<void>();
    old.output.onCancel = () => cleanup.future;
    old.exit(0);
    await _flush();
    expect(h.runner.stage, 'error');
    expect(h.proxy, isTrue);
    final restarting = h.runner.start(_blocking, preserveProxy: true);
    await _flush();
    expect(h.processes, hasLength(1));
    cleanup.complete();
    await restarting;
    expect(h.processes, hasLength(2));
    expect(h.runner.stage, 'connected');
  });

  test(
    'blocking verification requires block config, process, endpoint and proxy',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.runner.verifyBlocking(), isFalse);
      await h.runner.start(_ordinary);
      expect(h.runner.hasRunningProcess, isTrue);
      expect(h.runner.isBlocking, isFalse);
      expect(await h.runner.verifyBlocking(), isFalse);
      await h.runner.start(_blocking, preserveProxy: true);
      expect(await h.runner.verifyBlocking(), isTrue);
      h.proxy = false;
      expect(await h.runner.verifyBlocking(), isFalse);
      h.proxy = true;
      h.ready = false;
      expect(await h.runner.verifyBlocking(), isFalse);
      h.ready = true;
      h.processes.last.log('FATAL routing failed');
      await _flush();
      expect(h.runner.stage, 'error');
      expect(await h.runner.verifyBlocking(), isFalse);
      expect(h.proxy, isTrue);
    },
  );

  for (final blocking in [false, true]) {
    test(
      'individual ERROR preserves running ${blocking ? 'block' : 'normal'} config',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        await h.runner.start(blocking ? _blocking : _ordinary);
        final stages = <VpnStage>[];
        final sub = h.runner.onStage.listen(stages.add);
        addTearDown(sub.cancel);
        final disables = h.disables;
        for (final stderr in [false, true]) {
          final diagnostic =
              'ERROR ${stderr ? 'reject connection' : 'dial request failed'}';
          if (stderr) {
            h.processes.single.errors.add(utf8.encode('$diagnostic\n'));
          } else {
            h.processes.single.log(diagnostic);
          }
          await _flush();
          expect(h.runner.lastError, diagnostic);
          expect(h.runner.stage, 'connected');
          expect(h.runner.hasRunningProcess, isTrue);
          expect(h.runner.isBlocking, blocking);
          expect(await h.runner.verifyBlocking(), blocking);
          expect(h.proxy, isTrue);
          expect(h.disables, disables);
          expect(h.processes.single.kills, 0);
        }
        expect(stages, isEmpty);
      },
    );
  }

  test(
    'production kill-switch configuration is recognized as blocking',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.runner.start(
        jsonEncode(SingboxConfigBuilder.killSwitchBlockConfig()),
      );
      expect(h.runner.isBlocking, isTrue);
      expect(await h.runner.verifyBlocking(), isTrue);
    },
  );

  final blockCases = <String, (String, bool)>{
    'arbitrary block outbound tag': (
      '{"inbounds":[],"outbounds":[{"tag":"deny","type":"block"}],"route":{"final":"deny"}}',
      true,
    ),
    'block-named direct outbound': (
      '{"inbounds":[],"outbounds":[{"tag":"block","type":"direct"}],"route":{"final":"block"}}',
      false,
    ),
    'unrouted block outbound': (
      '{"inbounds":[],"outbounds":[{"tag":"block","type":"block"},{"tag":"direct","type":"direct"}],"route":{"final":"direct"}}',
      false,
    ),
    'ambiguous final outbound tag': (
      '{"inbounds":[],"outbounds":[{"tag":"block","type":"block"},{"tag":"block","type":"direct"}],"route":{"final":"block"}}',
      false,
    ),
  };
  for (final entry in blockCases.entries) {
    test('block recognition checks ${entry.key}', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.runner.start(entry.value.$1);
      expect(h.runner.isBlocking, entry.value.$2);
      expect(await h.runner.verifyBlocking(), entry.value.$2);
    });
  }

  test('stop failure propagates without leaving a live process', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.runner.start(_blocking);
    h.failDisable = true;
    await expectLater(h.runner.stop(), throwsStateError);
    expect(h.runner.stage, 'error');
    expect(h.runner.hasRunningProcess, isFalse);
    expect(h.proxy, isTrue);
  });
}
