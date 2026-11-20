import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iroru/src/services/local_history_database.dart';
import 'package:iroru/src/videos/video_library.dart';

import 'local_history_database_fake.dart';

class _FailOnceHistoryDatabase extends FakeLocalHistoryDatabase {
  bool _failed = false;

  @override
  Future<void> save(LocalHistoryType type, LocalHistoryEntry entry) async {
    if (!_failed) {
      _failed = true;
      throw StateError('write failed');
    }
    await super.save(type, entry);
  }
}

class _GatedSaveHistoryDatabase extends FakeLocalHistoryDatabase {
  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> releaseSave = Completer<void>();

  @override
  Future<void> save(LocalHistoryType type, LocalHistoryEntry entry) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await releaseSave.future;
    await super.save(type, entry);
  }
}

class _FailDeleteHistoryDatabase extends FakeLocalHistoryDatabase {
  @override
  Future<void> delete(LocalHistoryType type, String id) async {
    throw StateError('delete failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'resume positions and video volume survive reopening on this device',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final historyDatabase = FakeLocalHistoryDatabase();
      final library = VideoLibrary(
        preferences: preferences,
        historyDatabase: historyDatabase,
      );
      await library.initialize();

      await library.savePosition(
        'video-a',
        const Duration(minutes: 2, seconds: 3),
        details: const {'title': 'First video', 'durationMs': 123000},
      );
      await library.savePosition('video-b', const Duration(seconds: 19));
      await library.setVolume(37.5);
      library.dispose();

      final saved = historyDatabase.entry(LocalHistoryType.video, 'video-a')!;
      expect(saved.position, 123000);
      expect(saved.details['title'], 'First video');
      expect(saved.updatedAt.millisecondsSinceEpoch, greaterThan(0));

      final restored = VideoLibrary(
        preferences: preferences,
        historyDatabase: historyDatabase,
      );
      await restored.initialize();
      expect(
        restored.positionFor('video-a'),
        const Duration(minutes: 2, seconds: 3),
      );
      expect(restored.positionFor('video-b'), const Duration(seconds: 19));
      expect(restored.positionFor('unknown'), Duration.zero);
      expect(restored.volume, 37.5);
      restored.dispose();
    },
  );

  test('video volume stays within the media-kit range', () async {
    SharedPreferences.setMockInitialValues({});
    final library = VideoLibrary(
      preferences: await SharedPreferences.getInstance(),
      historyDatabase: FakeLocalHistoryDatabase(),
    );
    await library.initialize();

    await library.setVolume(140);
    expect(library.volume, 100);
    await library.setVolume(-10);
    expect(library.volume, 0);
    library.dispose();
  });

  test('legacy position preferences are ignored and preserved', () async {
    const legacy = '{"legacy":9000}';
    SharedPreferences.setMockInitialValues({
      'video_resume_positions_v1': legacy,
    });
    final preferences = await SharedPreferences.getInstance();
    final library = VideoLibrary(
      preferences: preferences,
      historyDatabase: FakeLocalHistoryDatabase(),
    );
    await library.initialize();

    expect(library.positionFor('legacy'), Duration.zero);
    await library.savePosition('fresh', const Duration(seconds: 4));
    expect(preferences.getString('video_resume_positions_v1'), legacy);
    library.dispose();
  });

  test(
    'a failed write leaves the saved position available for retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final historyDatabase = _FailOnceHistoryDatabase();
      final library = VideoLibrary(historyDatabase: historyDatabase);
      addTearDown(library.dispose);
      const position = Duration(seconds: 4);

      await expectLater(
        library.savePosition('video', position),
        throwsStateError,
      );
      expect(library.positionFor('video'), Duration.zero);

      await library.savePosition('video', position);
      expect(library.positionFor('video'), position);
      expect(
        historyDatabase.entry(LocalHistoryType.video, 'video')?.position,
        4000,
      );
    },
  );

  test('history is newest first and deletion clears the resume cache', () async {
    SharedPreferences.setMockInitialValues({});
    final historyDatabase = FakeLocalHistoryDatabase();
    final library = VideoLibrary(
      preferences: await SharedPreferences.getInstance(),
      historyDatabase: historyDatabase,
    );
    addTearDown(library.dispose);
    final now = DateTime.now();
    await historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: 'older',
        position: 1000,
        updatedAt: now.subtract(const Duration(hours: 1)),
      ),
    );
    await historyDatabase.save(
      LocalHistoryType.video,
      LocalHistoryEntry(
        id: 'newer',
        position: 2000,
        updatedAt: now,
      ),
    );
    await library.initialize();

    expect(library.historyEntries.map((entry) => entry.id), [
      'newer',
      'older',
    ]);

    await library.deleteHistory('older');

    expect(library.positionFor('older'), Duration.zero);
    expect(historyDatabase.entry(LocalHistoryType.video, 'older'), isNull);
    expect(library.historyEntries.map((entry) => entry.id), ['newer']);
  });

  test('deletion prevents an in-flight save from restoring the card', () async {
    SharedPreferences.setMockInitialValues({});
    final historyDatabase = _GatedSaveHistoryDatabase();
    final library = VideoLibrary(
      preferences: await SharedPreferences.getInstance(),
      historyDatabase: historyDatabase,
    );
    addTearDown(library.dispose);

    final save = library.savePosition(
      'video',
      const Duration(seconds: 4),
      details: const {'title': 'Video'},
    );
    await historyDatabase.saveStarted.future;
    final deletion = library.deleteHistory('video');
    historyDatabase.releaseSave.complete();
    await save;
    await deletion;

    expect(library.historyEntries, isEmpty);
    expect(historyDatabase.entry(LocalHistoryType.video, 'video'), isNull);
  });

  test('a failed deletion restores the previous history entry', () async {
    SharedPreferences.setMockInitialValues({});
    final historyDatabase = _FailDeleteHistoryDatabase();
    final library = VideoLibrary(
      preferences: await SharedPreferences.getInstance(),
      historyDatabase: historyDatabase,
    );
    addTearDown(library.dispose);
    await library.savePosition('video', const Duration(seconds: 7));

    await expectLater(
      library.deleteHistory('video'),
      throwsStateError,
    );

    expect(library.positionFor('video'), const Duration(seconds: 7));
    expect(library.historyEntries.single.id, 'video');
  });
}
