import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../services/local_history_database.dart';
import 'comic_models.dart';

class ComicLibrary extends ChangeNotifier {
  ComicLibrary({this.databaseOpener, LocalHistoryDatabase? historyDatabase})
    : _history = historyDatabase ?? LocalHistoryDatabase.instance;

  static const _historyType = LocalHistoryType.comic;

  final Future<Database> Function()? databaseOpener;
  final LocalHistoryDatabase _history;
  Future<Database>? _database;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<Database> get database =>
      _database ??= databaseOpener?.call() ?? _openDatabase();
  Future<Database> _openDatabase() async {
    final dir = await getApplicationSupportDirectory();
    await Directory(dir.path).create(recursive: true);
    return openDatabase(
      p.join(dir.path, 'comics.db'),
      version: 1,
      onCreate: createSchema,
    );
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute(
      'CREATE TABLE favorites (id TEXT PRIMARY KEY, comic TEXT NOT NULL, updated INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE downloads (id TEXT PRIMARY KEY, task TEXT NOT NULL)',
    );
  }

  Future<List<Comic>> favorites() async => (await (await database).query(
    'favorites',
    orderBy: 'updated DESC',
  )).map((r) => Comic.fromJson(jsonDecode(r['comic'] as String))).toList();
  Future<bool> isFavorite(Comic comic) async => (await (await database).query(
    'favorites',
    where: 'id = ?',
    whereArgs: [comic.key],
  )).isNotEmpty;
  Future<void> favorite(Comic comic, bool value) async {
    final db = await database;
    if (value) {
      await db.insert('favorites', {
        'id': comic.key,
        'comic': jsonEncode(comic.toJson()),
        'updated': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } else {
      await db.delete('favorites', where: 'id = ?', whereArgs: [comic.key]);
    }
    _notify();
  }

  Future<void> saveProgress(
    Comic comic,
    String chapter,
    int page, {
    int? pageCount,
  }) async {
    final exactPageCount = pageCount != null && pageCount > 0
        ? pageCount
        : null;
    await _history.save(
      _historyType,
      LocalHistoryEntry(
        id: comic.key,
        position: page,
        updatedAt: DateTime.now(),
        details: {
          'comic': comic.toJson(),
          'chapter': chapter,
          if (exactPageCount != null) 'pageCount': exactPageCount,
        },
      ),
    );
    _notify();
  }

  ComicProgress _progress(LocalHistoryEntry entry) => ComicProgress(
    Comic.fromJson(entry.details['comic'] as Map<String, dynamic>),
    entry.details['chapter'] as String,
    entry.position,
    entry.updatedAt,
    pageCount: switch (entry.details['pageCount']) {
      final int value when value > 0 => value,
      _ => null,
    },
  );

  Future<ComicProgress?> progress(Comic comic) async {
    final entry = await _history.get(_historyType, comic.key);
    return entry == null ? null : _progress(entry);
  }

  Future<List<ComicProgress>> history() async =>
      (await _history.list(_historyType)).map(_progress).toList();

  Future<void> removeHistory(Comic comic) async {
    await _history.delete(_historyType, comic.key);
    _notify();
  }

  Future<List<Map<String, dynamic>>> loadTasks() async =>
      (await (await database).query('downloads'))
          .map(
            (r) => Map<String, dynamic>.from(jsonDecode(r['task'] as String)),
          )
          .toList();
  Future<void> saveTask(String id, Map<String, dynamic> task) async {
    await (await database).insert('downloads', {
      'id': id,
      'task': jsonEncode(task),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteTask(String id) async {
    await (await database).delete(
      'downloads',
      where: 'id = ?',
      whereArgs: [id],
    );
    _notify();
  }
}
