import 'dart:io';

import 'package:flutter/foundation.dart';

/// Routes Windows user HTTP/HTTPS traffic through the local sing-box mixed inbound.
class WindowsSystemProxy {
  WindowsSystemProxy._();

  static const _regPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  @visibleForTesting
  static Future<ProcessResult> Function(String, List<String>)? runCommand;

  static Future<ProcessResult> _run(List<String> args) async {
    final result =
        await (runCommand?.call('reg', args) ?? Process.run('reg', args));
    if (result.exitCode != 0) {
      throw StateError('reg ${args.first} failed: ${result.stderr}');
    }
    return result;
  }

  static Future<void> enable({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (!Platform.isWindows && runCommand == null) return;
    final server = 'http=$host:$port;https=$host:$port;socks=$host:$port';
    await _reg('ProxyServer', 'REG_SZ', server);
    await _reg('ProxyOverride', 'REG_SZ', '<local>');
    await _reg('ProxyEnable', 'REG_DWORD', '1');
    if (!await isEnabled(host: host, port: port)) {
      throw StateError(
        'Windows system proxy readback did not match requested settings',
      );
    }
    debugPrint('[Windows] system proxy enabled → $host:$port');
  }

  static Future<bool> isEnabled({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (!Platform.isWindows && runCommand == null) return false;
    try {
      if (await _query('ProxyEnable') != '0x1') return false;
      final server = await _query('ProxyServer');
      final entries = <String, String>{};
      for (final entry in server.split(';')) {
        final pair = entry.trim().split('=');
        if (pair.length == 2) entries[pair[0].toLowerCase()] = pair[1];
      }
      return [
        'http',
        'https',
        'socks',
      ].every((scheme) => entries[scheme] == '$host:$port');
    } catch (_) {
      return false;
    }
  }

  static Future<void> disable() async {
    if (!Platform.isWindows && runCommand == null) return;
    await _reg('ProxyEnable', 'REG_DWORD', '0');
    if (await _query('ProxyEnable') != '0x0') {
      throw StateError('Windows system proxy disable could not be verified');
    }
    debugPrint('[Windows] system proxy disabled');
  }

  static Future<String> _query(String name) async {
    final result = await _run(['query', _regPath, '/v', name]);
    final match = RegExp(
      '^\\s*${RegExp.escape(name)}\\s+REG_\\w+\\s+(.*)\$',
      multiLine: true,
    ).firstMatch(result.stdout as String);
    if (match == null) throw StateError('Missing registry value $name');
    return match.group(1)!.trim();
  }

  static Future<void> _reg(String name, String type, String value) async {
    await _run(['add', _regPath, '/v', name, '/t', type, '/d', value, '/f']);
  }
}
