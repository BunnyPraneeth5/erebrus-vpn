import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../auth/wallet_auth_controller.dart';
import '../../settings/app_settings_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/premium_widgets.dart';
import '../../vpn/gateway_controller.dart';
import '../../vpn/singbox_engine.dart';
import '../../vpn/vpn_controller.dart';
import '../../vpn/vpn_models.dart';
import 'connect_dial.dart';
import 'node_display.dart';
import 'node_ui_widgets.dart';

/// The dVPN tab — connect/disconnect the tunnel, pick protocol, watch live
/// stats, and open diagnostics / the server picker. Binds to [VpnController];
/// the dial reflects the real tunnel stage and the readout shows real
/// throughput. Sheets are hosted by the shell via the callbacks.
class ConnectView extends StatefulWidget {
  const ConnectView({
    super.key,
    this.onOpenServers,
    this.onOpenDiagnostics,
    this.onGoSettings,
  });

  final VoidCallback? onOpenServers;
  final VoidCallback? onOpenDiagnostics;
  final VoidCallback? onGoSettings;

  @override
  State<ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends State<ConnectView> {
  VpnController get _c => Get.find<VpnController>();
  WalletAuthController? get _auth => Get.isRegistered<WalletAuthController>()
      ? Get.find<WalletAuthController>()
      : null;

  Timer? _ticker;
  final _elapsed = Duration.zero.obs;
  Worker? _stageWorker;

  @override
  void initState() {
    super.initState();
    _stageWorker = ever<VpnStage>(_c.stage, _onStage);
    if (_c.isConnected) _startTimer();
  }

  void _onStage(VpnStage s) {
    if (s == VpnStage.connected) {
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  void _startTimer() {
    _tick();
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    // Base the elapsed time on the controller's connect timestamp so it stays
    // accurate even if this view is rebuilt mid-session.
    final since = _c.connectedSince.value;
    _elapsed.value = since == null
        ? Duration.zero
        : DateTime.now().difference(since);
  }

  void _stopTimer() {
    _ticker?.cancel();
    _ticker = null;
    _elapsed.value = Duration.zero;
  }

  @override
  void dispose() {
    _stageWorker?.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  void _onDialTap() {
    // Tapping the dial mid-connect aborts the attempt (Stealth can take a while).
    if (_c.stage.value == VpnStage.connecting) {
      _c.cancelConnect();
      return;
    }
    final node = _c.selectedNode.value;
    if (node != null && !node.canAcceptClients) {
      _c.error.value = 'Selected server is at capacity — pick another node';
      return;
    }
    final auth = _auth;
    if (auth != null && !auth.canConnectVpn(node)) {
      final ent = auth.entitlement.value;
      _c.error.value = node?.isPrivateAccess == true && ent.orgMember == false
          ? 'Accept your workspace invite to connect to private org nodes'
          : ent.trialConsumed
          ? 'Trial ended — renew on erebrus.io with the same wallet'
          : 'Start your free trial in Settings to connect';
      widget.onGoSettings?.call();
      return;
    }
    _c.error.value = null;
    _c.toggle();
  }

  /// What the dial says while the tunnel is being established.
  String? _connectingLabel(VpnStage stage) {
    if (stage == VpnStage.disconnecting) return 'STOPPING…';
    if (stage != VpnStage.connecting) return null;
    return switch (_c.activeTransport.value) {
      null => 'SECURING…',
      Transport.wireguard => 'WIREGUARD HANDSHAKE…',
      Transport.vlessReality => 'STEALTH HANDSHAKE…',
      Transport.hysteria2 => 'QUIC HANDSHAKE…',
    };
  }

  void _setProtocol(ConnectMode m) {
    _c.setMode(m);
    if (Get.isRegistered<AppSettingsController>()) {
      Get.find<AppSettingsController>().setDefaultProtocol(m);
    }
  }

  /// Highlights the transport in use while connected/connecting; otherwise the
  /// user's saved preference (Auto / WireGuard / Stealth).
  ConnectMode _displayMode(VpnController c) {
    final stage = c.stage.value;
    final transport = c.activeTransport.value;
    if ((stage == VpnStage.connected || stage == VpnStage.connecting) &&
        transport != null) {
      return transport.connectMode;
    }
    return c.mode.value;
  }

  String _protocolBlurb(VpnController c) {
    final stage = c.stage.value;
    final transport = c.activeTransport.value;
    if (c.isProtected && transport != null) {
      return 'In use · ${transport.label}';
    }
    if (stage == VpnStage.connecting && transport != null) {
      return transport.connectMode.blurb;
    }
    return c.mode.value.blurb;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // header
              Obx(
                () => _StatusHeader(
                  status: vpnSafetyStatus(_c),
                  onDiagnostics: widget.onOpenDiagnostics,
                ),
              ),
              const SizedBox(height: 16),
              // protocol segmented
              Obx(
                () => _ProtocolSegment(
                  mode: _displayMode(_c),
                  enabled:
                      !_c.isConnected &&
                      !_c.isBusy &&
                      !_c.killSwitchBlocking.value,
                  onSelect: _setProtocol,
                ),
              ),
              const SizedBox(height: 8),
              Obx(
                () => Center(
                  child: Text(
                    _protocolBlurb(_c),
                    textAlign: TextAlign.center,
                    style: mono(
                      size: 11,
                      weight: FontWeight.w400,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ),
              // dial
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      physics: const ClampingScrollPhysics(),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Center(
                          child: Obx(() {
                            final stage = _c.stage.value;
                            final status = vpnSafetyStatus(_c);
                            final err = _c.error.value;
                            final transport = _c.activeTransport.value;
                            final stealthWait =
                                stage == VpnStage.connecting &&
                                transport != null &&
                                transport != Transport.wireguard;
                            final stalled =
                                stage == VpnStage.connected &&
                                !_c.tunnelHealthy.value;
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                RepaintBoundary(
                                  child: ConnectDial(
                                    stage: stage,
                                    status: status,
                                    durationLabel: fmtDuration(_elapsed.value),
                                    connectingLabel: _connectingLabel(stage),
                                    // Connecting stays tappable: it cancels. Only a
                                    // disconnect in flight is uninterruptible.
                                    onTap: stage == VpnStage.disconnecting
                                        ? null
                                        : _onDialTap,
                                  ),
                                ),
                                if (stealthWait) ...[
                                  const SizedBox(height: 14),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Text(
                                      'Disguising traffic — this can take up to a minute on strict networks.',
                                      textAlign: TextAlign.center,
                                      style: grotesk(
                                        size: 12.5,
                                        weight: FontWeight.w500,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                                if (stalled) ...[
                                  const SizedBox(height: 14),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Text(
                                      'Connection health checks are failing — tap the dial to disconnect, then reconnect (try Stealth).',
                                      textAlign: TextAlign.center,
                                      style: grotesk(
                                        size: 12.5,
                                        weight: FontWeight.w500,
                                        color: AppColors.danger,
                                      ),
                                    ),
                                  ),
                                ],
                                if (err != null && err.isNotEmpty) ...[
                                  const SizedBox(height: 14),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Text(
                                      err,
                                      textAlign: TextAlign.center,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: grotesk(
                                        size: 12.5,
                                        weight: FontWeight.w500,
                                        color: AppColors.danger,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            );
                          }),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // data readout
              Obx(
                () => _DataReadout(
                  stats: _c.stats.value,
                  connected: _c.isConnected,
                ),
              ),
              const SizedBox(height: 14),
              // server card
              Obx(() {
                final gw = Get.find<GatewayController>();
                final node = _c.selectedNode.value;
                final registryEmpty = gw.nodes.isEmpty;
                final display = registryEmpty
                    ? NodeDisplay.placeholder(
                        registryError: gw.error.value != null,
                      )
                    : NodeDisplay.of(node, showActivity: true);
                // Reflect the selected node's source (public vs its org/workspace).
                final org = node?.org;
                final showScope = gw.orgs.isNotEmpty || org != null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showScope) ...[
                      _ScopeStrip(
                        label: org?.name ?? 'Public network',
                        isOrg: org != null,
                        verified: org?.verified ?? false,
                        onTap: widget.onOpenServers,
                      ),
                      const SizedBox(height: 8),
                    ],
                    _ServerCard(
                      display: display,
                      egressIp: _c.egressIp.value,
                      egressLoading: _c.egressIpLoading.value,
                      protocol:
                          _c.activeTransport.value?.label ??
                          _c.mode.value.label,
                      connected: _c.isProtected,
                      onTap: widget.onOpenServers,
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.status, this.onDiagnostics});
  final VpnSafetyStatus status;
  final VoidCallback? onDiagnostics;

  @override
  Widget build(BuildContext context) {
    final label = status.label;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'STATUS',
                style: mono(
                  size: 11,
                  weight: FontWeight.w500,
                  color: AppColors.textMuted,
                  letterSpacing: 11 * 0.16,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: grotesk(
                  size: 18,
                  weight: FontWeight.w600,
                  color: status.color,
                  letterSpacing: -0.18,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: onDiagnostics,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AppColors.stroke),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.show_chart,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 7),
                Text(
                  'DIAGNOSTICS',
                  style: mono(
                    size: 11,
                    weight: FontWeight.w500,
                    color: AppColors.textSecondary,
                    letterSpacing: 11 * 0.06,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProtocolSegment extends StatelessWidget {
  const _ProtocolSegment({
    required this.mode,
    required this.enabled,
    required this.onSelect,
  });
  final ConnectMode mode;
  final bool enabled;
  final ValueChanged<ConnectMode> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: AppColors.stroke),
      ),
      child: Row(
        children: [
          _seg(
            'AUTO',
            mode == ConnectMode.auto,
            () => onSelect(ConnectMode.auto),
          ),
          const SizedBox(width: 4),
          _seg(
            'WIREGUARD',
            mode == ConnectMode.wireguard,
            () => onSelect(ConnectMode.wireguard),
          ),
          const SizedBox(width: 4),
          _seg(
            'STEALTH',
            mode == ConnectMode.stealth,
            () => onSelect(ConnectMode.stealth),
          ),
        ],
      ),
    );
  }

  Widget _seg(String label, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: mono(
              size: 12,
              weight: FontWeight.w600,
              color: active ? AppColors.onAccent : AppColors.textSecondary,
              letterSpacing: 12 * 0.05,
            ),
          ),
        ),
      ),
    );
  }
}

class _DataReadout extends StatelessWidget {
  const _DataReadout({required this.stats, required this.connected});
  final VpnStats stats;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.strokeSoft),
          bottom: BorderSide(color: AppColors.strokeSoft),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _TrafficStat(
                label: 'DOWNLOAD',
                arrow: '↓',
                value: connected ? fmtData(stats.rxBytes) : '0 KB',
              ),
            ),
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: AppColors.strokeSoft,
            ),
            Expanded(
              child: _TrafficStat(
                label: 'UPLOAD',
                arrow: '↑',
                value: connected ? fmtData(stats.txBytes) : '0 KB',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrafficStat extends StatelessWidget {
  const _TrafficStat({
    required this.label,
    required this.arrow,
    required this.value,
  });
  final String label;
  final String arrow;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              arrow,
              style: mono(
                size: 11,
                weight: FontWeight.w500,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: mono(
                size: 11,
                weight: FontWeight.w400,
                color: AppColors.textMuted,
                letterSpacing: 11 * 0.08,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          value,
          textAlign: TextAlign.center,
          style: mono(
            size: 15,
            weight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.display,
    this.egressIp,
    this.egressLoading = false,
    this.protocol,
    this.connected = false,
    this.onTap,
  });
  final NodeDisplay display;
  final String? egressIp;
  final bool egressLoading;
  final String? protocol;
  final bool connected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final d = display;
    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      color: d.isPlaceholder ? AppColors.surface2 : AppColors.surface,
      borderColor: d.isPlaceholder && d.name.contains('unavailable')
          ? AppColors.warn.withValues(alpha: 0.35)
          : AppColors.stroke,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.isPlaceholder) ...[
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.hub_outlined,
                size: 22,
                color: AppColors.accent.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: mono(
                      size: 14,
                      weight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    d.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: grotesk(
                      size: 12,
                      weight: FontWeight.w400,
                      color: AppColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ] else
            Expanded(child: NodeCompactRow(display: d, nameSize: 14)),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (d.isPlaceholder)
                TextActionChip(label: 'BROWSE', accent: true, onTap: onTap)
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (d.showLoad) ...[
                      Text(
                        d.loadLabel,
                        style: mono(
                          size: 14,
                          weight: FontWeight.w600,
                          color: d.loadColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    VisibleIconButton(
                      icon: Icons.swap_horiz_rounded,
                      onTap: onTap,
                      color: AppColors.accent,
                      borderColor: AppColors.accent.withValues(alpha: 0.35),
                      backgroundColor: AppColors.accent.withValues(alpha: 0.14),
                    ),
                  ],
                ),
              if (connected)
                Builder(
                  builder: (context) {
                    final protocolLabel = protocol;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 6),
                        Text(
                          egressLoading
                              ? 'Egress · …'
                              : (egressIp != null
                                    ? 'Egress · $egressIp'
                                    : 'Egress · —'),
                          style: mono(
                            size: 10,
                            weight: FontWeight.w500,
                            color: egressIp != null
                                ? AppColors.success
                                : AppColors.textMuted,
                          ),
                        ),
                        if (protocolLabel != null &&
                            protocolLabel.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Protocol · $protocolLabel',
                            style: mono(
                              size: 10,
                              weight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact label above the server card showing which scope ("Public network"
/// or an organization) the picker is browsing. Tapping opens the picker.
class _ScopeStrip extends StatelessWidget {
  const _ScopeStrip({
    required this.label,
    required this.isOrg,
    required this.verified,
    this.onTap,
  });
  final String label;
  final bool isOrg;
  final bool verified;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = isOrg ? AppColors.accent : AppColors.textTertiary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Icon(
            isOrg ? Icons.apartment_rounded : Icons.public,
            size: 13,
            color: accent,
          ),
          const SizedBox(width: 7),
          Text(
            'VPN SOURCE',
            style: mono(
              size: 10,
              weight: FontWeight.w500,
              color: AppColors.textMuted,
              letterSpacing: 10 * 0.06,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: grotesk(size: 12, weight: FontWeight.w600, color: accent),
            ),
          ),
          if (verified) ...[
            const SizedBox(width: 4),
            Icon(Icons.verified, size: 12, color: accent),
          ],
          const Spacer(),
          Text(
            'CHANGE',
            style: mono(
              size: 10,
              weight: FontWeight.w600,
              color: AppColors.accent,
              letterSpacing: 10 * 0.06,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.chevron_right, size: 14, color: AppColors.accent),
        ],
      ),
    );
  }
}
