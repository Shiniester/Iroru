import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide LocalHistoryEntry;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/models/download_task.dart';
import 'package:iroru/src/models/download_task_change.dart';
import 'package:iroru/src/providers/audio_provider.dart';
import 'package:iroru/src/providers/auth_provider.dart';
import 'package:iroru/src/providers/download_provider.dart';
import 'package:iroru/src/providers/works_provider.dart';
import 'package:iroru/src/services/kikoeru_api_service.dart'
    show KikoeruApiService;
import 'package:iroru/src/services/local_history_database.dart';
import 'package:iroru/src/services/storage_service.dart';
import 'package:iroru/src/videos/missav_client.dart';
import 'package:iroru/src/videos/ui/video_details_screen.dart';
import 'package:iroru/src/videos/ui/video_local_history_screen.dart';
import 'package:iroru/src/videos/ui/work_video_playback_screen.dart';
import 'package:iroru/src/videos/video_browse_preferences.dart';
import 'package:iroru/src/videos/video_download_task.dart';
import 'package:iroru/src/videos/video_downloads.dart';
import 'package:iroru/src/videos/video_library.dart';
import 'package:iroru/src/videos/video_models.dart';
import 'package:iroru/src/videos/video_providers.dart';
import 'package:iroru/src/widgets/app_navigation_scope.dart';
import 'package:iroru/src/widgets/local_history_card.dart';

