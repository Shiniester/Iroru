import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/providers/works_provider.dart' show LayoutType;
import 'package:iroru/src/widgets/local_history_card.dart';

void main() {
  for (final (width, layout) in [
    (360.0, LayoutType.list),
    (360.0, LayoutType.smallGrid),
    (1024.0, LayoutType.list),
    (1024.0, LayoutType.bigGrid),
  ]) {
    testWidgets('history progress is below the cover in $layout at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var openCount = 0;
      var resumeCount = 0;
      var removeCount = 0;
      const coverKey = ValueKey('cover');
      const title = 'A recording with a long title';
      const progress = '01:02:03 / 02:04:06';
      final cardWidth = layout == LayoutType.list
          ? width - 16
          : width < 600
          ? 152.0
          : 224.0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 850),
                textScaler: const TextScaler.linear(1.8),
              ),
              child: Center(
                child: SizedBox(
                  width: cardWidth,
                  child: LocalHistoryCard(
                    layoutType: layout,
                    title: title,
                    sourceLabel: 'ASMR.ONE',
                    cover: const ColoredBox(
                      key: coverKey,
                      color: Colors.blueGrey,
                    ),
                    onOpen: () => openCount++,
                    onResume: () => resumeCount++,
                    resumeLabel: 'Resume',
                    onRemove: () => removeCount++,
                    progressTitle: 'Chapter 2',
                    progressText: progress,
                    progressTrailing: '12 / 24',
                    progressValue: .5,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final progressFinder = find.text(progress);
      expect(
        tester.getTopLeft(progressFinder).dy,
        greaterThan(tester.getBottomLeft(find.byKey(coverKey)).dy),
      );
      expect(
        tester.getTopLeft(progressFinder).dy,
        greaterThan(tester.getBottomLeft(find.text(title)).dy),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .5,
      );
      await tester.tap(find.byTooltip('Resume'));
      await tester.tap(find.text(title));
      await tester.longPress(find.text(title));

      expect(resumeCount, 1);
      expect(openCount, 1);
      expect(removeCount, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
