import 'package:erebrus_vpn/view/home/node_display.dart';
import 'package:erebrus_vpn/vpn/gateway_client.dart';
import 'package:erebrus_vpn/vpn/vpn_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live gateway is reachable', () async {
    final client = GatewayClient();
    late final List<VpnNode> nodes;
    try {
      nodes = await client.fetchNodes();
    } catch (e) {
      fail('Gateway unreachable at ${client.baseUrl}: $e');
    }

    // An empty registry is valid when no nodes are online in production.
    if (nodes.isEmpty) return;

    final n = nodes.first;
    expect(n.name, isNotEmpty);
    expect(n.region, isNotEmpty);
    expect(n.walletAddress, isNotEmpty);
    expect(n.chain, isNotEmpty);
    // `zone` and `org` are optional in the live registry (public nodes such
    // as erebrus-Crypto ship region only); assert them only when present.
    if (n.org != null) expect(n.org!.name, isNotEmpty);

    final d = NodeDisplay.of(n, showActivity: true);
    expect(d.regionCompact, isNotEmpty);
    if (d.org != null) expect(d.org!.name, isNotEmpty);
    expect(d.showSolanaBadge, n.chain?.toLowerCase() == 'solana');
  }, skip: false);
}
