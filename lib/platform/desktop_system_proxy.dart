import 'dart:io';

import 'linux_system_proxy.dart';
import 'macos_system_proxy.dart';
import 'windows_system_proxy.dart';

/// Enables system HTTP/HTTPS/SOCKS proxy on desktop so in-app WebView and
/// system browsers route through sing-box's local mixed inbound.
class DesktopSystemProxy {
  DesktopSystemProxy._();

  static Future<void> enable({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (Platform.isMacOS) {
      await MacosSystemProxy.enable(host: host, port: port);
      return;
    }
    if (Platform.isWindows) {
      await WindowsSystemProxy.enable(host: host, port: port);
      return;
    }
    if (Platform.isLinux) {
      await LinuxSystemProxy.enable(host: host, port: port);
      return;
    }
    throw UnsupportedError('System proxy is only supported on desktop');
  }

  static Future<bool> isEnabled({
    String host = '127.0.0.1',
    int port = 10808,
  }) async {
    if (Platform.isMacOS) {
      return MacosSystemProxy.isEnabled(host: host, port: port);
    }
    if (Platform.isWindows) {
      return WindowsSystemProxy.isEnabled(host: host, port: port);
    }
    if (Platform.isLinux) {
      return LinuxSystemProxy.isEnabled(host: host, port: port);
    }
    return false;
  }

  static Future<void> disable() async {
    if (Platform.isMacOS) {
      await MacosSystemProxy.disable();
      return;
    }
    if (Platform.isWindows) {
      await WindowsSystemProxy.disable();
      return;
    }
    if (Platform.isLinux) {
      await LinuxSystemProxy.disable();
    }
  }
}
