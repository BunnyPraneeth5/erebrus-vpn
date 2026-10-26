import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../platform/platform_capabilities.dart';
import '../../theme/app_theme.dart';
import '../home/connect_dial.dart';
import '../../vpn/singbox_engine.dart';
import '../../vpn/vpn_controller.dart';
import '../../vpn/vpn_models.dart';

class BrowserSessionStatus {
  const BrowserSessionStatus({
    required this.label,
    required this.tint,
    required this.pulse,
  });

  final String label;
  final Color tint;
  final bool pulse;
}

BrowserSessionStatus browserSessionStatus(
  VpnController vpn, {
  bool? proxyScoped,
}) {
  final stage = vpn.stage.value;
  final proxy = proxyScoped ?? PlatformCapabilities.usesDesktopVpnRunner;
  final safety = vpnSafetyStatus(vpn, proxyScoped: proxy);

  if (vpn.killSwitchEngaging.value ||
      vpn.killSwitchBlocking.value ||
      (stage == VpnStage.connected && !safety.isProtected)) {
    return BrowserSessionStatus(
      label: safety.label,
      tint: safety.color,
      pulse: vpn.killSwitchEngaging.value,
    );
  }

  if (safety.isProtected) {
    final transport = vpn.activeTransport.value;
    final protocol = (transport?.label ?? vpn.mode.value.label).toUpperCase();
    return BrowserSessionStatus(
      label: '${proxy ? 'PROXY CONNECTED' : 'PRIVATE SESSION'} · $protocol',
      tint: AppColors.success,
      pulse: true,
    );
  }

  if (stage == VpnStage.connecting || stage == VpnStage.disconnecting) {
    final transport = vpn.activeTransport.value;
    final hint =
        transport?.label.toUpperCase() ?? vpn.mode.value.label.toUpperCase();
    final verb = stage == VpnStage.connecting ? 'CONNECTING' : 'STOPPING';
    return BrowserSessionStatus(
      label: '$verb · $hint',
      tint: AppColors.accent,
      pulse: true,
    );
  }

  return const BrowserSessionStatus(
    label: 'NOT PROTECTED',
    tint: AppColors.warn,
    pulse: false,
  );
}

class BrowserSessionStrip extends StatelessWidget {
  const BrowserSessionStrip({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<VpnController>()) {
      return const _BrowserSessionStripBody(
        status: BrowserSessionStatus(
          label: 'NOT PROTECTED',
          tint: AppColors.warn,
          pulse: false,
        ),
      );
    }

    final vpn = Get.find<VpnController>();
    return Obx(() {
      vpn.stage.value;
      vpn.activeTransport.value;
      vpn.mode.value;
      vpn.killSwitchBlocking.value;
      vpn.killSwitchEngaging.value;
      vpn.tunnelHealthy.value;
      return _BrowserSessionStripBody(status: browserSessionStatus(vpn));
    });
  }
}

class _BrowserSessionStripBody extends StatelessWidget {
  const _BrowserSessionStripBody({required this.status});

  final BrowserSessionStatus status;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
      child: Row(
        children: [
          _SessionDot(color: status.tint, pulse: status.pulse),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              status.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(
                size: 11,
                weight: FontWeight.w500,
                color: status.tint,
                letterSpacing: 11 * 0.12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionDot extends StatefulWidget {
  const _SessionDot({required this.color, required this.pulse});

  final Color color;
  final bool pulse;

  @override
  State<_SessionDot> createState() => _SessionDotState();
}

class _SessionDotState extends State<_SessionDot>
    with TickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _SessionDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.pulse) {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(seconds: 2),
      )..repeat(reverse: true);
      return;
    }
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    final controller = _controller;
    if (controller == null) return dot;
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.25).animate(controller),
      child: dot,
    );
  }
}
