import 'package:iroru/src/services/local_history_database.dart';

class FakeLocalHistoryDatabase extends LocalHistoryDatabase {
  FakeLocalHistoryDatabase() : super(path: ':memory:');

  final Map<LocalHistoryType, Map<String, LocalHistoryEntry>> _entries = {};

  LocalHistoryEntry? entry(LocalHistoryType type, String id) =>
      _entries[type]?[id];

  @override
  Future<void> save(LocalHistoryType type, LocalHistoryEntry entry) async {
    (_entries[type] ??= {})[entry.id] = entry;
  }

  @override
  Future<List<LocalHistoryEntry>> list(
    LocalHistoryType type, {
    int? limit,
    int? offset,
  }) async {
    final values =
        (_entries[type] ?? const <String, LocalHistoryEntry>{}).values.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    Iterable<LocalHistoryEntry> entries = values;
    if (offset != null) entries = entries.skip(offset);
    if (limit != null) entries = entries.take(limit);
    return entries.toList();
  }

  @override
  Future<void> delete(LocalHistoryType type, String id) async {
    _entries[type]?.remove(id);
  }
}
