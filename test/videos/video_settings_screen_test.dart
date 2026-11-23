import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/providers/unified_search_history_provider.dart';
import 'package:iroru/src/providers/works_provider.dart' show LayoutType;
import 'package:iroru/src/videos/jable_mirrors.dart';
import 'package:iroru/src/videos/missav_mirrors.dart';
import 'package:iroru/src/videos/ui/video_settings_screen.dart';
import 'package:iroru/src/videos/video_browse_preferences.dart';
import 'package:iroru/src/videos/video_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('video settings groups account, downloads, search and layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    final s = S.of(tester.element(find.byType(VideoSettingsScreen)));
    expect(find.text(s.playback), findsOneWidget);
    expect(find.text(s.videoInterface), findsOneWidget);
    expect(find.text(s.videoAccountAndSources), findsOneWidget);
    expect(find.text(s.downloadsAndStorage), findsOneWidget);
    expect(find.text(s.searchHistory), findsOneWidget);
    expect(find.text('MissAV'), findsOneWidget);
    expect(find.text('Jable'), findsOneWidget);
    expect(find.text(s.libraryAccount), findsNWidgets(2));
    expect(find.text(s.videoSourceHost), findsNWidgets(2));
    expect(find.text(s.videoAccountSignedOut), findsNWidgets(2));
    expect(find.text(s.videoMirrorAutomatic), findsNWidgets(2));
    expect(find.text(s.videoDownloads), findsOneWidget);
    expect(find.text(s.clearSearchHistory), findsOneWidget);

    await tester.tap(find.text(s.uiSettings));
    await tester.pumpAndSettle();
    expect(find.byType(VideoUiSettingsScreen), findsOneWidget);
    expect(find.text(s.layout), findsOneWidget);

    await tester.tap(find.text(s.layout));
    await tester.pumpAndSettle();
    await tester.tap(find.text(s.layoutList));
    await tester.pumpAndSettle();

    expect(container.read(videoBrowseLayoutProvider), LayoutType.list);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('video_layout_type'), 'list');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shows each saved manual host until that source returns to automatic',
    (tester) async {
      final missav = missavMirrors.first;
      final jable = jableMirrors.first;
      SharedPreferences.setMockInitialValues({
        missavMirrorBaseUrlKey: missav.baseUrl,
        jableMirrorBaseUrlKey: jable.baseUrl,
      });
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      final s = S.of(tester.element(find.byType(VideoSettingsScreen)));
      expect(find.text(missav.host), findsOneWidget);
      expect(find.text(jable.host), findsOneWidget);
      expect(find.text(s.videoMirrorAutomatic), findsNothing);

      final missavClient = container.read(videoClientProvider);
      final saving = missavClient.saveMirrorSelection(null);
      expect(missavClient.usesAutomaticMirror, isTrue);
      await saving;
      await tester.pumpAndSettle();

      expect(find.text(missav.host), findsNothing);
      expect(find.text(jable.host), findsOneWidget);
      expect(find.text(s.videoMirrorAutomatic), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(missavMirrorBaseUrlKey), '');
      expect(preferences.getString(jableMirrorBaseUrlKey), jable.baseUrl);
    },
  );

  testWidgets('video search history clears only video entries', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final history = container.read(unifiedSearchHistoryProvider.notifier);
    await history.addOrReplace(
      const UnifiedSearchHistoryContext(
        contentType: 'video',
        entryScope: 'source-directory',
        source: 'missav',
      ),
      {'keyword': 'video query'},
    );
    await history.addOrReplace(
      const UnifiedSearchHistoryContext(
        contentType: 'comic',
        entryScope: 'library',
        source: 'picacg',
      ),
      {'keyword': 'comic query'},
    );

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    final s = S.of(tester.element(find.byType(VideoSettingsScreen)));
    expect(find.text(s.nItems(1)), findsOneWidget);

    await tester.tap(find.text(s.clearSearchHistory));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
    await tester.pumpAndSettle();

    final entries = container.read(unifiedSearchHistoryProvider).entries;
    expect(
      entries.where((entry) => entry.context.contentType == 'video'),
      isEmpty,
    );
    expect(
      entries.where((entry) => entry.context.contentType == 'comic'),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    home: const VideoSettingsScreen(),
  ),
);
