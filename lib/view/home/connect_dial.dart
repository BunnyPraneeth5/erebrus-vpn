import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../platform/platform_capabilities.dart';
import '../../theme/app_theme.dart';
import '../../vpn/singbox_engine.dart';
import '../../vpn/vpn_controller.dart';

class VpnSafetyStatus {
  const VpnSafetyStatus({
    this.label = 'NOT PROTECTED',
    this.color = AppColors.warn,
    this.isProtected = false,
  });

  final String label;
  final Color color;
  final bool isProtected;
}

VpnSafetyStatus vpnSafetyStatus(VpnController vpn, {bool? proxyScoped}) {
  final proxy = proxyScoped ?? PlatformCapabilities.usesDesktopVpnRunner;
  if (vpn.killSwitchEngaging.value) {
    return VpnSafetyStatus(
      label: proxy ? 'BLOCKING PROXY TRAFFIC' : 'BLOCKING TUNNEL TRAFFIC',
    );
  }
  if (vpn.killSwitchBlocking.value) {
    return VpnSafetyStatus(
      label: proxy ? 'PROXY TRAFFIC BLOCKED' : 'TUNNEL TRAFFIC BLOCKED',
      color: AppColors.danger,
    );
  }
  if (vpn.isProtected) {
    return VpnSafetyStatus(
      label: proxy ? 'PROXY CONNECTED' : 'PROTECTED',
      color: AppColors.success,
      isProtected: true,
    );
  }
  if (vpn.stage.value == VpnStage.connected) {
    return const VpnSafetyStatus(
      label: 'TUNNEL STALLED',
      color: AppColors.danger,
    );
  }
  return const VpnSafetyStatus();
}

