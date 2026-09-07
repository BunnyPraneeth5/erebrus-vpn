import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../platform/platform_capabilities.dart';
import '../../settings/app_settings_controller.dart';
import '../../theme/app_theme.dart';
import '../../vpn/vpn_controller.dart';
import '../../vpn/vpn_models.dart';
import 'connect_dial.dart' show fmtData, VpnSafetyStatus, vpnSafetyStatus;
import 'node_display.dart';
import 'sheet_chrome.dart';

/// Presents the network-diagnostics bottom sheet.
Future<void> showDiagnosticsSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (_) =>
        const SheetFrame(maxHeightFactor: 0.8, child: _DiagnosticsSheet()),
  );
}

class _DiagnosticsSheet extends StatelessWidget {
  const _DiagnosticsSheet();

  @override
  Widget build(BuildContext context) {
    final vpn = Get.find<VpnController>();
    final settings = Get.isRegistered<AppSettingsController>()
        ? Get.find<AppSettingsController>()
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
          child: Row(
            children: [
              const Icon(Icons.show_chart, size: 20, color: AppColors.accent),
              const SizedBox(width: 10),
              Text(
                'Network diagnostics',
                style: grotesk(size: 18, weight: FontWeight.w600),
              ),
              const Spacer(),
              SheetCloseButton(onTap: () => Navigator.of(context).pop()),
            ],
          ),
        ),
        Flexible(
          child: Obx(() {
            final status = vpnSafetyStatus(vpn);
            final connected = status.isProtected;
            final proxy = PlatformCapabilities.usesDesktopVpnRunner;
            final node = vpn.selectedNode.value;
            final d = NodeDisplay.of(node);
            final stats = vpn.stats.value;
            final mode = vpn.mode.value;
            final transport = vpn.activeTransport.value;
            final protocolLabel = switch (mode) {
              ConnectMode.auto => 'Auto',
              ConnectMode.stealth => 'Stealth',
              ConnectMode.wireguard => 'WireGuard',
            };

            final rows = connected
                ? <_DiagRow>[
                    _DiagRow.text('Connection', d.name, AppColors.textPrimary),
                    _DiagRow.text('Protocol', protocolLabel, AppColors.accent),
                    _DiagRow.text(
                      'Transport',
                      transport?.label ?? 'Unknown',
                      transport == null
                          ? AppColors.warn
                          : AppColors.textSecondary,
                    ),
                    _DiagRow.text(
                      'Network',
                      '${d.network} · ${d.location}',
                      AppColors.textSecondary,
                    ),
                    _DiagRow.pair(
                      'Throughput',
                      fmtData(stats.rxBytes),
                      fmtData(stats.txBytes),
                      AppColors.textSecondary,
                    ),
                    _DiagRow.pair(
                      'Rate',
                      _rate(stats.downlinkBps),
                      _rate(stats.uplinkBps),
                      AppColors.textSecondary,
                    ),
                    _DiagRow.text(
                      proxy ? 'Proxy DNS' : 'DNS',
                      proxy
                          ? 'Proxied destinations only'
                          : 'Tunnel DNS → ${vpn.selectedNode.value != null ? "node resolver" : "upstream"}',
                      AppColors.success,
                    ),
                    const _DiagRow.text('MTU', '1280', AppColors.textSecondary),
                  ]
                : <_DiagRow>[
                    _DiagRow.text('Connection', status.label, status.color),
                    _DiagRow.text(
                      'Protocol',
                      protocolLabel,
                      AppColors.textSecondary,
                    ),
                    _DiagRow.text(
                      'Nearest node',
                      d.name,
                      AppColors.textSecondary,
                    ),
                    const _DiagRow.text('DNS', 'Not verified', AppColors.warn),
                  ];

            return ListView(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 30),
              shrinkWrap: true,
              children: [
                _Banner(status: status, proxyScoped: proxy),
                if (proxy)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      'Only traffic using the system proxy is covered; apps that bypass it are not blocked.',
                      style: grotesk(
                        size: 12,
                        weight: FontWeight.w400,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                for (final r in rows) _DiagRowWidget(row: r),
                _DiagRowWidget(
                  row: _DiagRow.text(
                    'Kill switch',
                    vpn.killSwitchEngaging.value
                        ? 'Verifying enforcement…'
                        : vpn.killSwitchBlocking.value
                        ? status.label
                        : (settings?.killSwitchEnabled.value ?? true)
                        ? 'Enabled on unexpected drop'
                        : 'Off',
                    vpn.killSwitchBlocking.value
                        ? AppColors.danger
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            );
          }),
        ),
      ],
    );
  }

