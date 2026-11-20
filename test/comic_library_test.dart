import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart' as sqlite;
import 'package:iroru/src/comics/comic_library.dart';
import 'package:iroru/src/comics/comic_models.dart';
import 'package:iroru/src/comics/comic_downloads.dart';
import 'package:iroru/src/services/local_history_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final native = Platform.environment['KIKOFLU_TEST_SQLITE'];
  if (native != null) {
    sqlite.open.overrideFor(
      sqlite.OperatingSystem.windows,
      () => DynamicLibrary.open(native),
    );
  }
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  late Database db;
  late Directory historyDirectory;
  late LocalHistoryDatabase historyDatabase;
  late ComicLibrary library;
  setUp(() async {
    db = await databaseFactoryFfiNoIsolate.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: ComicLibrary.createSchema,
      ),
    );
    historyDirectory = await Directory.systemTemp.createTemp('comic-history-');
    historyDatabase = LocalHistoryDatabase(
      path: p.join(historyDirectory.path, 'local_history.db'),
    );
    library = ComicLibrary(
      databaseOpener: () => Future.value(db),
      historyDatabase: historyDatabase,
    );
  });
  tearDown(() async {
    library.dispose();
    await (await historyDatabase.database).close();
    await db.close();
    await historyDirectory.delete(recursive: true);
  });
  test(
    'same IDs from different sources keep independent favorites and progress',
    () async {
      const a = Comic(source: 'picacg', id: '42', title: 'A');
      const b = Comic(source: 'nhentai', id: '42', title: 'B');
      await library.favorite(a, true);
      await library.favorite(b, true);
      await library.saveProgress(a, '2', 7, pageCount: 20);
      await library.saveProgress(b, '42', 18);
      expect((await library.favorites()).length, 2);
      expect((await library.progress(a))!.page, 7);
      expect((await library.progress(a))!.pageCount, 20);
      expect((await library.progress(b))!.page, 18);
      expect((await library.progress(b))!.pageCount, isNull);
      await library.favorite(a, false);
      expect(await library.isFavorite(b), true);
      final restarted = ComicLibrary(historyDatabase: historyDatabase);
      expect((await restarted.progress(a))!.chapterId, '2');
      expect((await restarted.progress(a))!.pageCount, 20);
      restarted.dispose();
    },
  );
  test(
    'restoring an interrupted download pauses it instead of calling it complete',
    () async {
      final task = ComicDownloadTask(
        comic: const Comic(source: 'nhentai', id: '42', title: 'A'),
        chapter: const ComicChapter('42', '1'),
        directory: 'unused',
        status: ComicDownloadStatus.downloading,
        pages: const [ComicPage('https://example/1')],
        completed: 0,
      );
      await library.saveTask(task.id, task.toJson());
      final downloads = ComicDownloads(
        library,
        (_) => throw StateError('offline restore must not request a source'),
      );
      await downloads.ready;
      expect(downloads.tasks.single.status, ComicDownloadStatus.paused);
      expect(downloads.completedComics, isEmpty);
      downloads.dispose();
    },
  );
}
