import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/async_state_view.dart';

void main() {
  testWidgets('scrollable state view keeps full-page errors reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 240);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(
              body: ScrollableStateView(
                child: AsyncStateView(
                  padding: const EdgeInsets.all(24),
                  icon: const Icon(Icons.cloud_off_outlined, size: 64),
                  title: const Text('Connection failed'),
                  message: const Text(
                    'Offline mode: network connection failed, only downloaded content is accessible',
                  ),
                  action: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: () {},
                        child: const Text('Retry'),
                      ),
                      TextButton(
                        onPressed: () {},
                        child: const Text('Settings'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final scrollable = find.byType(Scrollable).first;
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    await tester.scrollUntilVisible(
      find.text('Settings'),
      80,
      scrollable: scrollable,
    );
    expect(find.text('Settings').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
