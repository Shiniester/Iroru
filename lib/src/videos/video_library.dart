import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/local_history_database.dart';

class VideoLibrary extends ChangeNotifier {
  VideoLibrary({
    SharedPreferences? preferences,
    LocalHistoryDatabase? historyDatabase,
  }) : _providedPreferences = preferences,
       _historyDatabase = historyDatabase ?? LocalHistoryDatabase.instance;

  static const _volumeKey = 'video_volume_v1';

  final SharedPreferences? _providedPreferences;
  final LocalHistoryDatabase _historyDatabase;
  SharedPreferences? _preferences;
  Future<void>? _initializing;
  Future<void> _writeTail = Future<void>.value();
  final Map<String, LocalHistoryEntry> _entries = {};
  final Map<String, LocalHistoryEntry> _pendingEntries = {};
  double _volume = 100;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _load().whenComplete(() => _initializing = null);
  }

  Future<void> _load() async {
    final preferences =
        _providedPreferences ?? await SharedPreferences.getInstance();
    final entries = await _historyDatabase.list(LocalHistoryType.video);
    for (final entry in entries) {
      if (entry.position >= 0) _entries[entry.id] = entry;
    }
    _preferences = preferences;
    final savedVolume = preferences.getDouble(_volumeKey);
    if (savedVolume != null && savedVolume.isFinite) {
      _volume = savedVolume.clamp(0, 100).toDouble();
    }
    _initialized = true;
    _notify();
  }

  Duration positionFor(String videoId) =>
      Duration(milliseconds: _entries[videoId]?.position ?? 0);

  bool hasHistory(String videoId) => _entries.containsKey(videoId);

  List<LocalHistoryEntry> get historyEntries {
    final entries = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(entries);
  }

  Future<void> savePosition(
    String videoId,
    Duration position, {
    Map<String, Object?> details = const {},
  }) async {
    await initialize();
    final milliseconds = position.inMilliseconds < 0
        ? 0
        : position.inMilliseconds;
    await _queueWrite(() async {
      final previous = _pendingEntries[videoId] ?? _entries[videoId];
      final savedDetails = {...?previous?.details, ...details};
      if (previous?.position != milliseconds ||
          !mapEquals(previous?.details, savedDetails)) {
        _pendingEntries[videoId] = LocalHistoryEntry(
          id: videoId,
          position: milliseconds,
          updatedAt: DateTime.now(),
          details: savedDetails,
        );
      }
      for (final entry in _pendingEntries.values.toList()) {
        await _historyDatabase.save(LocalHistoryType.video, entry);
        _pendingEntries.remove(entry.id);
        _entries[entry.id] = entry;
        _notify();
      }
    });
  }

  Future<void> deleteHistory(String videoId) async {
    await initialize();
    await _queueWrite(() async {
      await _historyDatabase.delete(LocalHistoryType.video, videoId);
      _pendingEntries.remove(videoId);
      if (_entries.remove(videoId) != null) _notify();
    });
  }

  double get volume => _volume;

  Future<void> setVolume(double value) async {
    if (!value.isFinite) throw ArgumentError.value(value, 'value');
    await initialize();
    final volume = value.clamp(0, 100).toDouble();
    if (_volume == volume) return;
    _volume = volume;
    await _queueWrite(() => _preferences!.setDouble(_volumeKey, volume));
    _notify();
  }

  Future<void> _queueWrite(Future<void> Function() write) {
    final pending = _writeTail.then((_) => write());
    _writeTail = pending.catchError((_) {});
    return pending;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
