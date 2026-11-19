import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/services/player_audio_variant_classifier.dart';
import 'package:iroru/src/widgets/work_detail/work_detail_responsive_layout.dart';
import 'package:iroru/src/widgets/work_resource_tabs.dart';

List<dynamic> _files({int images = 0}) => [
  {'type': 'audio', 'title': 'track.wav', 'hash': 'audio'},
  for (var index = 0; index < images; index++)
    {'type': 'image', 'title': 'image$index.png', 'hash': 'image$index'},
];

Widget _app({
  required List<dynamic> files,
  required Widget resourceSliver,
  WorkResourceTab initialTab = WorkResourceTab.audio,
  WorkResourceSession? session,
  Key? layoutKey,
}) => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: S.localizationsDelegates,
    supportedLocales: S.supportedLocales,
    home: Scaffold(
      body: WorkDetailResponsiveLayout(
        key: layoutKey,
        coverBuilder: (_, __) =>
            const SizedBox(height: 120, child: Text('cover')),
        infoSliver: SliverMainAxisGroup(
          slivers: [
            const SliverToBoxAdapter(
              child: SizedBox(height: 180, child: Text('intro')),
            ),
            WorkResourceTabs(
              workId: 42,
              fileTree: files,
              audioVariants: const PlayerAudioVariantClassifier().scan(files),
              resourceSliver: resourceSliver,
              resourceTitle: 'Files',
              initialTab: initialTab,
              session: session,
              onPlayAudio: (_, __, ___) {},
              onFileTap: (_, __, ___) {},
              onImageTap: (_) {},
              resolveImage: (_) async => null,
            ),
          ],
        ),
      ),
    ),
  ),
);

int _selectedTab(WidgetTester tester) =>
    tester.widget<TabBar>(find.byType(TabBar)).controller!.index;

double _resourceTop(WidgetTester tester) {
  final resourceGroup = tester.renderObject(
    find
        .ancestor(
          of: find.byType(TabBar),
          matching: find.byType(SliverMainAxisGroup),
        )
        .first,
  );
  final viewport = RenderAbstractViewport.maybeOf(resourceGroup)!;
  return viewport.getOffsetToReveal(resourceGroup, 0).offset;
}

ScrollPosition _scrollPosition(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  testWidgets('rotation keeps the selected resource tab', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        files: _files(images: 2),
        resourceSliver: const SliverToBoxAdapter(child: SizedBox(height: 600)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-images-tab')));
    await tester.pumpAndSettle();
    expect(_selectedTab(tester), 2);

    tester.view.physicalSize = const Size(800, 390);
    await tester.pumpAndSettle();

    expect(_selectedTab(tester), 2);

    tester.view.physicalSize = const Size(390, 800);
    await tester.pumpAndSettle();
    expect(_selectedTab(tester), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation restores the active tab resource scroll offset', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        files: _files(),
        resourceSliver: SliverList.builder(
          itemCount: 80,
          itemBuilder: (context, index) =>
              SizedBox(height: 48, child: Text('resource $index')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    expect(_selectedTab(tester), 0);

    final before = _scrollPosition(tester);
    before.jumpTo(_resourceTop(tester) + 420);
    await tester.pump();
    expect(before.pixels - _resourceTop(tester), closeTo(420, 1));

    tester.view.physicalSize = const Size(800, 390);
    await tester.pumpAndSettle();

    expect(_selectedTab(tester), 0);
    final after = _scrollPosition(tester);
    expect(after.pixels - _resourceTop(tester), closeTo(420, 4));

    tester.view.physicalSize = const Size(390, 800);
    await tester.pumpAndSettle();
    expect(_selectedTab(tester), 0);
    final restored = _scrollPosition(tester);
    expect(restored.pixels - _resourceTop(tester), closeTo(420, 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rotation above the resource section stays at the page top', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        files: _files(),
        resourceSliver: SliverList.builder(
          itemCount: 80,
          itemBuilder: (context, index) =>
              SizedBox(height: 48, child: Text('resource $index')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_scrollPosition(tester).pixels, 0);

    tester.view.physicalSize = const Size(800, 390);
    await tester.pumpAndSettle();

    expect(_scrollPosition(tester).pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('session restores tab and scroll after details subtree rebuild', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);
    final session = WorkResourceSession();

    Widget build(Key key) => _app(
      layoutKey: key,
      session: session,
      files: _files(),
      resourceSliver: SliverList.builder(
        itemCount: 80,
        itemBuilder: (context, index) =>
            SizedBox(height: 48, child: Text('resource $index')),
      ),
    );

    await tester.pumpWidget(build(const ValueKey('first')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('work-resource-files-tab')));
    await tester.pumpAndSettle();
    final before = _scrollPosition(tester);
    before.jumpTo(_resourceTop(tester) + 420);
    await tester.pump();
    expect(before.pixels - _resourceTop(tester), closeTo(420, 1));
    expect(session.selectedTab, WorkResourceTab.resources);
    expect(session.reachedResourceTopFor(WorkResourceTab.resources), isTrue);

    await tester.pumpWidget(build(const ValueKey('second')));
    await tester.pumpAndSettle();

    expect(_selectedTab(tester), 0);
    final after = _scrollPosition(tester);
    expect(after.pixels - _resourceTop(tester), closeTo(420, 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('session restores and clamps the image page after a rebuild', (
    tester,
  ) async {
    final session = WorkResourceSession()
      ..selectedTab = WorkResourceTab.images
      ..imagePage = 3;

    Widget build(Key key, int images) => _app(
      layoutKey: key,
      session: session,
      files: _files(images: images),
      resourceSliver: const SliverToBoxAdapter(child: SizedBox()),
    );

    await tester.pumpWidget(build(const ValueKey('first'), 45));
    await tester.pumpAndSettle();
    expect(session.imagePage, 3);

    await tester.pumpWidget(build(const ValueKey('recreated'), 45));
    await tester.pumpAndSettle();
    expect(session.imagePage, 3);

    await tester.pumpWidget(build(const ValueKey('recreated'), 25));
    await tester.pumpAndSettle();
    expect(session.imagePage, 2);
  });
}
