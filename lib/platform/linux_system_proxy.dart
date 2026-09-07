import 'dart:io';

import 'package:flutter/foundation.dart';

/// Routes Linux desktop HTTP/HTTPS/SOCKS through gsettings (GNOME / most GTK desktops).
class LinuxSystemProxy {
  LinuxSystemProxy._();

  @visibleForTesting
  static Future<ProcessResult> Function(String, List<String>)? runCommand;

  static Future<String> _run(List<String> args) async {
    final result =
        await (runCommand?.call('gsettings', args) ??
            Process.run('gsettings', args));
    if (result.exitCode != 0) {
      throw StateError('gsettings ${args.join(' ')} failed: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  static Future<void> enable({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (!Platform.isLinux && runCommand == null) return;
    for (final scheme in ['http', 'https', 'socks']) {
      await _run(['set', 'org.gnome.system.proxy.$scheme', 'host', host]);
      await _run(['set', 'org.gnome.system.proxy.$scheme', 'port', '$port']);
    }
    await _run(['set', 'org.gnome.system.proxy', 'mode', 'manual']);
    if (!await isEnabled(host: host, port: port)) {
      throw StateError(
        'Linux system proxy readback did not match requested settings',
      );
    }
    debugPrint('[Linux] system proxy enabled → $host:$port');
  }

  static Future<bool> isEnabled({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (!Platform.isLinux && runCommand == null) return false;
    try {
      if (await _get('org.gnome.system.proxy', 'mode') != 'manual') {
        return false;
      }
      for (final scheme in ['http', 'https', 'socks']) {
        final schema = 'org.gnome.system.proxy.$scheme';
        if (await _get(schema, 'host') != host ||
            await _get(schema, 'port') != '$port') {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _get(String schema, String key) async {
    final value = await _run(['get', schema, key]);
    if (value.length >= 2 &&
        ((value.startsWith("'") && value.endsWith("'")) ||
            (value.startsWith('"') && value.endsWith('"')))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  static Future<void> disable() async {
    if (!Platform.isLinux && runCommand == null) return;
    await _run(['set', 'org.gnome.system.proxy', 'mode', 'none']);
    if (await _get('org.gnome.system.proxy', 'mode') != 'none') {
      throw StateError('Linux system proxy disable could not be verified');
    }
    debugPrint('[Linux] system proxy disabled');
  }
}
