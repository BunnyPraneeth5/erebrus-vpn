import 'dart:io';

import 'package:erebrus_vpn/platform/desktop_system_proxy.dart';
import 'package:erebrus_vpn/platform/linux_system_proxy.dart';
import 'package:erebrus_vpn/platform/macos_system_proxy.dart';
import 'package:erebrus_vpn/platform/windows_system_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProxyCommands {
  final values = <String, String>{};
  final calls = <List<String>>[];
  bool fail = false;
  bool ignoreWrites = false;
  String? failMatch;

  Future<ProcessResult> run(String executable, List<String> args) async {
    calls.add([executable, ...args]);
    if (fail || (failMatch != null && args.join(' ').contains(failMatch!))) {
      return ProcessResult(1, 1, '', 'denied');
    }
    if (executable == 'reg') {
      final name = args[args.indexOf('/v') + 1];
      if (args.first == 'add') {
        if (!ignoreWrites) values[name] = args[args.indexOf('/d') + 1];
        return ProcessResult(1, 0, '', '');
      }
      final type = name == 'ProxyEnable' ? 'REG_DWORD' : 'REG_SZ';
      final value = values[name] ?? '';
      final output = name == 'ProxyEnable' ? '0x$value' : value;
      return ProcessResult(1, 0, '    $name    $type    $output\r\n', '');
    }
    if (executable == 'gsettings') {
      final key = '${args[1]}.${args[2]}';
      if (args.first == 'set') {
        if (!ignoreWrites) values[key] = args[3];
        return ProcessResult(1, 0, '', '');
      }
      final value = values[key] ?? '';
      return ProcessResult(1, 0, args[2] == 'port' ? value : "'$value'", '');
    }
    if (args.first == '-listallnetworkservices') {
      return ProcessResult(
        1,
        0,
        'An asterisk (*) denotes that a network service is disabled.\nWi-Fi\nEthernet\n*Disabled\n',
        '',
      );
    }
    final command = args[0];
    final service = args[1];
    if (command.startsWith('-set')) {
      if (!ignoreWrites) {
        final kind = command.substring(4).replaceFirst('state', '');
        final key = '$service.$kind';
        if (command.endsWith('state')) {
          values['$key.enabled'] = args[2] == 'on' ? 'Yes' : 'No';
        } else {
          values['$key.host'] = args[2];
          values['$key.port'] = args[3];
        }
      }
      return ProcessResult(1, 0, '', '');
    }
    final key = '$service.${command.substring(4)}';
    return ProcessResult(
      1,
      0,
      'Enabled: ${values['$key.enabled'] ?? 'No'}\n'
          'Server: ${values['$key.host'] ?? ''}\n'
          'Port: ${values['$key.port'] ?? '0'}\n',
      '',
    );
  }
}

void main() {
  tearDown(() {
    WindowsSystemProxy.runCommand = null;
    LinuxSystemProxy.runCommand = null;
    MacosSystemProxy.runCommand = null;
  });

  for (final platform in ['windows', 'linux', 'macos']) {
    group(platform, () {
      late _ProxyCommands commands;
      late Future<void> Function() enable;
      late Future<void> Function() disable;
      late Future<bool> Function() enabled;
      setUp(() {
        commands = _ProxyCommands();
        switch (platform) {
          case 'windows':
            WindowsSystemProxy.runCommand = commands.run;
            enable = () =>
                WindowsSystemProxy.enable(host: '127.0.0.2', port: 11080);
            disable = WindowsSystemProxy.disable;
            enabled = () =>
                WindowsSystemProxy.isEnabled(host: '127.0.0.2', port: 11080);
          case 'linux':
            LinuxSystemProxy.runCommand = commands.run;
            enable = () =>
                LinuxSystemProxy.enable(host: '127.0.0.2', port: 11080);
            disable = LinuxSystemProxy.disable;
            enabled = () =>
                LinuxSystemProxy.isEnabled(host: '127.0.0.2', port: 11080);
          case 'macos':
            MacosSystemProxy.runCommand = commands.run;
            enable = () =>
                MacosSystemProxy.enable(host: '127.0.0.2', port: 11080);
            disable = MacosSystemProxy.disable;
            enabled = () =>
                MacosSystemProxy.isEnabled(host: '127.0.0.2', port: 11080);
        }
      });

      test('enable and disable require matching readback', () async {
        expect(await enabled(), isFalse);
        await enable();
        expect(await enabled(), isTrue);
        await disable();
        expect(await enabled(), isFalse);
      });

      test(
        'successful commands with mismatched settings fail enable',
        () async {
          commands.ignoreWrites = true;
          await expectLater(enable(), throwsStateError);
          expect(await enabled(), isFalse);
        },
      );

      test('command failures propagate for enable and disable', () async {
        commands.fail = true;
        await expectLater(enable(), throwsStateError);
        await expectLater(disable(), throwsStateError);
        expect(await enabled(), isFalse);
      });

      test(
        'disable cannot report success if settings remain enabled',
        () async {
          await enable();
          commands.ignoreWrites = true;
          await expectLater(disable(), throwsStateError);
          expect(await enabled(), isTrue);
        },
      );
    });
  }

  test(
    'macOS partial service failure never counts as verified routing',
    () async {
      final commands = _ProxyCommands()..failMatch = 'Ethernet';
      MacosSystemProxy.runCommand = commands.run;
      await expectLater(MacosSystemProxy.enable(), throwsStateError);
      expect(await MacosSystemProxy.isEnabled(), isFalse);
      expect(
        commands.calls.any(
          (args) => args.contains('-setsocksfirewallproxystate'),
        ),
        isTrue,
      );
      expect(
        commands.calls.any(
          (args) => args.contains(
            'An asterisk (*) denotes that a network service is disabled.',
          ),
        ),
        isFalse,
      );
    },
  );

  test(
    'macOS disable continues through every proxy despite individual failure',
    () async {
      final commands = _ProxyCommands();
      MacosSystemProxy.runCommand = commands.run;
      await MacosSystemProxy.enable();
      commands.calls.clear();
      commands.failMatch = '-setwebproxystate Wi-Fi';
      await expectLater(MacosSystemProxy.disable(), throwsStateError);
      expect(
        commands.calls.where((args) => args[1].startsWith('-set')),
        hasLength(6),
      );
    },
  );

  test('missing gsettings propagates rather than claiming success', () async {
    LinuxSystemProxy.runCommand = (exe, args) async =>
        throw ProcessException(exe, args, 'not found');
    await expectLater(
      LinuxSystemProxy.enable(),
      throwsA(isA<ProcessException>()),
    );
    await expectLater(
      LinuxSystemProxy.disable(),
      throwsA(isA<ProcessException>()),
    );
    expect(await LinuxSystemProxy.isEnabled(), isFalse);
  });

  test(
    'desktop facade reads the current platform without invoking actual proxies',
    () async {
      final commands = _ProxyCommands();
      WindowsSystemProxy.runCommand = commands.run;
      LinuxSystemProxy.runCommand = commands.run;
      MacosSystemProxy.runCommand = commands.run;
      if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
      await DesktopSystemProxy.enable();
      expect(await DesktopSystemProxy.isEnabled(), isTrue);
      expect(await DesktopSystemProxy.isEnabled(port: 1), isFalse);
      await DesktopSystemProxy.disable();
      expect(await DesktopSystemProxy.isEnabled(), isFalse);
    },
  );
}
