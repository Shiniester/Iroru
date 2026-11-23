import 'package:sqflite/sqflite.dart';

import '../models/audio_track.dart';
import '../models/history_record.dart';
import '../models/work.dart';
import 'local_history_database.dart';

class HistoryDatabase {
  static final instance = HistoryDatabase._();
  static const _type = LocalHistoryType.audio;
  final _history = LocalHistoryDatabase.instance;

  HistoryDatabase._();

  Future<Database> get database => _history.database;

  Future<void> addOrUpdate(HistoryRecord record) => _history.save(
    _type,
    LocalHistoryEntry(
      id: record.work.id.toString(),
      position: record.lastPositionMs,
      updatedAt: record.lastPlayedTime,
      details: {
        'work': record.work.toJson(),
        'track': record.lastTrack?.toJson(),
        'playlistIndex': record.playlistIndex,
        'playlistTotal': record.playlistTotal,
      },
    ),
  );

  HistoryRecord _record(LocalHistoryEntry entry) {
    final track = entry.details['track'] as Map<String, dynamic>?;
    return HistoryRecord(
      work: Work.fromJson(entry.details['work'] as Map<String, dynamic>),
      lastPlayedTime: entry.updatedAt,
      lastTrack: track == null ? null : AudioTrack.fromJson(track),
      lastPositionMs: entry.position,
      playlistIndex: entry.details['playlistIndex'] as int,
      playlistTotal: entry.details['playlistTotal'] as int,
    );
  }

  Future<List<HistoryRecord>> getAllHistory({int? limit, int? offset}) async =>
      (await _history.list(
        _type,
        limit: limit,
        offset: offset,
      )).map(_record).toList();

  Future<HistoryRecord?> getHistoryByWorkId(int workId) async {
    final entry = await _history.get(_type, workId.toString());
    return entry == null ? null : _record(entry);
  }

  Future<Set<int>> getPlayedWorkIds(Iterable<int> workIds) async {
    final ids = await _history.existingIds(_type, workIds.map((id) => '$id'));
    return ids.map(int.parse).toSet();
  }

  Future<void> updateWorkMetadata(Work work, {bool Function()? shouldUpdate}) =>
      _history.updateDetails(_type, work.id.toString(), {
        'work': work.toJson(),
      }, shouldUpdate: shouldUpdate);

  Future<int> getHistoryCount() => _history.count(_type);

  Future<void> delete(int workId) => _history.delete(_type, workId.toString());

  Future<void> clear() => _history.clear(_type);
}
