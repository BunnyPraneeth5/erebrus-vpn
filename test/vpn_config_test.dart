import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:erebrus_vpn/vpn/vpn_models.dart';

// A minimal node-style credential bundle: a sing-box profile with the WG
// endpoint + both carrier outbounds (as the gateway/node returns).
const _bundleJson = '''
{
  "wireguard": {
    "server_public_key": "6RfVDGZnJs4BJSzRk+iR8Ta1ftSMSnEC5fGwSbw7RkM=",
    "endpoint": "203.0.113.10:51820",
    "address": "10.0.0.7/32",
    "dns": "1.1.1.1"
  },
  "vless_uri": "vless://uuid@203.0.113.10:8443?security=reality#node",
  "hysteria2_uri": "hysteria2://pw@203.0.113.10:4443?#node",
  "singbox_profile": {
    "endpoints": [
      {"type":"wireguard","tag":"wg-out","address":["10.0.0.7/32"],
       "private_key":"REPLACE_WITH_CLIENT_PRIVATE_KEY",
       "peers":[{"address":"127.0.0.1","port":51820,"public_key":"srv","allowed_ips":["0.0.0.0/0"]}],
       "detour":"carrier-vless"}
    ],
    "outbounds": [
      {"type":"vless","tag":"carrier-vless","server":"203.0.113.10","server_port":8443},
      {"type":"hysteria2","tag":"carrier-hysteria2","server":"203.0.113.10","server_port":4443}
    ],
    "route": {"final": "wg-out"}
  }
}
''';

