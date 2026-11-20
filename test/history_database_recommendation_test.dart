import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/comics/comic_library.dart';
import 'package:iroru/src/comics/comic_models.dart';
import 'package:iroru/src/models/history_record.dart';
import 'package:iroru/src/models/work.dart';
import 'package:iroru/src/services/history_database.dart';
import 'package:iroru/src/services/local_history_database.dart';
import 'package:iroru/src/videos/video_library.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.supportPath, this.documentsPath);

  final String supportPath;
  final String documentsPath;
  var documentsCalls = 0;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentsCalls++;
    return documentsPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('local history starts fresh and isolates media', () async {
    final root = await Directory.systemTemp.createTemp(
      'recommendation-history-',
    );
    final support = await Directory(p.join(root.path, 'support')).create();
    final documents = await Directory(p.join(root.path, 'documents')).create();
    final originalPathProvider = PathProviderPlatform.instance;
    final pathProvider = _TestPathProvider(support.path, documents.path);
    PathProviderPlatform.instance = pathProvider;
    final history = HistoryDatabase.instance;
    addTearDown(() async {
      PathProviderPlatform.instance = originalPathProvider;
      if (await root.exists()) await root.delete(recursive: true);
    });

    final now = DateTime.utc(2026, 10, 8);
    final oldDatabasePath = p.join(support.path, 'history.db');
    final oldDatabase = await openDatabase(
      oldDatabasePath,
      version: 2,
      onCreate: (database, _) => database.execute('''
        CREATE TABLE history (
          work_id INTEGER PRIMARY KEY,
          work_json TEXT NOT NULL,
          last_played_time INTEGER NOT NULL,
          last_track_json TEXT,
          last_position_ms INTEGER DEFAULT 0,
          playlist_index INTEGER DEFAULT 0,
          playlist_total INTEGER DEFAULT 0
        )
      '''),
    );
    try {
      await oldDatabase.insert('history', {
        'work_id': 2,
        'work_json': jsonEncode(
          const Work(id: 2, title: 'Former work').toJson(),
        ),
        'last_played_time': now.millisecondsSinceEpoch,
        'last_position_ms': 1250,
      });
    } finally {
      await oldDatabase.close();
    }

    await history.addOrUpdate(
      HistoryRecord(
        work: const Work(id: 5, title: 'New work'),
        lastPlayedTime: now,
        lastPositionMs: 3500,
        playlistIndex: 2,
        playlistTotal: 4,
      ),
    );
    await history.addOrUpdate(
      HistoryRecord(
        work: const Work(id: -5, title: 'Japanese ASMR', sourceId: 'RJ000005'),
        lastPlayedTime: now.subtract(const Duration(seconds: 1)),
      ),
    );
    final comics = ComicLibrary();
    addTearDown(comics.dispose);
    const comic = Comic(source: 'source', id: '5', title: 'Comic');
    await comics.saveProgress(comic, 'chapter', 7);
    final localHistory = LocalHistoryDatabase.instance;
    SharedPreferences.setMockInitialValues({});
    final videos = VideoLibrary();
    addTearDown(videos.dispose);
    await videos.savePosition('5', const Duration(milliseconds: 1500));

    expect(await history.getPlayedWorkIds([1, 2, 3, -5, 5]), {-5, 5});
    expect(await history.getPlayedWorkIds(const []), isEmpty);
    expect(await history.getHistoryByWorkId(2), isNull);
    expect(
      (await history.database).path,
      p.join(support.path, 'local_history.db'),
    );
    expect(pathProvider.documentsCalls, 0);

    await history.updateWorkMetadata(const Work(id: 5, title: 'Updated work'));
    final updated = (await history.getAllHistory(limit: 1)).single;
    expect(updated.work.title, 'Updated work');
    expect(updated.work.isJapaneseAsmr, isFalse);
    final japanese = (await history.getAllHistory(limit: 1, offset: 1)).single;
    expect(japanese.work.id, -5);
    expect(japanese.work.displayId, 'RJ000005');
    expect(updated.lastPositionMs, 3500);
    expect(updated.playlistIndex, 2);
    expect(updated.playlistTotal, 4);
    expect(
      updated.lastPlayedTime.millisecondsSinceEpoch,
      now.millisecondsSinceEpoch,
    );
    expect(await history.getHistoryCount(), 2);
    expect(
      (await localHistory.list(LocalHistoryType.comic)).single.id,
      comic.key,
    );

    await history.delete(5);
    expect(await history.getHistoryByWorkId(5), isNull);
    expect(await history.getHistoryCount(), 1);
    await history.clear();
    expect(await history.getHistoryCount(), 0);
    expect(await history.getPlayedWorkIds([5]), isEmpty);
    expect((await comics.history()).single.page, 7);
    expect(
      (await localHistory.get(LocalHistoryType.video, '5'))?.position,
      1500,
    );
    await comics.removeHistory(comic);
    expect(await comics.progress(comic), isNull);
    expect(await localHistory.count(LocalHistoryType.video), 1);
    await (await history.database).close();

    final reopened = LocalHistoryDatabase(
      path: p.join(support.path, 'local_history.db'),
    );
    final restoredVideos = VideoLibrary(historyDatabase: reopened);
    try {
      await restoredVideos.initialize();
      expect(
        restoredVideos.positionFor('5'),
        const Duration(milliseconds: 1500),
      );
    } finally {
      restoredVideos.dispose();
      await (await reopened.database).close();
    }

    final preservedOldDatabase = await openDatabase(
      oldDatabasePath,
      readOnly: true,
    );
    try {
      expect(
        (await preservedOldDatabase.query('history')).single['work_id'],
        2,
      );
    } finally {
      await preservedOldDatabase.close();
    }
  });
}
