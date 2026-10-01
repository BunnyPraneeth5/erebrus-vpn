import 'gateway_client.dart';

const _pricingUrl = 'erebrus.io/pricing';

/// Turns raw gateway errors into short, actionable copy for the connect UI.
/// The gateway enforces every plan limit; this only explains its answer.
String friendlyGatewayError(Object error, {String? nodeName}) {
  final node = nodeName ?? 'the node';
  if (error is GatewayException && error.code != null) {
    final byCode = _byCode(error, node);
    if (byCode != null) return byCode;
  }
  final raw = switch (error) {
    GatewayException(:final message) => message,
    _ => error.toString(),
  };
  final lower = raw.toLowerCase();

  if (lower.contains('organization membership is required') ||
      lower.contains('no active subscription')) {
    return 'Your account needs an active Erebrus workspace. Sign out and back in, or check Account → Organizations';
  }
  if (lower.contains('higher tier')) {
    return 'This server requires a higher XP tier — earn rank on erebrus.io or pick an open-pool node';
  }
  if (lower.contains('private node') || lower.contains('org membership')) {
    return 'This is a private org node — you need membership to connect';
  }
  if (lower.contains('node unreachable') || lower.contains('no reachable api')) {
    return 'Gateway cannot reach $node (port 9080). '
        'The node may need to re-register with the gateway, or the server '
        'firewall must allow the gateway to call the node API.';
  }
  if (lower.contains('device limit')) {
    return 'Device limit reached for your plan — remove a device on $_pricingUrl or upgrade';
  }
  if (lower.contains('node not found')) {
    return 'Node no longer registered — refresh Servers and pick another node';
  }
  if (lower.contains('node is draining')) {
    return '$node is draining — choose another server';
  }
  return raw;
}

String? _byCode(GatewayException e, String node) {
  switch (e.code) {
    case 'VPN_DEVICE_LIMIT':
      final limit = e.details?['limit'];
      final used = e.details?['used'] ?? limit;
      final count = limit != null ? ' ($used/$limit)' : '';
      return 'Device limit reached$count. Remove a device you no longer use, or upgrade at $_pricingUrl';
    case 'VPN_DEVICE_PAUSED':
      return 'This device is paused because your plan no longer covers it. Remove another device or upgrade at $_pricingUrl';
    case 'ENTITLEMENT_REQUIRED':
      return 'Your account needs an active Erebrus workspace. Sign out and back in, or check Account → Organizations';
    case 'BILLING_ACCESS_REQUIRED':
      return "This managed node isn't covered by the workspace's billing. Ask the workspace owner to restore billing";
    case 'TIER_REQUIRED':
      return 'This server requires a higher XP tier — earn rank on erebrus.io or pick an open-pool node';
    case 'PRIVATE_NODE_ACCESS':
      return 'This is a private org node — you need membership to connect';
    case 'NODE_DRAINING':
      return '$node is draining — choose another server';
    case 'NODE_CAPACITY':
      return '$node is full right now — choose another server';
    case 'NODE_NOT_FOUND':
      return 'Node no longer registered — refresh Servers and pick another node';
    case 'IDEMPOTENCY_CONFLICT':
      return 'A previous connection attempt is still being processed — try again';
  }
  return null;
}