import 'local_history_database_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('cards use collection layouts and show saved progress', (
    tester,
  ) async {
    final fixture = await _fixture();
    final now = DateTime.now();
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: 'jable:recent',
        position: 42000,
        updatedAt: now.subtract(const Duration(minutes: 3)),
        details: const {
          'title': 'Recent Jable video',
          'sourceKey': 'jable',
          'videoId': 'recent',
          'storageKey': 'jable:recent',
          'pageUrl': 'https://jable.tv/videos/recent/',
        },
      ),
    );
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: 'missav-progress',
        position: 123000,
        updatedAt: now.subtract(const Duration(hours: 2)),
        details: const {
          'title': 'MissAV progress video',
          'sourceKey': 'missav',
          'videoId': 'missav-progress',
          'storageKey': 'missav-progress',
          'pageUrl': 'https://missav.ai/en/missav-progress',
          'durationMs': 300000,
        },
      ),
    );
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: 'fallback-video',
        position: 5000,
        updatedAt: now.subtract(const Duration(days: 2)),
        details: const {
          'sourceKey': 'missav',
          'pageUrl': 'https://missav.ai/en/fallback-video',
        },
      ),
    );

    await tester.pumpWidget(_app(fixture));
    await tester.pumpAndSettle();
    var cards = tester.widgetList<LocalHistoryCard>(
      find.byType(LocalHistoryCard),
    );

    expect(cards.map((card) => card.title), [
      'Recent Jable video',
      'MissAV progress video',
      'fallback-video',
    ]);
    expect(cards.map((card) => card.sourceLabel), [
      'Jable',
      'MissAV',
      'MissAV',
    ]);
    expect(find.text('02:03 / 05:00'), findsOneWidget);
    expect(find.text('00:42'), findsOneWidget);
    expect(
      cards.every((card) => card.layoutType == LayoutType.bigGrid),
      isTrue,
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(VideoLocalHistoryScreen)),
    );
    await container
        .read(videoBrowseLayoutProvider.notifier)
        .setLayout(LayoutType.list);
    await tester.pump();
    cards = tester.widgetList<LocalHistoryCard>(find.byType(LocalHistoryCard));
    expect(cards.every((card) => card.layoutType == LayoutType.list), isTrue);

    await container
        .read(videoBrowseLayoutProvider.notifier)
        .setLayout(LayoutType.smallGrid);
    await tester.pump();
    cards = tester.widgetList<LocalHistoryCard>(find.byType(LocalHistoryCard));
    expect(
      cards.every((card) => card.layoutType == LayoutType.smallGrid),
      isTrue,
    );
  });

  testWidgets('opening a card passes its downloaded task to video details', (
    tester,
  ) async {
    final fixture = await _fixture();
    const video = VideoItem(
      id: 'downloaded-history',
      title: 'Downloaded history',
      pageUrl: 'https://missav.ai/en/downloaded-history',
      durationSeconds: 300,
    );
    final task = VideoDownloadTask(
      id: video.storageKey,
      video: video,
      quality: 'Source',
      isHls: false,
      status: VideoDownloadStatus.completed,
      progress: 1,
      localPath: '/downloads/downloaded-history.mp4',
    );
    fixture.downloads.register(task);
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: video.storageKey,
        position: 123000,
        updatedAt: DateTime.now(),
        details: const {
          'title': 'Downloaded history',
          'sourceKey': 'missav',
          'videoId': 'downloaded-history',
          'storageKey': 'downloaded-history',
          'pageUrl': 'https://missav.ai/en/downloaded-history',
          'durationMs': 300000,
        },
      ),
    );

    await tester.pumpWidget(_app(fixture));
    await tester.pumpAndSettle();
    tester
        .widget<LocalHistoryCard>(
          find.byKey(const ValueKey('video-local-history-downloaded-history')),
        )
        .onOpen();
    await _pumpUntilFound(tester, find.byType(VideoDetailsScreen));

    final details = tester.widget<VideoDetailsScreen>(
      find.byType(VideoDetailsScreen),
    );
    expect(details.autoPlayVideo, isFalse);
    expect(details.downloadedTask, same(task));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('resume opens video details with automatic playback', (
    tester,
  ) async {
    final fixture = await _fixture();
    const video = VideoItem(
      id: 'resume-history',
      title: 'Resume history',
      pageUrl: 'https://missav.ai/en/resume-history',
    );
    fixture.downloads.register(
      VideoDownloadTask(
        id: video.storageKey,
        video: video,
        quality: 'Source',
        isHls: false,
        status: VideoDownloadStatus.completed,
        progress: 1,
        localPath: '/downloads/resume-history.mp4',
      ),
    );
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: video.storageKey,
        position: 60000,
        updatedAt: DateTime.now(),
        details: const {
          'title': 'Resume history',
          'sourceKey': 'missav',
          'videoId': 'resume-history',
          'storageKey': 'resume-history',
          'pageUrl': 'https://missav.ai/en/resume-history',
        },
      ),
    );

    await tester.pumpWidget(_app(fixture));
    await tester.pumpAndSettle();
    final card = find.byKey(
      const ValueKey('video-local-history-resume-history'),
    );
    tester.widget<LocalHistoryCard>(card).onResume!();
    await _pumpUntilFound(tester, find.byType(VideoDetailsScreen));

    final details = tester.widget<VideoDetailsScreen>(
      find.byType(VideoDetailsScreen),
    );
    expect(details.autoPlayVideo, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('long press confirmation removes history and resume position', (
    tester,
  ) async {
    final fixture = await _fixture();
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: 'remove-history',
        position: 90000,
        updatedAt: DateTime.now(),
        details: const {
          'title': 'Remove history',
          'sourceKey': 'missav',
          'videoId': 'remove-history',
          'pageUrl': 'https://missav.ai/en/remove-history',
        },
      ),
    );

    await tester.pumpWidget(_app(fixture));
    await tester.pumpAndSettle();
    final s = S.of(tester.element(find.byType(VideoLocalHistoryScreen)));
    final card = find.byKey(
      const ValueKey('video-local-history-remove-history'),
    );
    await tester.longPress(card);
    await tester.pumpAndSettle();

    expect(find.text(s.deleteRecord), findsOneWidget);
    expect(
      find.text(s.deletePlayRecordConfirm('Remove history')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, s.delete));
    await tester.pumpAndSettle();

    expect(card, findsNothing);
    expect(find.text(s.noLocalHistory), findsOneWidget);
    expect(
      fixture.historyDatabase.entry(LocalHistoryType.video, 'remove-history'),
      isNull,
    );
    expect(fixture.library.positionFor('remove-history'), Duration.zero);
  });

  testWidgets('work video without its local file shows the existing error', (
    tester,
  ) async {
    final fixture = await _fixture();
    final directory = Directory.systemTemp.createTempSync(
      'iroru-video-history-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final missingPath =
        '${directory.path}${Platform.pathSeparator}missing-video.mp4';
    final videoId = workVideoPlaybackId(
      sourceIdentity: 'local:$missingPath',
      workId: 42,
      fileIdentity: 'chapter/video.mp4',
    );
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: videoId,
        position: 30000,
        updatedAt: DateTime.now(),
        details: {
          'title': 'Missing work video',
          'sourceKey': 'work',
          'fileIdentity': 'chapter/video.mp4',
          'folderPath': 'chapter',
          'localPath': missingPath,
        },
      ),
    );

    await tester.pumpWidget(_app(fixture));
    await tester.pumpAndSettle();
    final s = S.of(tester.element(find.byType(VideoLocalHistoryScreen)));
    final card = find.byKey(ValueKey('video-local-history-$videoId'));
    await tester.runAsync(() async {
      tester.widget<LocalHistoryCard>(card).onOpen();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await _pumpUntilFound(tester, find.text(s.videoFileNotExist));
  });

  testWidgets('work history playback stays on the video app tab', (
    tester,
  ) async {
    final fixture = await _fixture(gateWorkInitialization: true);
    final directory = Directory.systemTemp.createTempSync(
      'iroru-video-history-play-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}video.mp4';
    File(path).writeAsBytesSync(const [0]);
    final videoId = workVideoPlaybackId(
      sourceIdentity: 'local:$path',
      workId: 42,
      fileIdentity: 'chapter/video.mp4',
    );
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: videoId,
        position: 30000,
        updatedAt: DateTime.now(),
        details: {
          'title': 'Local work video',
          'sourceKey': 'work',
          'fileIdentity': 'chapter/video.mp4',
          'folderPath': 'chapter',
          'localPath': path,
        },
      ),
    );

    await tester.pumpWidget(_app(fixture));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('video-local-history-$videoId')));
    await _pumpUntilFound(tester, find.byType(WorkVideoPlaybackScreen));
    expect(
      tester
          .widget<WorkVideoPlaybackScreen>(find.byType(WorkVideoPlaybackScreen))
          .appTabIndex,
      appVideoTabIndex,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('work history resumes online instead of opening a reused path', (
    tester,
  ) async {
    final fixture = await _fixture(gateWorkInitialization: true);
    final preferences = await SharedPreferences.getInstance();
    await StorageService.initCritical(preferences: preferences);
    final directory = Directory.systemTemp.createTempSync(
      'iroru-video-history-reused-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path =
        '${directory.path}${Platform.pathSeparator}chapter'
        '${Platform.pathSeparator}video.mp4';
    final replacement = File(path);
    replacement.parent.createSync();
    replacement.writeAsBytesSync(const [0]);
    const source = 'https://original.example';
    final videoId = workVideoPlaybackId(
      sourceIdentity: source,
      workId: 42,
      fileIdentity: 'chapter/video.mp4',
    );
    await fixture.historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: videoId,
        position: 30000,
        updatedAt: DateTime.now(),
        details: {
          'title': 'Online work video',
          'sourceKey': 'work',
          'folderPath': 'chapter',
          'localPath': path,
        },
      ),
    );
    await tester.pumpWidget(
      _app(
        fixture,
        auth: const AuthState(host: source, token: 'test-token'),
        workTasks: [
          DownloadTask(
            id: 'original',
            workId: 42,
            workTitle: 'Original work',
            fileName: 'chapter/video.mp4',
            downloadUrl: '$source/api/media/download/original-hash',
            createdAt: DateTime.utc(2026, 1, 1),
            status: DownloadStatus.completed,
          ),
          DownloadTask(
            id: 'replacement',
            workId: 42,
            workTitle: 'Another work',
            fileName: 'chapter/video.mp4',
            downloadUrl:
                'https://different.example/api/media/download/replacement',
            createdAt: DateTime.utc(2026, 1, 2),
            status: DownloadStatus.completed,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(ValueKey('video-local-history-$videoId'));
    tester.widget<LocalHistoryCard>(card).onResume!();
    await _pumpUntilFound(tester, find.byType(WorkVideoPlaybackScreen));

    final player = tester.widget<WorkVideoPlaybackScreen>(
      find.byType(WorkVideoPlaybackScreen),
    );
    expect(player.videoId, videoId);
    expect(player.localPath, isNull);
    expect(
      player.streams.single.url,
      '$source/api/media/stream/original-hash?token=test-token',
    );
    expect(fixture.library.positionFor(videoId), const Duration(seconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Expected widget did not appear: $finder');
}

Widget _app(
  _HistoryFixture fixture, {
  AuthState auth = const AuthState(),
  List<DownloadTask> workTasks = const [],
}) => ProviderScope(
  overrides: [
    authProvider.overrideWith((ref) => _HistoryAuth(auth)),
    kikoeruApiServiceProvider.overrideWith((ref) => _WorkVideoApi()),
    downloadServiceProvider.overrideWithValue(_WorkDownloads(workTasks)),
    videoClientProvider.overrideWith((ref) => fixture.client),
    videoLibraryProvider.overrideWith((ref) => fixture.library),
    videoDownloadsProvider.overrideWith((ref) => fixture.downloads),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    home: const VideoLocalHistoryScreen(),
  ),
);

class _HistoryAuth extends StateNotifier<AuthState> implements AuthNotifier {
  _HistoryAuth(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WorkVideoApi extends KikoeruApiService {
  @override
  Future<List<dynamic>> getWorkTracks(
    int workId, {
    bool forceRefresh = false,
  }) async => const [
    {
      'type': 'folder',
      'title': 'chapter',
      'children': [
        {'type': 'video', 'title': 'video.mp4', 'hash': 'original-hash'},
      ],
    },
  ];
}

class _WorkDownloads extends Fake implements DownloadTaskRepository {
  _WorkDownloads(this.tasks);

  @override
  final List<DownloadTask> tasks;
}

class _HistoryFixture {
  _HistoryFixture({
    required this.client,
    required this.library,
    required this.downloads,
    required this.historyDatabase,
  });

  final MissavClient client;
  final VideoLibrary library;
  final _HistoryDownloads downloads;
  final FakeLocalHistoryDatabase historyDatabase;
}

Future<_HistoryFixture> _fixture({bool gateWorkInitialization = false}) async {
  final historyDatabase = FakeLocalHistoryDatabase();
  final preferences = await SharedPreferences.getInstance();
  final library = gateWorkInitialization
      ? _GatedWorkInitializationVideoLibrary(
          preferences: preferences,
          historyDatabase: historyDatabase,
        )
      : VideoLibrary(
          preferences: preferences,
          historyDatabase: historyDatabase,
        );
  final client = MissavClient();
  final downloads = _HistoryDownloads(client: client, library: library);
  return _HistoryFixture(
    client: client,
    library: library,
    downloads: downloads,
    historyDatabase: historyDatabase,
  );
}

class _GatedWorkInitializationVideoLibrary extends VideoLibrary {
  _GatedWorkInitializationVideoLibrary({
    required super.preferences,
    required super.historyDatabase,
  });

  final Completer<void> _workInitialization = Completer<void>();
  int _initializeCalls = 0;

  @override
  Future<void> initialize() {
    _initializeCalls++;
    if (_initializeCalls > 1) return _workInitialization.future;
    return super.initialize();
  }
}

class _HistoryDownloads extends VideoDownloads {
  _HistoryDownloads({required super.client, required super.library});

  final Map<String, VideoDownloadTask> _registered = {};

  void register(VideoDownloadTask task) {
    _registered[task.id] = task;
  }

  @override
  Future<void> initialize() async {}

  @override
  VideoDownloadTask? forVideo(String videoId) => _registered[videoId];
}