void main() {
  test('ConnectMode maps to the right transport fallback order', () {
    expect(ConnectMode.auto.transports, [
      Transport.wireguard,
      Transport.vlessReality,
      Transport.hysteria2,
    ]);
    expect(ConnectMode.stealth.transports, [
      Transport.vlessReality,
      Transport.hysteria2,
    ]);
    expect(ConnectMode.wireguard.transports, [Transport.wireguard]);
  });

  test('Transport maps to the connect-screen protocol segment', () {
    expect(Transport.wireguard.connectMode, ConnectMode.wireguard);
    expect(Transport.vlessReality.connectMode, ConnectMode.stealth);
    expect(Transport.hysteria2.connectMode, ConnectMode.stealth);
  });

  test('desktop WireGuard bootstraps an unresolved peer hostname directly', () {
    final json = jsonDecode(_bundleJson) as Map<String, dynamic>;
    json['wireguard']['endpoint'] = 'vpn.example.com:51820';
    final config = SingboxConfigBuilder.build(
      bundle: CredentialBundle.fromJson(json),
      transport: Transport.wireguard,
      clientPrivateKey: 'PRIV',
      useSystemTunnel: false,
      resolvedHosts: const {},
    );
    final dns = config['dns'] as Map;
    final rules = dns['rules'] as List? ?? const [];
    expect(rules, [
      {
        'domain': ['vpn.example.com'],
        'server': 'dns-direct',
      },
    ]);
    expect(dns['final'], 'dns-remote');
    expect(rules.length, 1);
  });

  test('literal WireGuard peers do not need bootstrap DNS rules', () {
    final config = SingboxConfigBuilder.build(
      bundle: CredentialBundle.fromJson(jsonDecode(_bundleJson)),
      transport: Transport.wireguard,
      clientPrivateKey: 'PRIV',
      useSystemTunnel: false,
      resolvedHosts: const {},
    );
    expect((config['dns'] as Map)['rules'], isNull);
  });

  test('CredentialBundle parses the node response', () {
    final b = CredentialBundle.fromJson(jsonDecode(_bundleJson));
    expect(b.serverPublicKey, '6RfVDGZnJs4BJSzRk+iR8Ta1ftSMSnEC5fGwSbw7RkM=');
    expect(b.endpoint, '203.0.113.10:51820');
    expect(b.hasStealth, isTrue);
  });

  test('WireGuard transport dials the real endpoint, no carrier detour', () {
    final b = CredentialBundle.fromJson(jsonDecode(_bundleJson));
    final cfg = SingboxConfigBuilder.build(
      bundle: b,
      transport: Transport.wireguard,
      clientPrivateKey: 'PRIV',
    );
    final ep = (cfg['endpoints'] as List).first as Map;
    expect(ep['private_key'], 'PRIV');
    expect(ep.containsKey('detour'), isFalse);
    final peer = (ep['peers'] as List).first as Map;
    expect(peer['address'], '203.0.113.10');
    expect(peer['port'], 51820);
    expect((cfg['inbounds'] as List).first['type'], 'tun');
    expect((cfg['inbounds'] as List).first['stack'], 'gvisor');
    expect((cfg['dns'] as Map)['final'], 'dns-remote');
    expect((cfg['route'] as Map)['auto_detect_interface'], isTrue);
    final rules = (cfg['route'] as Map)['rules'] as List;
    expect(rules.first['ip_cidr'], ['203.0.113.10/32']);
    expect(
      rules.any((r) => (r as Map)['action'] == 'hijack-dns'),
      isTrue,
    ); // tunnel DNS capture
    expect(
      rules.any((r) => (r as Map)['ip_cidr'] == ['172.19.0.0/30']),
      isFalse,
    );
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.any((i) => (i as Map)['type'] == 'mixed'), isTrue);
    expect((cfg['experimental'] as Map)['clash_api'], isNotNull);
    expect(
      (cfg['endpoints'] as List).first['peers'][0]['public_key'],
      '6RfVDGZnJs4BJSzRk+iR8Ta1ftSMSnEC5fGwSbw7RkM=',
    );
  });

  test(
    'Stealth transport detours WG through the VLESS carrier (loopback peer)',
    () {
      final b = CredentialBundle.fromJson(jsonDecode(_bundleJson));
      final cfg = SingboxConfigBuilder.build(
        bundle: b,
        transport: Transport.vlessReality,
        clientPrivateKey: 'PRIV',
      );
      final ep = (cfg['endpoints'] as List).first as Map;
      expect(ep['detour'], 'carrier-vless');
      final peer = (ep['peers'] as List).first as Map;
      expect(
        peer['address'],
        '127.0.0.1',
      ); // node de-wraps and forwards locally
      expect(cfg['route']['final'], 'wg-out');
      final rules = cfg['route']['rules'] as List;
      expect(
        rules.any((r) => (r as Map)['action'] == 'hijack-dns'),
        isTrue,
      ); // tunnel DNS capture
      final outbounds = cfg['outbounds'] as List;
      expect(outbounds.any((o) => (o as Map)['tag'] == 'direct'), isTrue);
    },
  );

  test('dialTarget uses carrier port for stealth transports', () {
    final b = CredentialBundle.fromJson(jsonDecode(_bundleJson));
    expect(b.dialTarget(Transport.wireguard), '203.0.113.10:51820');
    expect(b.dialTarget(Transport.vlessReality), '203.0.113.10:8443');
    expect(b.dialTarget(Transport.hysteria2), '203.0.113.10:4443');
  });

  test('resolved hostname dials IPv4 peer and ip_cidr bypass', () {
    final json = jsonDecode(_bundleJson) as Map<String, dynamic>;
    final wg = (json['wireguard'] as Map).cast<String, dynamic>();
    wg['endpoint'] = 'us01.erebrus.io:51820';
    final b = CredentialBundle.fromJson(json);
    final cfg = SingboxConfigBuilder.build(
      bundle: b,
      transport: Transport.wireguard,
      clientPrivateKey: 'PRIV',
      resolvedHosts: {'us01.erebrus.io': '209.50.50.202'},
    );
    final peer = ((cfg['endpoints'] as List).first as Map)['peers'][0] as Map;
    expect(peer['address'], '209.50.50.202');
    final rules = (cfg['route'] as Map)['rules'] as List;
    final bypass =
        rules.firstWhere((r) => (r as Map).containsKey('ip_cidr')) as Map;
    expect(bypass['ip_cidr'], ['209.50.50.202/32']);
  });

  test(
    'bracketed IPv6 endpoint keeps the address intact and uses /128 bypass',
    () {
      final json = jsonDecode(_bundleJson) as Map<String, dynamic>;
      final wg = (json['wireguard'] as Map).cast<String, dynamic>();
      wg['endpoint'] = '[2001:db8::1]:51820';
      final b = CredentialBundle.fromJson(json);
      final cfg = SingboxConfigBuilder.build(
        bundle: b,
        transport: Transport.wireguard,
        clientPrivateKey: 'PRIV',
      );
      final peer = ((cfg['endpoints'] as List).first as Map)['peers'][0] as Map;
      expect(peer['address'], '2001:db8::1');
      expect(peer['port'], 51820);
      final rules = (cfg['route'] as Map)['rules'] as List;
      final bypass =
          rules.firstWhere((r) => (r as Map).containsKey('ip_cidr')) as Map;
      expect(bypass['ip_cidr'], [
        '2001:db8::1/128',
      ]); // /32 would be a huge v6 prefix
    },
  );

  test('bare IPv6 endpoint (no port) is not truncated at the last colon', () {
    final json = jsonDecode(_bundleJson) as Map<String, dynamic>;
    final wg = (json['wireguard'] as Map).cast<String, dynamic>();
    wg['endpoint'] = '2001:db8::1';
    final b = CredentialBundle.fromJson(json);
    final cfg = SingboxConfigBuilder.build(
      bundle: b,
      transport: Transport.wireguard,
      clientPrivateKey: 'PRIV',
    );
    final peer = ((cfg['endpoints'] as List).first as Map)['peers'][0] as Map;
    expect(peer['address'], '2001:db8::1');
    expect(peer['port'], 51820); // default WG port
  });

  test(
    'stealth DNS bootstrap covers only the carrier host, not the WG endpoint',
    () {
      final json = jsonDecode(_bundleJson) as Map<String, dynamic>;
      final wg = (json['wireguard'] as Map).cast<String, dynamic>();
      // Distinct hostnames: the WG endpoint host is never dialed in stealth
      // (inner peer is the node loopback), so it must not leak into bootstrap.
      wg['endpoint'] = 'wg.example.com:51820';
      // _patchVlessFromUri re-applies the URI host, so keep it consistent.
      json['vless_uri'] =
          'vless://uuid@carrier.example.com:8443?security=reality#node';
      final ob = ((json['singbox_profile'] as Map)['outbounds'] as List)
          .cast<Map>();
      for (final o in ob) {
        if (o['tag'] == 'carrier-vless') o['server'] = 'carrier.example.com';
      }
      final b = CredentialBundle.fromJson(json);
      final cfg = SingboxConfigBuilder.build(
        bundle: b,
        transport: Transport.vlessReality,
        clientPrivateKey: 'PRIV',
      );
      final dnsRules =
          ((cfg['dns'] as Map)['rules'] as List?)?.cast<Map>() ?? const [];
      final bootstrapDomains = dnsRules
          .where((r) => r['server'] == 'dns-direct')
          .expand((r) => (r['domain'] as List).cast<String>())
          .toList();
      expect(bootstrapDomains, ['carrier.example.com']);
    },
  );

  test('hostname server bypass uses domain rule, not ip_cidr', () {
    final json = jsonDecode(_bundleJson) as Map<String, dynamic>;
    final wg = (json['wireguard'] as Map).cast<String, dynamic>();
    wg['endpoint'] = 'us01.erebrus.io:51820';
    json['vless_uri'] =
        'vless://uuid@us01.erebrus.io:8443?security=reality#node';
    json['hysteria2_uri'] = 'hysteria2://pw@us01.erebrus.io:4443?#node';
    final ob = ((json['singbox_profile'] as Map)['outbounds'] as List)
        .cast<Map>();
    for (final o in ob) {
      if (o['tag'] == 'carrier-vless') o['server'] = 'us01.erebrus.io';
      if (o['tag'] == 'carrier-hysteria2') o['server'] = 'us01.erebrus.io';
    }
    final b = CredentialBundle.fromJson(json);
    final cfg = SingboxConfigBuilder.build(
      bundle: b,
      transport: Transport.vlessReality,
      clientPrivateKey: 'PRIV',
    );
    final rules = (cfg['route'] as Map)['rules'] as List;
    final bypass =
        rules.firstWhere(
              (r) =>
                  (r as Map).containsKey('domain') || r.containsKey('ip_cidr'),
            )
            as Map;
    expect(bypass['domain'], ['us01.erebrus.io']);
    expect(bypass.containsKey('ip_cidr'), isFalse);
  });
}
