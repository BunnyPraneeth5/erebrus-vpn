import 'dart:io';

import 'package:flutter/foundation.dart';

/// Routes macOS system HTTP/HTTPS/SOCKS traffic through the local sing-box mixed inbound.
class MacosSystemProxy {
  MacosSystemProxy._();

  @visibleForTesting
  static Future<ProcessResult> Function(String, List<String>)? runCommand;

  static const _proxyKinds = [
    'webproxy',
    'securewebproxy',
    'socksfirewallproxy',
  ];

  static Future<String> _run(List<String> args) async {
    final result =
        await (runCommand?.call('networksetup', args) ??
            Process.run('networksetup', args));
    final output = (result.stdout as String).trim();
    if (result.exitCode != 0 || output.toLowerCase().contains('error')) {
      throw StateError(
        'networksetup ${args.join(' ')} failed: $output ${result.stderr}',
      );
    }
    return output;
  }

  /// All enabled network services from `networksetup -listallnetworkservices`.
  static Future<List<String>> discoverNetworkServices() async {
    final output = await _run(['-listallnetworkservices']);
    final services = output
        .split('\n')
        .map((line) => line.trim())
        .where(
          (line) =>
              line.isNotEmpty &&
              !line.startsWith('*') &&
              !line.toLowerCase().startsWith('an asterisk'),
        )
        .toList();
    if (services.isEmpty) {
      throw StateError('No enabled macOS network services found');
    }
    return services;
  }

  static Future<void> enable({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (!Platform.isMacOS && runCommand == null) return;
    final services = await discoverNetworkServices();
    final failures = <Object>[];
    for (final service in services) {
      for (final kind in _proxyKinds) {
        try {
          await _run(['-set$kind', service, host, '$port']);
          await _run(['-set${kind}state', service, 'on']);
        } catch (e) {
          failures.add(e);
        }
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('macOS proxy enable failed: $failures');
    }
    if (!await isEnabled(host: host, port: port)) {
      throw StateError(
        'macOS system proxy readback did not match requested settings',
      );
    }
    debugPrint('[macOS] system proxy enabled → $host:$port');
  }

  static Future<bool> isEnabled({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (!Platform.isMacOS && runCommand == null) return false;
    try {
      for (final service in await discoverNetworkServices()) {
        for (final kind in _proxyKinds) {
          final values = await _get(service, kind);
          if (values['Enabled'] != 'Yes' ||
              values['Server'] != host ||
              values['Port'] != '$port') {
            return false;
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, String>> _get(String service, String kind) async {
    final output = await _run(['-get$kind', service]);
    final values = <String, String>{};
    for (final line in output.split('\n')) {
      final colon = line.indexOf(':');
      if (colon > 0) {
        values[line.substring(0, colon).trim()] = line
            .substring(colon + 1)
            .trim();
      }
    }
    return values;
  }

  static Future<void> disable() async {
    if (!Platform.isMacOS && runCommand == null) return;
    final failures = <Object>[];
    for (final service in await discoverNetworkServices()) {
      for (final kind in _proxyKinds) {
        try {
          await _run(['-set${kind}state', service, 'off']);
          if ((await _get(service, kind))['Enabled'] != 'No') {
            throw StateError(
              'macOS proxy disable could not be verified: $service $kind',
            );
          }
        } catch (e) {
          failures.add(e);
        }
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('macOS proxy disable failed: $failures');
    }
    debugPrint('[macOS] system HTTP/SOCKS proxy disabled');
  }
}
