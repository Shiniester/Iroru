import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/models/history_record.dart';
import 'package:iroru/src/models/work.dart';
import 'package:iroru/src/services/history_database.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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

  test('batch history lookup ignores the former Documents database', () async {
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
    final oldDirectory = await Directory(
      p.join(documents.path, 'KikoFlu'),
    ).create();
    final oldDatabasePath = p.join(oldDirectory.path, 'history.db');
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
      await oldDatabase.insert(
        'history',
        HistoryRecord(
          work: const Work(id: 2, title: 'Former work'),
          lastPlayedTime: now,
          lastPositionMs: 1250,
        ).toMap(),
      );
    } finally {
      await oldDatabase.close();
    }

    await history.addOrUpdate(
      HistoryRecord(
        work: const Work(id: 5, title: 'New work'),
        lastPlayedTime: now,
      ),
    );

    expect(await history.getPlayedWorkIds([1, 2, 3, 5]), {5});
    expect(await history.getPlayedWorkIds(const []), isEmpty);
    expect(await history.getHistoryByWorkId(2), isNull);
    expect((await history.database).path, p.join(support.path, 'history.db'));
    expect(pathProvider.documentsCalls, 0);
    await (await history.database).close();

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
