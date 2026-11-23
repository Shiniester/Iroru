import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:iroru/src/models/account.dart';
import 'package:iroru/src/models/history_record.dart';
import 'package:iroru/src/models/work.dart';
import 'package:iroru/src/services/account_database.dart';
import 'package:iroru/src/services/download_path_service.dart';
import 'package:iroru/src/services/history_database.dart';
import 'package:iroru/src/services/storage_service.dart';
import 'package:iroru/src/services/subtitle_database.dart';
import 'package:iroru/src/services/subtitle_library_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

Future<void> _writeFile(Directory root, String relativePath, String value) async {
  final file = File(p.joinAll([root.path, ...relativePath.split('/')]));
  await file.parent.create(recursive: true);
  await file.writeAsString(value);
}

Future<Map<String, String>> _snapshot(Iterable<Directory> roots) async {
  final entries = <String, String>{};
  for (final root in roots) {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final key = '${root.path}|${p.relative(entity.path, from: root.path)}';
      entries[key] = entity is File
          ? 'file:${await entity.readAsString()}'
          : 'other';
    }
  }
  return entries;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('first start uses clean roots and persists new data', () async {
    final root = await Directory.systemTemp.createTemp('iroru-storage-roots-');
    final support = await Directory(p.join(root.path, 'support')).create();
    final documents = await Directory(
      p.join(root.path, 'documents'),
    ).create();
    final originalPathProvider = PathProviderPlatform.instance;
    final pathProvider = _TestPathProvider(support.path, documents.path);
    PathProviderPlatform.instance = pathProvider;
    SharedPreferences.setMockInitialValues({});
    addTearDown(() async {
      await Hive.close();
      PathProviderPlatform.instance = originalPathProvider;
      if (await root.exists()) await root.delete(recursive: true);
    });

    final oldKikoFlu = Directory(p.join(documents.path, 'KikoFlu'));
    final oldIroru = Directory(p.join(documents.path, 'Iroru'));
    final oldDownloads = Directory(p.join(documents.path, 'downloads'));
    await _writeFile(oldKikoFlu, 'accounts.db', 'old account database');
    await _writeFile(oldKikoFlu, 'history.db', 'old history database');
    await _writeFile(oldKikoFlu, 'subtitle_library.db', 'old subtitle database');
    await _writeFile(oldKikoFlu, 'users.hive', 'old hive data');
    await _writeFile(oldIroru, 'downloads/123/old.mp3', 'old interim download');
    await _writeFile(oldIroru, 'history.db', 'old interim history');
    await _writeFile(oldDownloads, '456/old.mp3', 'old default download');
    final oldRoots = [oldKikoFlu, oldIroru, oldDownloads];
    final oldSnapshot = await _snapshot(oldRoots);

    await StorageService.initCritical();
    await StorageService.initSecondary();
    final accounts = AccountDatabase.instance;
    final history = HistoryDatabase.instance;
    final subtitles = SubtitleDatabase.instance;

    expect(await accounts.getAllAccounts(), isEmpty);
    expect(await history.getAllHistory(), isEmpty);
    expect(await subtitles.getAllFiles(), isEmpty);
    expect((await accounts.database).path, p.join(support.path, 'accounts.db'));
    expect(
      (await history.database).path,
      p.join(support.path, 'local_history.db'),
    );
    expect(
      (await subtitles.database).path,
      p.join(support.path, 'subtitle_library.db'),
    );
    expect(Hive.box('users').path, p.join(support.path, 'users.hive'));

    final downloads = await DownloadPathService.getDownloadDirectory();
    final subtitleDirectory =
        await SubtitleLibraryService.getSubtitleLibraryDirectory();
    expect(p.equals(downloads.path, p.join(support.path, 'downloads')), isTrue);
    expect(
      p.equals(
        subtitleDirectory.path,
        p.join(support.path, 'downloads', 'subtitle_library'),
      ),
      isTrue,
    );

    await accounts.createAccount(
      const Account(username: 'user', password: 'pass', host: 'host'),
    );
    await history.addOrUpdate(
      HistoryRecord(
        work: const Work(id: 5, title: 'Saved work'),
        lastPlayedTime: DateTime.utc(2026, 11, 19),
      ),
    );
    await subtitles.insertFiles([
      SubtitleFileRecord(
        fileName: 'saved.srt',
        relativePath: 'saved/saved.srt',
        category: 'saved',
      ),
    ]);
    await StorageService.setUser('account', 'persisted user');

    expect((await accounts.getAllAccounts()).single.username, 'user');
    expect(await history.getPlayedWorkIds([5]), {5});
    expect((await subtitles.getAllFiles()).single['file_name'], 'saved.srt');
    expect(await _snapshot(oldRoots), oldSnapshot);
    expect(pathProvider.documentsCalls, 0);

    await accounts.close();
    await (await history.database).close();
    await (await subtitles.database).close();
    await Hive.close();

    final accountDatabase = await openDatabase(
      p.join(support.path, 'accounts.db'),
      readOnly: true,
    );
    final historyDatabase = await openDatabase(
      p.join(support.path, 'local_history.db'),
      readOnly: true,
    );
    final subtitleDatabase = await openDatabase(
      p.join(support.path, 'subtitle_library.db'),
      readOnly: true,
    );
    final users = await Hive.openBox('users');
    try {
      expect(
        (await accountDatabase.query('accounts')).single['username'],
        'user',
      );
      expect(
        (await historyDatabase.query('local_history')).single['item_id'],
        '5',
      );
      expect(
        (await subtitleDatabase.query('subtitle_files')).single['file_name'],
        'saved.srt',
      );
      expect(users.get('account'), 'persisted user');
    } finally {
      await accountDatabase.close();
      await historyDatabase.close();
      await subtitleDatabase.close();
      await users.close();
    }
  });
}
