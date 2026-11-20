import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

enum LocalHistoryType { audio, comic, video }

class LocalHistoryEntry {
  const LocalHistoryEntry({
    required this.id,
    required this.position,
    required this.updatedAt,
    this.details = const {},
  });

  final String id;
  final int position;
  final DateTime updatedAt;
  final Map<String, Object?> details;
}

class LocalHistoryDatabase {
  LocalHistoryDatabase({this._path});

  static final instance = LocalHistoryDatabase();
  static const _table = 'local_history';
  static const _byItem = 'media_type = ? AND item_id = ?';

  final String? _path;
  Future<Database>? _database;

  Future<Database> get database =>
      _database ??= _open().onError<Object>((error, stackTrace) {
        _database = null;
        Error.throwWithStackTrace(error, stackTrace);
      });

  Future<Database> _open() async {
    var path = _path;
    if (path == null) {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      path = p.join(directory.path, 'local_history.db');
    }
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE local_history (
            media_type TEXT NOT NULL,
            item_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            details TEXT NOT NULL,
            PRIMARY KEY (media_type, item_id)
          )
        ''');
        await db.execute('''
          CREATE INDEX local_history_recent
          ON local_history (media_type, updated_at DESC, item_id)
        ''');
      },
    );
  }

  LocalHistoryEntry _entry(Map<String, Object?> row) => LocalHistoryEntry(
    id: row['item_id'] as String,
    position: row['position'] as int,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    details: jsonDecode(row['details'] as String) as Map<String, Object?>,
  );

  Future<void> save(LocalHistoryType type, LocalHistoryEntry entry) async {
    final db = await database;
    await db.insert(_table, {
      'media_type': type.name,
      'item_id': entry.id,
      'position': entry.position,
      'updated_at': entry.updatedAt.millisecondsSinceEpoch,
      'details': jsonEncode(entry.details),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<LocalHistoryEntry>> list(
    LocalHistoryType type, {
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: 'media_type = ?',
      whereArgs: [type.name],
      orderBy: 'updated_at DESC, item_id',
      limit: limit ?? (offset == null ? null : -1),
      offset: offset,
    );
    return rows.map(_entry).toList();
  }

  Future<LocalHistoryEntry?> get(LocalHistoryType type, String id) async {
    final db = await database;
    final rows = await db.query(
      _table,
      where: _byItem,
      whereArgs: [type.name, id],
      limit: 1,
    );
    return rows.isEmpty ? null : _entry(rows.single);
  }

  Future<Set<String>> existingIds(
    LocalHistoryType type,
    Iterable<String> ids,
  ) async {
    final keys = ids.toSet();
    if (keys.isEmpty) return {};
    final placeholders = List.filled(keys.length, '?').join(',');
    final db = await database;
    final rows = await db.query(
      _table,
      columns: ['item_id'],
      where: 'media_type = ? AND item_id IN ($placeholders)',
      whereArgs: [type.name, ...keys],
    );
    return rows.map((row) => row['item_id'] as String).toSet();
  }

  Future<void> updateDetails(
    LocalHistoryType type,
    String id,
    Map<String, Object?> details, {
    bool Function()? shouldUpdate,
  }) async {
    final db = await database;
    final args = [type.name, id];
    await db.transaction((txn) async {
      final rows = await txn.query(
        _table,
        columns: ['details'],
        where: _byItem,
        whereArgs: args,
      );
      if (rows.isEmpty || shouldUpdate?.call() == false) return;
      final existing =
          jsonDecode(rows.single['details'] as String) as Map<String, Object?>;
      await txn.update(
        _table,
        {
          'details': jsonEncode({...existing, ...details}),
        },
        where: _byItem,
        whereArgs: args,
      );
    });
  }

  Future<int> count(LocalHistoryType type) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) FROM local_history WHERE media_type = ?',
      [type.name],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> delete(LocalHistoryType type, String id) async {
    final db = await database;
    await db.delete(_table, where: _byItem, whereArgs: [type.name, id]);
  }

  Future<void> clear(LocalHistoryType type) async {
    final db = await database;
    await db.delete(_table, where: 'media_type = ?', whereArgs: [type.name]);
  }
}
