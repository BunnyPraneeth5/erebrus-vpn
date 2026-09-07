import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/desktop_system_proxy.dart';
import '../platform/macos_privileged_process.dart';
import '../platform/platform_capabilities.dart';
import 'clash_stats_poller.dart';
import 'singbox_engine.dart';
import 'vpn_models.dart';

/// Runs the bundled sing-box CLI as a subprocess on macOS / Windows / Linux.
///
/// On macOS, unsigned desktop builds use **proxy-only** (mixed inbound on
/// 127.0.0.1:10808 + system HTTP/SOCKS via `networksetup`). Configs that still
/// include a TUN inbound can be started via an administrator prompt when needed.
class SingboxDesktopRunner {
  SingboxDesktopRunner._();

  @visibleForTesting
  SingboxDesktopRunner.testing({
    required Future<String?> Function() findBinary,
    required Future<String> Function(String) writeConfig,
    required Future<Process> Function(String, String) startProcess,
    required Future<bool> Function() endpointReady,
    required Future<void> Function() enableProxy,
    required Future<void> Function() disableProxy,
    required Future<bool> Function() proxyEnabled,
  }) : _findBinaryOverride = findBinary,
       _writeConfigOverride = writeConfig,
       _startProcessOverride = startProcess,
       _endpointReadyOverride = endpointReady,
       _enableProxyOverride = enableProxy,
       _disableProxyOverride = disableProxy,
       _proxyEnabledOverride = proxyEnabled,
       _testing = true;

  static final instance = SingboxDesktopRunner._();

  Future<String?> Function()? _findBinaryOverride;
  Future<String> Function(String)? _writeConfigOverride;
  Future<Process> Function(String, String)? _startProcessOverride;
  Future<bool> Function()? _endpointReadyOverride;
  Future<void> Function()? _enableProxyOverride;
  Future<void> Function()? _disableProxyOverride;
  Future<bool> Function()? _proxyEnabledOverride;
  bool _testing = false;
  Future<void> _operations = Future<void>.value();
  Future<void>? _exitCleanup;
  final List<StreamSubscription<String>> _processLogs = [];
  Process? _stoppingProcess;
  int _generation = 0;
  bool _routingReady = false;
  bool _blockingConfig = false;
  bool _failed = false;

  Process? _process;
  bool _privilegedMacos = false;
  int? _privilegedPid;
  String? _workDir;
  String? _pidPath;
  String? _logPath;
  StreamSubscription<void>? _logTailer;

  String _stage = 'disconnected';
  final _stageCtrl = StreamController<VpnStage>.broadcast();
  final _statsPoller = ClashStatsPoller();
  StreamSubscription<VpnStats>? _statsSub;
  String? _lastError;
  String? _clashApiSecret;

  Stream<VpnStage> get onStage => _stageCtrl.stream;
  Stream<VpnStats> get onStats => _statsPoller.stream;
  String get stage => _stage;
  String? get lastError => _lastError;

  bool get hasRunningProcess => _process != null || _privilegedMacos;
  bool get isBlocking =>
      _blockingConfig && _routingReady && hasRunningProcess && !_failed;

