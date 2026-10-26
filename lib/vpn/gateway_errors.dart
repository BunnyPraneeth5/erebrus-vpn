import 'gateway_client.dart';

/// Turns raw gateway errors into short, actionable copy for the connect UI.
String friendlyGatewayError(Object error, {String? nodeName}) {
  final raw = switch (error) {
    GatewayException(:final message) => message,
    _ => error.toString(),
  };
  final lower = raw.toLowerCase();
  final node = nodeName ?? 'the node';

  if (lower.contains('no active subscription')) {
    return 'No active subscription — start a free trial in Account first';
  }
  if (lower.contains('higher tier')) {
    return 'This server requires a higher XP tier — earn rank on erebrus.io or pick an open-pool node';
  }
  if (lower.contains('private node') || lower.contains('org membership')) {
    return 'This is a private org node — you need membership to connect';
  }
  if (lower.contains('node unreachable') ||
      lower.contains('no reachable api')) {
    return 'Gateway cannot reach $node (port 9080). '
        'The node may need to re-register with the gateway, or the server '
        'firewall must allow the gateway to call the node API.';
  }
  if (error is GatewayException && error.isDeviceLimitReached) {
    return 'Connected-device limit reached — disconnect another device and try again';
  }
  if (lower.contains('client limit')) {
    // Older gateways may still reject a saved-config count. Deleting configs
    // is not the connected-device policy and must not be suggested as a fix.
    return 'The server rejected this VPN config. Saved configs do not use connected-device slots.';
  }
  if (lower.contains('node not found')) {
    return 'Node no longer registered — refresh Servers and pick another node';
  }
  if (lower.contains('node is draining')) {
    return '$node is draining — choose another server';
  }
  return raw;
}
