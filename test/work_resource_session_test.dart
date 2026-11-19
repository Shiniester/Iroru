import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/widgets/work_resource_tabs.dart';

void main() {
  test('session keeps resource tab state across widget lifetimes', () {
    final session = WorkResourceSession()
      ..selectedTab = WorkResourceTab.images
      ..imagePage = 3
      ..recommendationVisited = true
      ..expandedFolders.add('A');
    session.recordScrollOffset(WorkResourceTab.images, 420);

    expect(session.selectedTab, WorkResourceTab.images);
    expect(session.imagePage, 3);
    expect(session.recommendationVisited, isTrue);
    expect(session.expandedFolders, {'A'});
    expect(session.scrollOffsetFor(WorkResourceTab.images), 420);
    expect(session.reachedResourceTopFor(WorkResourceTab.images), isTrue);

    session.recordScrollOffset(WorkResourceTab.images, -20);
    expect(session.scrollOffsetFor(WorkResourceTab.images), 0);
    expect(session.reachedResourceTopFor(WorkResourceTab.images), isFalse);

    session.resetScrollOffset(WorkResourceTab.images);
    expect(session.scrollOffsetFor(WorkResourceTab.images), 0);
    expect(session.reachedResourceTopFor(WorkResourceTab.images), isTrue);
  });
}