  Future<bool> verifyBlocking() async {
    final generation = _generation;
    if (!isBlocking || !_routingReady) return false;
    try {
      final proxy = await _proxyEnabled();
      final ready = proxy && await _endpointReady();
      return generation == _generation && isBlocking && _routingReady && ready;
    } catch (_) {
      return false;
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _enableProxy() =>
      _enableProxyOverride?.call() ??
      DesktopSystemProxy.enable(
        host: SingboxConfigBuilder.localProxyHost,
        port: SingboxConfigBuilder.localProxyPort,
      );

  Future<void> _disableProxy() =>
      _disableProxyOverride?.call() ?? DesktopSystemProxy.disable();

  Future<bool> _proxyEnabled() =>
      _proxyEnabledOverride?.call() ??
      DesktopSystemProxy.isEnabled(
        host: SingboxConfigBuilder.localProxyHost,
        port: SingboxConfigBuilder.localProxyPort,
      );

  Future<String?> findBinary() async {
    if (_findBinaryOverride != null) return _findBinaryOverride!();
    final exe = Platform.resolvedExecutable;
    final exeDir = p.dirname(exe);
    final name = Platform.isWindows ? 'sing-box.exe' : 'sing-box';
    final cwd = Directory.current.path;

    final candidates = <String>[
      if (Platform.environment['EREBRUS_SINGBOX'] != null)
        Platform.environment['EREBRUS_SINGBOX']!,
      if (Platform.isMacOS) p.join(exeDir, '..', 'Resources', name),
      p.join(exeDir, name),
      p.join(exeDir, 'data', name),
      p.join(cwd, 'bin', 'sing-box', 'darwin-arm64', name),
      p.join(cwd, 'bin', 'sing-box', 'darwin-amd64', name),
      p.join(cwd, 'bin', 'sing-box', 'linux-amd64', name),
      p.join(cwd, 'bin', 'sing-box', 'windows-amd64', name),
      p.join(cwd, 'bin', name),
      p.join(cwd, 'native', name),
    ];

    for (final c in candidates) {
      final resolved = p.normalize(c);
      if (await File(resolved).exists()) {
        debugPrint('[DesktopVPN] sing-box at $resolved');
        return resolved;
      }
    }
    debugPrint(
      '[DesktopVPN] sing-box not found (searched ${candidates.length} paths)',
    );
    return null;
  }

  Future<bool> prepare() async {
    final binary = await findBinary();
    if (binary != null) return true;
    _lastError =
        'sing-box binary missing — install the bundled CLI for ${PlatformCapabilities.platformLabel}';
    return false;
  }

  Future<void> start(
    String configJson, {
    String profileName = 'Erebrus',
    bool preserveProxy = false,
  }) => _serialize(() async {
    try {
      await _stop(preserveProxy: preserveProxy);
      _generation++;
      _failed = false;
      _lastError = null;
      _routingReady = false;
      _blockingConfig = _configBlocks(configJson);
      _setStage('connecting');
      final binary = await findBinary();
      if (binary == null) {
        throw StateError(
          'sing-box binary missing — install the bundled CLI for ${PlatformCapabilities.platformLabel}',
        );
      }
      final String configPath;
      if (_writeConfigOverride != null) {
        configPath = await _writeConfigOverride!(configJson);
        _workDir = p.dirname(configPath);
      } else {
        _workDir = await _ensureConfigDir();
        configPath = p.join(_workDir!, 'config.json');
        await File(configPath).writeAsString(configJson);
        await _restrictConfigPermissions(configPath);
      }
      _clashApiSecret = _extractClashApiSecret(configJson);
      _statsPoller.secret = _clashApiSecret;
      _logPath = p.join(_workDir!, 'singbox.log');
      _pidPath = p.join(_workDir!, 'singbox.pid');
      debugPrint(
        '[DesktopVPN] starting $binary ($profileName, ${configJson.length} bytes)',
      );
      if (!_testing && Platform.isMacOS && _configUsesTun(configJson)) {
        if (await _startPrivilegedMacos(binary, configPath)) {
          await _awaitReady(privileged: true);
          return;
        }
        debugPrint(
          '[DesktopVPN] admin declined or TUN start failed — falling back to proxy mode',
        );
        await File(configPath).writeAsString(_stripTunInbound(configJson));
        _lastError = null;
      }
      await _startSubprocess(binary, configPath);
      await _awaitReady(privileged: false);
    } catch (e) {
      _lastError ??= e.toString();
      _failed = true;
      _routingReady = false;
      _setStage('error');
      try {
        await _stop(preserveProxy: true);
      } catch (cleanupError) {
        _lastError = '$_lastError; cleanup failed: $cleanupError';
      }
      _setStage('error');
      rethrow;
    }
  });

  Future<bool> _startPrivilegedMacos(String binary, String configPath) async {
    final q = MacosPrivilegedProcess.shellQuote;
    final cmd =
        'nohup ${q(binary)} run -c ${q(configPath)} --disable-color >> ${q(_logPath!)} 2>&1 & echo \$! > ${q(_pidPath!)}';
    debugPrint('[DesktopVPN] requesting administrator access for TUN…');
    final ok = await MacosPrivilegedProcess.runShellScript(cmd);
    if (!ok) {
      _lastError = 'Administrator permission required for system VPN (TUN)';
      return false;
    }
    _privilegedMacos = true;
    _privilegedPid = int.tryParse(
      (await File(_pidPath!).readAsString()).trim(),
    );
    if (_privilegedPid == null || _privilegedPid! <= 0) {
      throw StateError('Could not identify privileged sing-box process');
    }
    _process = null;
    _startLogTail();
    return true;
  }

  Future<void> _startSubprocess(String binary, String configPath) async {
    final generation = _generation;
    final process =
        await (_startProcessOverride?.call(binary, configPath) ??
            Process.start(
              binary,
              ['run', '-c', configPath, '--disable-color'],
              mode: ProcessStartMode.normal,
              workingDirectory: p.dirname(binary),
            ));
    _process = process;
    bool current() => generation == _generation && identical(_process, process);
    void handleLine(String line) {
      if (!current() || identical(_stoppingProcess, process)) return;
      _handleLine(line);
    }

    for (final stream in [process.stdout, process.stderr]) {
      _processLogs.add(
        stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              handleLine,
              onError: (Object error) {
                if (current() && !identical(_stoppingProcess, process)) {
                  _invalidate(error.toString());
                }
              },
            ),
      );
    }
    _exitCleanup = process.exitCode.then((code) async {
      if (!current()) return;
      final expected = identical(_stoppingProcess, process);
      _process = null;
      _routingReady = false;
      _stopStats();
      if (expected) {
        _setStage('disconnecting');
      } else {
        _invalidate('sing-box exited unexpectedly ($code)');
      }
      final logs = List<StreamSubscription<String>>.from(_processLogs);
      _processLogs.clear();
      for (final sub in logs) {
        await sub.cancel();
      }
    });
  }

  void _invalidate(String error) {
    _lastError = error;
    _failed = true;
    _routingReady = false;
    _stopStats();
    _setStage('error');
  }

  void _handleLine(String line) {
    debugPrint('[sing-box] $line');
    if (line.contains('FATAL')) {
      _invalidate(line);
    } else if (line.contains('ERROR') && !_failed) {
      _lastError = line;
    }
  }

  Future<void> _awaitReady({required bool privileged}) async {
    final generation = _generation;
    var ready = false;
    for (var i = 0; i < 60; i++) {
      if (_failed || !hasRunningProcess) break;
      if (await _endpointReady()) {
        ready = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!ready || _failed || !hasRunningProcess || generation != _generation) {
      throw StateError(
        _lastError ??
            (privileged
                ? 'sing-box did not start after admin elevation'
                : 'sing-box did not start — check logs for TUN/permission errors'),
      );
    }
    await _enableProxy();
    final routing = await _proxyEnabled();
    final endpoint = routing && await _endpointReady();
    if (!endpoint ||
        _failed ||
        !hasRunningProcess ||
        generation != _generation) {
      throw StateError(_lastError ?? 'sing-box routing could not be verified');
    }
    _routingReady = true;
    _setStage('connected');
    _startStats();
  }

  Future<bool> _endpointReady() async {
    if (_endpointReadyOverride != null) return _endpointReadyOverride!();
    if (_privilegedMacos && !await _privilegedProcessAlive()) return false;
    try {
      final socket = await Socket.connect(
        SingboxConfigBuilder.localProxyHost,
        SingboxConfigBuilder.localProxyPort,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _privilegedProcessAlive() async {
    final generation = _generation;
    if (!_privilegedMacos) return false;
    try {
      final pid = _privilegedPid;
      if (pid != null && pid > 0) {
        final result = await Process.run('ps', ['-p', '$pid', '-o', 'stat=']);
        final state = (result.stdout as String).trim();
        if (generation != _generation || !_privilegedMacos) return false;
        if (result.exitCode == 0 &&
            state.isNotEmpty &&
            !state.startsWith('Z')) {
          return true;
        }
        if (result.exitCode != 0 && result.exitCode != 1) {
          throw StateError('ps failed: ${result.stderr}');
        }
      }
    } catch (e) {
      if (generation == _generation && _privilegedMacos) {
        _invalidate('Could not verify privileged sing-box process: $e');
      }
      return false;
    }
    if (generation == _generation && _privilegedMacos) {
      _privilegedMacos = false;
      _logTailer?.cancel();
      _logTailer = null;
      _invalidate('sing-box privileged process exited unexpectedly');
    }
    return false;
  }

  void _startLogTail() {
    _logTailer?.cancel();
    final logFile = _logPath;
    if (logFile == null) return;
    var offset = 0;
    final generation = _generation;
    _logTailer = Stream.periodic(const Duration(milliseconds: 400)).listen((
      _,
    ) async {
      try {
        if (generation != _generation || !await _privilegedProcessAlive()) {
          return;
        }
        final f = File(logFile);
        if (!await f.exists()) return;
        final len = await f.length();
        if (len <= offset) return;
        final chunk = await f
            .openRead(offset, len)
            .transform(utf8.decoder)
            .join();
        if (generation != _generation || !_privilegedMacos) return;
        offset = len;
        for (final line in chunk.split('\n')) {
          if (line.isNotEmpty) _handleLine(line);
        }
      } catch (_) {}
    });
  }

  Future<void> stop({bool preserveProxy = false}) => _serialize(() async {
    try {
      await _stop(preserveProxy: preserveProxy);
    } catch (e) {
      _invalidate('sing-box stop failed: $e');
      rethrow;
    }
  });

  Future<void> _stop({required bool preserveProxy}) async {
    _stoppingProcess = _process;
    _routingReady = false;
    _setStage('disconnecting');
    _stopStats();
    await _logTailer?.cancel();
    _logTailer = null;
    if (_privilegedMacos) {
      final q = MacosPrivilegedProcess.shellQuote;
      final pidFile = _pidPath;
      final pid = _privilegedPid;
      if (pid == null || pid <= 0 || pidFile == null) {
        throw StateError(
          'Cannot stop an unidentified privileged sing-box process',
        );
      }
      _privilegedMacos = false;
      final stopped = await MacosPrivilegedProcess.runShellScript(
        'kill $pid 2>/dev/null; i=0; '
        'while kill -0 $pid 2>/dev/null; do '
        'i=\$((i + 1)); '
        'if [ "\$i" -eq 50 ]; then kill -9 $pid 2>/dev/null; fi; '
        'if [ "\$i" -ge 100 ]; then exit 1; fi; sleep 0.1; done; '
        'rm -f ${q(pidFile)}',
      );
      if (!stopped) {
        _privilegedMacos = true;
        throw StateError('Could not stop privileged sing-box process');
      }
      _privilegedPid = null;
    }
    final process = _process;
    final cleanup = _exitCleanup;
    if (process != null) {
      _stoppingProcess = process;
      process.kill(ProcessSignal.sigterm);
      try {
        await cleanup?.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await cleanup?.timeout(const Duration(seconds: 5));
      }
    } else {
      await cleanup;
    }
    _exitCleanup = null;
    _stoppingProcess = null;
    _generation++;
    if (!preserveProxy) await _disableProxy();
    _setStage('disconnected');
  }

  bool _configBlocks(String configJson) {
    try {
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final route = config['route'] as Map?;
      final finalTag = route?['final'];
      final rules = route?['rules'] as List? ?? const [];
      if (rules.isNotEmpty) return false;
      if (finalTag is! String || finalTag.isEmpty) return false;
      final outbounds = config['outbounds'] as List? ?? const [];
      final targets = outbounds
          .where((outbound) => outbound is Map && outbound['tag'] == finalTag)
          .toList();
      return targets.length == 1 && (targets.single as Map)['type'] == 'block';
    } catch (_) {
      return false;
    }
  }

  String? _extractClashApiSecret(String configJson) {
    try {
      final m = jsonDecode(configJson) as Map<String, dynamic>;
      final clashApi = (m['experimental'] as Map?)?['clash_api'] as Map?;
      final secret = clashApi?['secret'] as String?;
      if (secret != null && secret.isNotEmpty) return secret;
    } catch (_) {}
    return null;
  }

  Future<String> _ensureConfigDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'singbox'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> _restrictConfigPermissions(String configPath) async {
    try {
      if (Platform.isWindows) {
        // Remove inherited ACEs and allow only the current user.
        final user =
            Platform.environment['USER'] ?? Platform.environment['USERNAME'];
        if (user != null && user.isNotEmpty) {
          await Process.run('icacls', [
            configPath,
            '/inheritance:r',
            '/grant:r',
            '$user:(R,W)',
          ]);
        }
      } else if (Platform.isMacOS || Platform.isLinux) {
        await Process.run('chmod', ['600', configPath]);
      }
    } catch (e) {
      debugPrint('[DesktopVPN] could not restrict config permissions: $e');
    }
  }

  bool _configUsesTun(String configJson) {
    try {
      final m = jsonDecode(configJson) as Map<String, dynamic>;
      final inbounds = (m['inbounds'] as List?) ?? const [];
      return inbounds.any((e) => (e as Map)['type'] == 'tun');
    } catch (_) {
      return true;
    }
  }

  String _stripTunInbound(String configJson) {
    final m = jsonDecode(configJson) as Map<String, dynamic>;
    final inbounds = ((m['inbounds'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((e) => e['type'] != 'tun')
        .toList();
    m['inbounds'] = inbounds;
    return const JsonEncoder.withIndent('  ').convert(m);
  }

  void _setStage(String value) {
    _stage = value;
    if (!_stageCtrl.isClosed) {
      _stageCtrl.add(switch (value) {
        'connecting' => VpnStage.connecting,
        'connected' => VpnStage.connected,
        'disconnecting' => VpnStage.disconnecting,
        'error' => VpnStage.error,
        _ => VpnStage.disconnected,
      });
    }
  }

  void _startStats() {
    if (_testing) return;
    _stopStats();
    unawaited(_statsPoller.start());
  }

  void _stopStats() {
    unawaited(_statsPoller.stop());
    _statsSub?.cancel();
    _statsSub = null;
  }

  void dispose() {
    _stopStats();
    _logTailer?.cancel();
    _statsPoller.dispose();
    _stageCtrl.close();
  }
}
