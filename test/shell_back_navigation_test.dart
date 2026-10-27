import 'package:erebrus_vpn/view/bottombar/shell_back_scope.dart';
import 'package:erebrus_vpn/view/browser/browser_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors [MainShell]: tabs are index switches on one route.
class _Shell extends StatefulWidget {
  const _Shell({
    required this.initialIndex,
    required this.browserBack,
    this.moveToBackground,
  });

  final int initialIndex;
  final Future<bool> Function() browserBack;
  final Future<void> Function()? moveToBackground;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  late int _index = widget.initialIndex;

  @override
  Widget build(BuildContext context) {
    return ShellBackScope(
      index: _index,
      onSelectTab: (i) => setState(() => _index = i),
      browserBack: widget.browserBack,
      moveToBackground: widget.moveToBackground,
      child: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              Text('tab $_index'),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('nested')),
                  ),
                ),
                child: const Text('open nested'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void main() {
  late int systemPops;
  late int movedToBackground;
  late int browserBackCalls;

  setUp(() {
    systemPops = 0;
    movedToBackground = 0;
    browserBackCalls = 0;
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    required int index,
    bool browserHasHistory = false,
    bool interceptRoot = true,
  }) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') systemPops++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: _Shell(
          initialIndex: index,
          browserBack: () async {
            browserBackCalls++;
            return browserHasHistory;
          },
          moveToBackground: interceptRoot
              ? () async => movedToBackground++
              : null,
        ),
      ),
    );
  }

  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('back on Settings returns to the VPN tab, not out of the app', (
    tester,
  ) async {
    await pumpShell(tester, index: 2);
    await systemBack(tester);

    expect(find.text('tab 0'), findsOneWidget);
    expect(browserBackCalls, 0);
    expect(movedToBackground, 0);
    expect(systemPops, 0);
  });

  testWidgets('back on Browser steps back through web history first', (
    tester,
  ) async {
    await pumpShell(tester, index: 1, browserHasHistory: true);
    await systemBack(tester);

    expect(find.text('tab 1'), findsOneWidget);
    expect(browserBackCalls, 1);
    expect(movedToBackground, 0);
    expect(systemPops, 0);
  });

  testWidgets('back on Browser without history returns to the VPN tab', (
    tester,
  ) async {
    await pumpShell(tester, index: 1);
    await systemBack(tester);

    expect(find.text('tab 0'), findsOneWidget);
    expect(browserBackCalls, 1);
    expect(movedToBackground, 0);
    expect(systemPops, 0);
  });

  testWidgets('back on the VPN tab moves the app to the background', (
    tester,
  ) async {
    await pumpShell(tester, index: 0);
    await systemBack(tester);

    expect(find.text('tab 0'), findsOneWidget);
    expect(movedToBackground, 1);
    expect(systemPops, 0);
  });

  testWidgets('without a background hook the VPN tab defers to the system', (
    tester,
  ) async {
    await pumpShell(tester, index: 0, interceptRoot: false);
    await systemBack(tester);

    expect(movedToBackground, 0);
    expect(systemPops, 1);
  });

  testWidgets('back on a nested screen pops it and stays on the tab', (
    tester,
  ) async {
    await pumpShell(tester, index: 2);
    await tester.tap(find.text('open nested'));
    await tester.pumpAndSettle();
    expect(find.text('nested'), findsOneWidget);

    await systemBack(tester);

    expect(find.text('nested'), findsNothing);
    expect(find.text('tab 2'), findsOneWidget);
    expect(movedToBackground, 0);
    expect(systemPops, 0);
  });

  testWidgets('moveAppToBackground falls back to the system pop', (
    tester,
  ) async {
    const appMethods = MethodChannel('com.erebrus.vpn/methods');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(appMethods, (call) async {
      calls.add(call.method);
      return false;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') systemPops++;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(appMethods, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await moveAppToBackground();

    expect(calls, ['moveTaskToBack']);
    expect(systemPops, 1);
  });

  test('browser back reports no history on the start page', () async {
    final controller = BrowserController();
    controller.addTab();

    expect(await controller.goBackIfPossible(), isFalse);
    controller.onClose();
  });
}
