import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'missav_mirrors.dart';

class VideoMirrorSelection {
  VideoMirrorSelection(this._lookup, this._lastGoodKey);

  final MissavMirror? Function(String?) _lookup;
  final String _lastGoodKey;
  SharedPreferences? _preferences;
  String? _preferred;
  String? _lastGood;
  String? _measured;
  bool _probeFinished = false;

  bool get probeFinished => _probeFinished;
  String? get preferred => _preferred;
  String? get initial => _preferred ?? _lastGood;
  String? get automaticProbe => _preferred == null ? _measured : null;

  Iterable<String> get prioritized => {
    if (_preferred case final preferred?) preferred,
    if (automaticProbe case final measured?) measured,
    if (_lastGood case final lastGood?) lastGood,
  };

  void restore(SharedPreferences preferences, MissavMirror? preferred) {
    _preferences = preferences;
    _preferred ??= preferred?.baseUrl;
    final saved = preferences.getString(_lastGoodKey);
    final lastGood = _lookup(saved)?.baseUrl;
    _lastGood ??= lastGood;
    if (saved != null && saved.isNotEmpty && lastGood == null) {
      unawaited(_saveLastGood(null));
    }
  }

  bool select(MissavMirror? mirror) {
    final baseUrl = mirror?.baseUrl;
    if (_preferred == baseUrl) return false;
    _preferred = baseUrl;
    return true;
  }

  List<MissavMirror> probeCandidates(Iterable<String> baseUrls) => {
    if (_lastGood case final lastGood?) lastGood,
    ...baseUrls,
  }.map(_lookup).whereType<MissavMirror>().take(3).toList();

  void acceptProbeResults(List<MissavMirrorLatency> results) {
    _probeFinished = true;
    _measured = results
        .where((result) => result.isAvailable)
        .firstOrNull
        ?.mirror
        .baseUrl;
  }

  void remember(String baseUrl) {
    if (_lastGood == baseUrl || _lookup(baseUrl) == null) return;
    _lastGood = baseUrl;
    unawaited(_saveLastGood(baseUrl));
  }

  bool forget(String baseUrl) {
    if (_measured == baseUrl) _measured = null;
    if (_lastGood != baseUrl) return false;
    _lastGood = null;
    unawaited(_saveLastGood(null));
    return true;
  }

  Future<void> _saveLastGood(String? baseUrl) async {
    try {
      await _preferences?.setString(_lastGoodKey, baseUrl ?? '');
    } catch (_) {
      // Keep selecting in memory when writing preferences fails.
    }
  }
}

bool isVideoMirrorConnectionFailure(DioException error) => switch (error.type) {
  DioExceptionType.connectionTimeout ||
  DioExceptionType.sendTimeout ||
  DioExceptionType.receiveTimeout ||
  DioExceptionType.connectionError ||
  DioExceptionType.badCertificate => true,
  DioExceptionType.unknown => error.error is IOException,
  _ => false,
};