/// Formats a duration as `MM:SS` or `H:MM:SS`.
String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Formats a byte count using the spec's KB/MB/GB scale.
String fmtData(int bytes) {
  final kb = bytes ~/ 1024;
  if (kb < 1024) return '$kb KB';
  final mb = bytes / (1024 * 1024);
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// The 240×240 connect dial with offline / connecting / connected states.
class ConnectDial extends StatefulWidget {
  const ConnectDial({
    super.key,
    required this.stage,
    required this.durationLabel,
    this.status,
    this.connectingLabel,
    this.onTap,
  });

  final VpnStage stage;
  final String durationLabel;
  final VpnSafetyStatus? status;

  /// Status text while connecting/disconnecting (e.g. "STEALTH HANDSHAKE…").
  final String? connectingLabel;
  final VoidCallback? onTap;

  @override
  State<ConnectDial> createState() => _ConnectDialState();
}

class _ConnectDialState extends State<ConnectDial>
    with TickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    super.dispose();
  }

  bool get _connecting =>
      widget.stage == VpnStage.connecting ||
      widget.stage == VpnStage.disconnecting;

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    if (status != null) return _buildDial(status);
    if (Get.isRegistered<VpnController>()) {
      return Obx(() => _buildDial(vpnSafetyStatus(Get.find<VpnController>())));
    }
    return _buildDial(const VpnSafetyStatus());
  }

  Widget _buildDial(VpnSafetyStatus status) {
    const size = 240.0;
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // base ring
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                  width: 1.5,
                ),
              ),
            ),
            // connecting arc
            if (_connecting)
              AnimatedBuilder(
                animation: _spin,
                builder: (_, _) => Transform.rotate(
                  angle: _spin.value * 2 * math.pi,
                  child: CustomPaint(
                    size: const Size(size, size),
                    painter: _ArcRingPainter(),
                  ),
                ),
              ),
            // connected pulse rings + solid glow ring
            if (status.isProtected) ...[
              _PulseRing(controller: _pulse, phase: 0.0),
              _PulseRing(controller: _pulse, phase: 0.5),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.accent, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.7),
                      blurRadius: 50,
                      spreadRadius: -6,
                    ),
                  ],
                ),
              ),
            ],
            // center disk
            _CenterDisk(
              stage: widget.stage,
              status: status,
              durationLabel: widget.durationLabel,
              connectingLabel: widget.connectingLabel,
              cancellable:
                  widget.stage == VpnStage.connecting && widget.onTap != null,
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterDisk extends StatelessWidget {
  const _CenterDisk({
    required this.stage,
    required this.status,
    required this.durationLabel,
    this.connectingLabel,
    this.cancellable = false,
  });

  final VpnStage stage;
  final VpnSafetyStatus status;
  final String durationLabel;
  final String? connectingLabel;
  final bool cancellable;

  @override
  Widget build(BuildContext context) {
    final connected = status.isProtected;
    final connecting =
        (stage == VpnStage.connecting || stage == VpnStage.disconnecting) &&
        status.label == 'NOT PROTECTED';

    final gradient = connected
        ? const RadialGradient(
            center: Alignment(0, -0.3),
            colors: [Color(0xFF2A1709), Color(0xFF140D08)],
          )
        : connecting
        ? const RadialGradient(
            center: Alignment(0, -0.3),
            colors: [Color(0xFF1D150F), Color(0xFF0D0D11)],
          )
        : const RadialGradient(
            center: Alignment(0, -0.3),
            colors: [Color(0xFF18181E), Color(0xFF0D0D11)],
          );

    Widget content;
    if (connected) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.verified_user, size: 38, color: AppColors.accent),
          const SizedBox(height: 4),
          Text(
            durationLabel,
            style: mono(
              size: 25,
              weight: FontWeight.w600,
              color: AppColors.textPrimary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            status.label,
            textAlign: TextAlign.center,
            style: mono(
              size: 11,
              weight: FontWeight.w500,
              color: AppColors.accent,
              letterSpacing: 11 * 0.12,
            ),
          ),
        ],
      );
    } else if (connecting) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.power_settings_new,
            size: 40,
            color: AppColors.accent,
          ),
          const SizedBox(height: 9),
          Text(
            connectingLabel ?? 'SECURING…',
            textAlign: TextAlign.center,
            style: mono(
              size: 12,
              weight: FontWeight.w500,
              color: AppColors.accent,
              letterSpacing: 12 * 0.05,
            ),
          ),
          if (cancellable) ...[
            const SizedBox(height: 5),
            Text(
              'TAP TO CANCEL',
              style: mono(
                size: 10,
                weight: FontWeight.w500,
                color: AppColors.textTertiary,
                letterSpacing: 10 * 0.08,
              ),
            ),
          ],
        ],
      );
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.power_settings_new,
            size: 40,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: 9),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              status.label,
              textAlign: TextAlign.center,
              style: mono(
                size: 11,
                weight: FontWeight.w500,
                color: status.color,
                letterSpacing: 0.5,
              ),
            ),
          ),
          if (status.label == 'NOT PROTECTED' &&
              stage != VpnStage.connected) ...[
            const SizedBox(height: 5),
            Text(
              'TAP TO CONNECT',
              style: mono(
                size: 10,
                weight: FontWeight.w500,
                color: AppColors.textTertiary,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ],
      );
    }

    return Container(
      width: 172,
      height: 172,
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: gradient),
      child: content,
    );
  }
}

class _PulseRing extends StatelessWidget {
  const _PulseRing({required this.controller, required this.phase});
  final AnimationController controller;
  final double phase;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final t = (controller.value + phase) % 1.0;
        final scale = 0.8 + (1.75 - 0.8) * t;
        final opacity = t < 0.8 ? 0.55 * (1 - t / 0.8) : 0.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.accent.withValues(alpha: opacity),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ArcRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = size.width / 2 - 1.5;
    // top arc, bright
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2 - 0.5,
      1.0,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.accent,
    );
    // right arc, dim
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      0.2,
      0.9,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.accent.withValues(alpha: 0.4),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