  String _rate(int bps) {
    if (bps >= 1000000) return '${(bps / 1000000).toStringAsFixed(1)} MB/s';
    if (bps >= 1000) return '${(bps / 1000).toStringAsFixed(0)} KB/s';
    return '$bps B/s';
  }
}

class _DiagRow {
  const _DiagRow._({
    required this.label,
    this.value,
    this.down,
    this.up,
    required this.color,
  });
  const _DiagRow.text(String label, String value, Color color)
    : this._(label: label, value: value, color: color);
  const _DiagRow.pair(String label, String down, String up, Color color)
    : this._(label: label, down: down, up: up, color: color);

  final String label;
  final String? value;
  final String? down;
  final String? up;
  final Color color;

  bool get isPair => down != null && up != null;
}

class _DiagRowWidget extends StatelessWidget {
  const _DiagRowWidget({required this.row});
  final _DiagRow row;

  static const _labelFlex = 2;
  static const _valueFlex = 3;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.strokeSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: _labelFlex,
            child: Text(
              row.label,
              style: grotesk(
                size: 13.5,
                weight: FontWeight.w400,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: _valueFlex,
            child: row.isPair
                ? _PairValue(down: row.down!, up: row.up!, color: row.color)
                : Text(
                    row.value ?? '—',
                    textAlign: TextAlign.right,
                    style: mono(
                      size: 12.5,
                      weight: FontWeight.w500,
                      color: row.color,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PairValue extends StatelessWidget {
  const _PairValue({required this.down, required this.up, required this.color});
  final String down;
  final String up;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _PairStat(arrow: '↓', value: down, color: color),
        const SizedBox(width: 18),
        _PairStat(arrow: '↑', value: up, color: color),
      ],
    );
  }
}

class _PairStat extends StatelessWidget {
  const _PairStat({
    required this.arrow,
    required this.value,
    required this.color,
  });
  final String arrow;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          arrow,
          style: mono(
            size: 12,
            weight: FontWeight.w500,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 64),
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: mono(size: 12.5, weight: FontWeight.w500, color: color),
          ),
        ),
      ],
    );
  }
}

String diagnosticsSafetyLabel(
  VpnSafetyStatus status, {
  required bool proxyScoped,
}) {
  if (!status.isProtected) return status.label;
  return proxyScoped
      ? 'PROXY CONNECTED · PROXIED TRAFFIC ENCRYPTED'
      : 'TUNNEL ACTIVE · TRAFFIC ENCRYPTED';
}

class _Banner extends StatelessWidget {
  const _Banner({required this.status, required this.proxyScoped});
  final VpnSafetyStatus status;
  final bool proxyScoped;
  @override
  Widget build(BuildContext context) {
    final connected = status.isProtected;
    final color = status.color;
    final label = diagnosticsSafetyLabel(status, proxyScoped: proxyScoped);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          connected
              ? _BlinkDot(color: color)
              : Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              label,
              style: mono(
                size: 12.5,
                weight: FontWeight.w600,
                color: color,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlinkDot extends StatefulWidget {
  const _BlinkDot({required this.color});
  final Color color;
  @override
  State<_BlinkDot> createState() => _BlinkDotState();
}

class _BlinkDotState extends State<_BlinkDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.25).animate(_c),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
