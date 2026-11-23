import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UpdateChannel { stable, beta }

typedef FileOpener =
    Future<OpenResult> Function(String filePath, {String? type});

typedef ProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      ProcessStartMode mode,
      bool runInShell,
    });

/// Service to check for app updates from GitHub releases and install them.
class UpdateService {
  static const String _releaseRepository = 'Shiniester/Iroru';
  static const String _releasesGithubApiUrl =
      'https://api.github.com/repos/$_releaseRepository/releases';
  static const String _stableGithubApiUrl = '$_releasesGithubApiUrl/latest';
  static const String _releasePageUrl =
      'https://github.com/$_releaseRepository/releases/latest';
  static const String _androidPackageName = 'com.meteor.iroru';
  static const List<String> _downloadMirrors = [
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
  ];
  static const Duration _defaultDownloadTimeout = Duration(seconds: 60);
  static final RegExp _betaVersion = RegExp(r'^\d+\.\d+\.\d+-beta\.\d+$');

  static const String _keyUpdateChannel = 'update_channel';
  static const String _keyLastCheckedVersion = 'last_checked_version';
  static const String _keyLastNotifiedVersion = 'last_notified_version';
  static const String _keyLastCheckTime = 'last_check_time';
  static const String _keyLastReleaseNotes = 'last_release_notes';
  static const String _keyLastDownloadUrl = 'last_download_url';
  static const String _keyLastAssetName = 'last_asset_name';
  static const String _keyLastAssetSize = 'last_asset_size';
  static const String _keyLastAssetDigest = 'last_asset_digest';
  static const String _keyLastReleaseUrl = 'last_release_url';

  int _channelRevision = 0;
  int _checkRevision = 0;
  Future<void> _channelWriteTail = Future<void>.value();
  Future<void> _cacheWriteTail = Future<void>.value();

  int get channelRevision => _channelRevision;

  final Dio _dio;
  final FileOpener _openFile;
  final ProcessStarter _processStarter;
  final Future<Directory> Function() _getTempDirectory;
  final Abi? _androidAbi;
  final Duration _downloadTimeout;

  UpdateService({
    Dio? dio,
    FileOpener? openFile,
    ProcessStarter? processStarter,
    Future<Directory> Function()? getTempDirectory,
    Abi? androidAbi,
    Duration? downloadTimeout,
  }) : _dio = dio ?? Dio(),
       _openFile = openFile ?? OpenFilex.open,
       _processStarter = processStarter ?? Process.start,
       _getTempDirectory = getTempDirectory ?? getTemporaryDirectory,
       _androidAbi =
           androidAbi ?? (!kIsWeb && Platform.isAndroid ? Abi.current() : null),
       _downloadTimeout = downloadTimeout ?? _defaultDownloadTimeout;

  Future<UpdateChannel> getUpdateChannel({String? currentVersion}) async {
    final prefs = await SharedPreferences.getInstance();
    final savedChannel = prefs.getString(_keyUpdateChannel);
    for (final channel in UpdateChannel.values) {
      if (savedChannel == channel.name) return channel;
    }

    currentVersion ??= (await PackageInfo.fromPlatform()).version;
    return _betaVersion.hasMatch(currentVersion)
        ? UpdateChannel.beta
        : UpdateChannel.stable;
  }

  Future<void> setUpdateChannel(UpdateChannel channel) {
    final channelRevision = ++_channelRevision;
    final previous = _channelWriteTail;
    final completed = Completer<void>();
    _channelWriteTail = completed.future;

    return () async {
      try {
        await previous;
        if (channelRevision != _channelRevision) return;
        final prefs = await SharedPreferences.getInstance();
        var saved = false;
        try {
          saved = await prefs.setString(_keyUpdateChannel, channel.name);
        } finally {
          if (!saved) await prefs.reload();
        }
        if (!saved) throw StateError('Could not save the update channel');
      } finally {
        completed.complete();
      }
    }();
  }

  /// Returns the selected channel's release when one is available.
  /// Request failures are propagated to the caller.
  Future<UpdateInfo?> checkForUpdates({
    bool force = false,
    UpdateChannel? channel,
  }) async {
    final checkRevision = ++_checkRevision;
    final channelRevision = _channelRevision;
    final currentVersion = (await PackageInfo.fromPlatform()).version;
    final prefs = await SharedPreferences.getInstance();
    final selectedChannel =
        channel ?? await getUpdateChannel(currentVersion: currentVersion);
    if (!_isCurrentCheck(checkRevision, channelRevision)) return null;
    final checkedAtKey = _cacheKey(_keyLastCheckTime, selectedChannel);
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastCheckedVersion = _cachedVersion(prefs, selectedChannel);

    if (!force &&
        lastCheckedVersion != null &&
        now - (prefs.getInt(checkedAtKey) ?? 0) < 3600000) {
      if (lastCheckedVersion.isEmpty || lastCheckedVersion == currentVersion) {
        return null;
      }

      return UpdateInfo(
        latestVersion: lastCheckedVersion,
        currentVersion: currentVersion,
        releaseUrl:
            prefs.getString(_cacheKey(_keyLastReleaseUrl, selectedChannel)) ??
            _releasePageUrl,
        hasNewVersion: _compareVersions(currentVersion, lastCheckedVersion) < 0,
        releaseNotes: prefs.getString(
          _cacheKey(_keyLastReleaseNotes, selectedChannel),
        ),
        downloadUrl: prefs.getString(
          _cacheKey(_keyLastDownloadUrl, selectedChannel),
        ),
        assetName: prefs.getString(
          _cacheKey(_keyLastAssetName, selectedChannel),
        ),
        assetSize: prefs.getInt(_cacheKey(_keyLastAssetSize, selectedChannel)),
        assetDigest: prefs.getString(
          _cacheKey(_keyLastAssetDigest, selectedChannel),
        ),
      );
    }

    final data = await _fetchRelease(selectedChannel);
    if (!_isCurrentCheck(checkRevision, channelRevision)) return null;
    if (data == null) {
      await _cacheIfCurrent(
        checkRevision,
        channelRevision,
        () => _cacheNoRelease(prefs, selectedChannel),
      );
      return null;
    }

    final latestVersion = _normalizeVersion(data['tag_name'] as String? ?? '');
    if (latestVersion.isEmpty) {
      throw const FormatException('Release tag has no version');
    }

    final releaseNotes = data['body'] as String?;
    final releaseUrl = data['html_url'] as String? ?? _releasePageUrl;
    final matchedAsset = _findReleaseAsset(data);
    final downloadUrl = matchedAsset?['browser_download_url'] as String?;
    final assetName = matchedAsset?['name'] as String?;
    final assetSize = matchedAsset?['size'] as int?;
    final assetDigest = matchedAsset?['digest'] as String?;

    await _cacheIfCurrent(
      checkRevision,
      channelRevision,
      () => _cacheRelease(
        prefs,
        selectedChannel,
        latestVersion: latestVersion,
        releaseUrl: releaseUrl,
        releaseNotes: releaseNotes,
        downloadUrl: downloadUrl,
        assetName: assetName,
        assetSize: assetSize,
        assetDigest: assetDigest,
      ),
    );
    if (!_isCurrentCheck(checkRevision, channelRevision)) return null;

    return UpdateInfo(
      latestVersion: latestVersion,
      currentVersion: currentVersion,
      releaseUrl: releaseUrl,
      hasNewVersion: _compareVersions(currentVersion, latestVersion) < 0,
      releaseNotes: releaseNotes,
      downloadUrl: downloadUrl,
      assetName: assetName,
      assetSize: assetSize,
      assetDigest: assetDigest,
    );
  }

  Future<Map<String, dynamic>?> _fetchRelease(UpdateChannel channel) async {
    final options = Options(
      headers: {'Accept': 'application/vnd.github.v3+json'},
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
    );

    if (channel == UpdateChannel.stable) {
      final response = await _dio.get(_stableGithubApiUrl, options: options);
      if (response.data is! Map<String, dynamic>) {
        throw const FormatException('Invalid stable release response');
      }
      final data = response.data as Map<String, dynamic>;
      if (data['draft'] == true || data['prerelease'] == true) return null;
      if (_androidAbi != null && _findReleaseAsset(data) == null) {
        return null;
      }
      return data;
    }

    var page = 1;
    Map<String, dynamic>? newestRelease;
    String newestTag = '';
    while (true) {
      final response = await _dio.get(
        _releasesGithubApiUrl,
        queryParameters: {'per_page': 100, 'page': page},
        options: options,
      );
      if (response.data is! List<dynamic>) {
        throw const FormatException('Invalid beta releases response');
      }
      final releases = response.data as List<dynamic>;
      for (final release in releases.whereType<Map<String, dynamic>>()) {
        if (release['draft'] == true || release['prerelease'] != true) continue;
        final tag = _normalizeVersion(release['tag_name'] as String? ?? '');
        if (!_betaVersion.hasMatch(tag) ||
            (_androidAbi != null && _findReleaseAsset(release) == null)) {
          continue;
        }
        if (newestRelease == null || _compareVersions(newestTag, tag) < 0) {
          newestRelease = release;
          newestTag = tag;
        }
      }
      if (releases.length < 100) break;
      page++;
    }
    return newestRelease;
  }

  Map<String, dynamic>? _findReleaseAsset(Map<String, dynamic> release) {
    final assets = release['assets'] as List<dynamic>? ?? [];
    final androidAbi = _androidAbi;
    if (androidAbi == null) return findPlatformAsset(assets);

    final candidates = assets.whereType<Map<String, dynamic>>().where(
      (asset) => _isAndroidUpdateAsset(asset['name'] as String?),
    );
    return findPlatformAsset(
      candidates.toList(),
      targetPlatform: 'android',
      targetAbi: androidAbi,
    );
  }

  String _normalizeVersion(String version) => version
      .replaceFirst(RegExp(r'^v'), '')
      .replaceFirst(RegExp(r'\(.*\)'), '')
      .trim();

  bool _isAndroidUpdateAsset(String? name) =>
      _androidAbi == Abi.androidArm64 &&
      name != null &&
      name.endsWith('_$_androidPackageName.apk');

  String _cacheKey(String key, UpdateChannel channel) =>
      '${key}_${channel.name}';

  String? _cachedVersion(SharedPreferences prefs, UpdateChannel channel) {
    final version = prefs.getString(_cacheKey(_keyLastCheckedVersion, channel));
    if (version == null || version.isEmpty || _androidAbi == null) {
      return version;
    }
    final assetName = prefs.getString(_cacheKey(_keyLastAssetName, channel));
    return _isAndroidUpdateAsset(assetName) ? version : null;
  }

  bool _isCurrentCheck(int checkRevision, int channelRevision) =>
      checkRevision == _checkRevision && channelRevision == _channelRevision;

  Future<void> _cacheIfCurrent(
    int checkRevision,
    int channelRevision,
    Future<void> Function() write,
  ) {
    final previous = _cacheWriteTail;
    final completed = Completer<void>();
    _cacheWriteTail = completed.future;

    return () async {
      try {
        await previous;
        if (!_isCurrentCheck(checkRevision, channelRevision)) return;
        await write();
      } finally {
        completed.complete();
      }
    }();
  }

  Future<void> _cacheRelease(
    SharedPreferences prefs,
    UpdateChannel channel, {
    required String latestVersion,
    required String releaseUrl,
    required String? releaseNotes,
    required String? downloadUrl,
    required String? assetName,
    required int? assetSize,
    required String? assetDigest,
  }) async {
    final assetSizeKey = _cacheKey(_keyLastAssetSize, channel);
    // Update all in-memory fields before yielding to a channel change.
    await Future.wait([
      prefs.setString(
        _cacheKey(_keyLastCheckedVersion, channel),
        latestVersion,
      ),
      prefs.setInt(
        _cacheKey(_keyLastCheckTime, channel),
        DateTime.now().millisecondsSinceEpoch,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastReleaseUrl, channel),
        releaseUrl,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastReleaseNotes, channel),
        releaseNotes,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastDownloadUrl, channel),
        downloadUrl,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastAssetName, channel),
        assetName,
      ),
      _setOptionalString(
        prefs,
        _cacheKey(_keyLastAssetDigest, channel),
        assetDigest,
      ),
      assetSize == null
          ? prefs.remove(assetSizeKey)
          : prefs.setInt(assetSizeKey, assetSize),
    ]);
  }

  Future<void> _cacheNoRelease(
    SharedPreferences prefs,
    UpdateChannel channel,
  ) async {
    await Future.wait([
      prefs.setString(_cacheKey(_keyLastCheckedVersion, channel), ''),
      prefs.setInt(
        _cacheKey(_keyLastCheckTime, channel),
        DateTime.now().millisecondsSinceEpoch,
      ),
      for (final key in [
        _keyLastReleaseUrl,
        _keyLastReleaseNotes,
        _keyLastDownloadUrl,
        _keyLastAssetName,
        _keyLastAssetSize,
        _keyLastAssetDigest,
      ])
        prefs.remove(_cacheKey(key, channel)),
    ]);
  }

  Future<bool> _setOptionalString(
    SharedPreferences prefs,
    String key,
    String? value,
  ) => value == null || value.isEmpty
      ? prefs.remove(key)
      : prefs.setString(key, value);

  /// Match the corresponding release asset for the current operating system.
  Map<String, dynamic>? findPlatformAsset(
    List<dynamic> assets, {
    String? targetPlatform,
    Abi? targetAbi,
  }) {
    final os = targetPlatform ?? (kIsWeb ? 'web' : Platform.operatingSystem);
    final assetList = assets.whereType<Map<String, dynamic>>().toList();
    if (assetList.isEmpty) return null;

    Map<String, dynamic>? result;
    switch (os) {
      case 'android':
        if ((targetAbi ?? Abi.current()) != Abi.androidArm64) return null;
        result = assetList.firstWhere((asset) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          return name.endsWith('.apk') && name.contains('arm64-v8a');
        }, orElse: () => <String, dynamic>{});
        break;
      case 'windows':
        result = assetList.firstWhere(
          (a) {
            final name = (a['name'] as String? ?? '').toLowerCase();
            return name.contains('setup') && name.endsWith('.exe');
          },
          orElse: () => assetList.firstWhere(
            (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.exe'),
            orElse: () => <String, dynamic>{},
          ),
        );
        break;
      case 'macos':
        if ((targetAbi ?? Abi.current()) != Abi.macosArm64) return null;
        result = assetList.firstWhere(
          (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.dmg'),
          orElse: () => <String, dynamic>{},
        );
        break;
      case 'linux':
        final architecture = switch (targetAbi ?? Abi.current()) {
          Abi.linuxX64 => 'x64',
          Abi.linuxArm64 => 'arm64',
          _ => null,
        };
        if (architecture == null) return null;
        result = assetList.firstWhere((a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return name.contains('linux-$architecture') &&
              name.endsWith('.tar.gz');
        }, orElse: () => <String, dynamic>{});
        break;
      case 'ios':
        result = assetList.firstWhere(
          (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.ipa'),
          orElse: () => <String, dynamic>{},
        );
        break;
      default:
        return null;
    }

    return result.isNotEmpty ? result : null;
  }

  /// Download the update package to the local updates directory.
  ///
  /// Tries the official download URL first, then each built-in mirror in
  /// order, attempting every address once. A cancelled download stops the
  /// chain without falling back. When GitHub supplied a SHA-256 digest, every
  /// candidate must match it. Without a valid digest, only the official URL is
  /// tried.
  Future<File> downloadUpdate({
    required String downloadUrl,
    required String fileName,
    String? assetDigest,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    Directory? targetDirectory,
  }) async {
    final saveDir =
        targetDirectory ??
        Directory(p.join((await _getTempDirectory()).path, 'updates'));
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }

    final expectedDigest = _parseSha256Digest(assetDigest);
    final candidates = <String>[
      downloadUrl,
      if (expectedDigest != null)
        for (final mirror in _downloadMirrors) _mirrorUrl(downloadUrl, mirror),
    ];
    final downloadDirectory = await saveDir.createTemp('.${fileName}_');
    final finalPath = p.join(downloadDirectory.path, fileName);

    Exception? lastError;
    var completed = false;
    try {
      for (var i = 0; i < candidates.length; i++) {
        final tempFile = File(p.join(downloadDirectory.path, '$i.part'));

        try {
          await _downloadAttempt(
            candidates[i],
            tempFile.path,
            cancelToken: cancelToken,
            onProgress: onProgress,
          );
          _throwIfCancelled(cancelToken);
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel &&
              cancelToken?.isCancelled == true) {
            rethrow;
          }
          lastError = e;
          continue;
        } on Exception catch (e) {
          lastError = e;
          continue;
        }

        if (!await tempFile.exists() || await tempFile.length() == 0) {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
          lastError = FileSystemException(
            'Downloaded file is empty or missing',
            tempFile.path,
          );
          continue;
        }

        if (expectedDigest != null &&
            !await _hasMatchingDigest(tempFile, expectedDigest)) {
          _throwIfCancelled(cancelToken);
          await tempFile.delete();
          lastError = const FormatException(
            'Update does not match the GitHub SHA-256 digest',
          );
          continue;
        }

        _throwIfCancelled(cancelToken);
        final result = await tempFile.rename(finalPath);
        _throwIfCancelled(cancelToken);
        completed = true;
        return result;
      }
    } finally {
      if (!completed && await downloadDirectory.exists()) {
        await downloadDirectory.delete(recursive: true);
      }
    }

    throw lastError ?? Exception('Update download failed');
  }

  /// Runs one download attempt and aborts it when no bytes arrive for
  /// [_downloadTimeout]. Dio's receive timeout only covers the response
  /// headers, so the body needs this stall guard. A stall cancels the
  /// underlying connection so the next attempt starts from a clean file.
  Future<void> _downloadAttempt(
    String url,
    String tempPath, {
    required CancelToken? cancelToken,
    required void Function(int received, int total)? onProgress,
  }) async {
    final attemptToken = CancelToken();
    if (cancelToken != null) {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      cancelToken.whenCancel.then((error) {
        if (!attemptToken.isCancelled) attemptToken.cancel(error.error);
      });
    }

    Timer? stallTimer;
    var stalled = false;
    void resetStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(_downloadTimeout, () {
        stalled = true;
        if (!attemptToken.isCancelled) {
          attemptToken.cancel('Update download stalled');
        }
      });
    }

    resetStallTimer();
    try {
      await _dio.download(
        url,
        tempPath,
        cancelToken: attemptToken,
        options: Options(
          receiveTimeout: _downloadTimeout,
          sendTimeout: _downloadTimeout,
        ),
        onReceiveProgress: (received, total) {
          resetStallTimer();
          onProgress?.call(received, total);
        },
      );
    } on DioException catch (e) {
      if (cancelToken?.isCancelled == true) rethrow;
      if (stalled && e.type == DioExceptionType.cancel) {
        throw TimeoutException(
          'Update download stalled',
          _downloadTimeout,
        );
      }
      rethrow;
    } finally {
      stallTimer?.cancel();
    }
  }

  String _mirrorUrl(String downloadUrl, String mirror) => '$mirror$downloadUrl';

  String? _parseSha256Digest(String? digest) {
    final match = RegExp(
      r'^sha256:([0-9a-fA-F]{64})$',
    ).firstMatch(digest ?? '');
    return match?.group(1)?.toLowerCase();
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) {
      throw cancelToken!.cancelError!;
    }
  }

  Future<bool> _hasMatchingDigest(File file, String expectedDigest) async {
    final actualDigest = (await sha256.bind(file.openRead()).single).toString();
    return actualDigest == expectedDigest;
  }

  /// Launch or install the downloaded update package.
  Future<bool> installUpdate(String filePath, {String? targetPlatform}) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return false;
    }

    final os = targetPlatform ?? (kIsWeb ? 'web' : Platform.operatingSystem);

    if (os == 'windows' && filePath.endsWith('.exe')) {
      try {
        await _processStarter(
          filePath,
          [],
          runInShell: true,
          mode: ProcessStartMode.detached,
        );
        return true;
      } catch (_) {
        final result = await _openFile(filePath);
        return result.type == ResultType.done;
      }
    }

    if (os == 'android') {
      final result = await _openFile(
        filePath,
        type: 'application/vnd.android.package-archive',
      );
      return result.type == ResultType.done;
    }

    final result = await _openFile(filePath);
    return result.type == ResultType.done;
  }

  /// Check if the red dot should be shown for the current latest version
  /// Returns true if a new version exists and hasn't been notified yet
  Future<bool> shouldShowRedDot({UpdateChannel? channel}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final currentVersion = (await PackageInfo.fromPlatform()).version;
      final selectedChannel =
          channel ?? await getUpdateChannel(currentVersion: currentVersion);
      final lastCheckedVersion = _cachedVersion(prefs, selectedChannel);
      final lastNotifiedVersion = prefs.getString(
        _cacheKey(_keyLastNotifiedVersion, selectedChannel),
      );

      if (lastCheckedVersion == null || lastCheckedVersion.isEmpty) {
        return false;
      }

      return _compareVersions(currentVersion, lastCheckedVersion) < 0 &&
          lastCheckedVersion != lastNotifiedVersion;
    } catch (e) {
      return false;
    }
  }

  /// Mark the current new version as notified (hide red dot)
  Future<void> markAsNotified({UpdateChannel? channel}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final selectedChannel = channel ?? await getUpdateChannel();
      final lastCheckedVersion = _cachedVersion(prefs, selectedChannel);
      if (lastCheckedVersion != null && lastCheckedVersion.isNotEmpty) {
        await prefs.setString(
          _cacheKey(_keyLastNotifiedVersion, selectedChannel),
          lastCheckedVersion,
        );
      }
    } catch (e) {
      // Silent failure
    }
  }

  /// Compare two version strings
  /// Returns: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
  int _compareVersions(String v1, String v2) {
    final pattern = RegExp(
      r'^(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    );
    final match1 = pattern.firstMatch(v1);
    final match2 = pattern.firstMatch(v2);
    if (match1 == null || match2 == null) {
      return _compareNumericVersions(v1, v2);
    }

    final core1 = match1.group(1)!.split('.').map(int.parse).toList();
    final core2 = match2.group(1)!.split('.').map(int.parse).toList();
    for (
      var i = 0;
      i < (core1.length > core2.length ? core1.length : core2.length);
      i++
    ) {
      final part1 = i < core1.length ? core1[i] : 0;
      final part2 = i < core2.length ? core2[i] : 0;
      if (part1 != part2) return part1.compareTo(part2);
    }

    final prerelease1 = match1.group(2)?.split('.');
    final prerelease2 = match2.group(2)?.split('.');
    if (prerelease1 == null) return prerelease2 == null ? 0 : 1;
    if (prerelease2 == null) return -1;
    for (var i = 0; i < prerelease1.length && i < prerelease2.length; i++) {
      final part1 = prerelease1[i];
      final part2 = prerelease2[i];
      final number1 = int.tryParse(part1);
      final number2 = int.tryParse(part2);
      if (number1 != null && number2 != null) {
        if (number1 != number2) return number1.compareTo(number2);
      } else if (number1 != null) {
        return -1;
      } else if (number2 != null) {
        return 1;
      } else if (part1 != part2) {
        return part1.compareTo(part2);
      }
    }
    return prerelease1.length.compareTo(prerelease2.length);
  }

  int _compareNumericVersions(String v1, String v2) {
    final parts1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (
      var i = 0;
      i < (parts1.length > parts2.length ? parts1.length : parts2.length);
      i++
    ) {
      final part1 = i < parts1.length ? parts1[i] : 0;
      final part2 = i < parts2.length ? parts2[i] : 0;
      if (part1 != part2) return part1.compareTo(part2);
    }
    return 0;
  }

  /// Clear all update check data
  Future<void> clearUpdateData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final channel in UpdateChannel.values) {
        for (final key in [
          _keyLastCheckedVersion,
          _keyLastNotifiedVersion,
          _keyLastCheckTime,
          _keyLastReleaseNotes,
          _keyLastDownloadUrl,
          _keyLastAssetName,
          _keyLastAssetSize,
          _keyLastAssetDigest,
          _keyLastReleaseUrl,
        ]) {
          await prefs.remove(_cacheKey(key, channel));
        }
      }
      for (final key in [
        _keyLastCheckedVersion,
        _keyLastNotifiedVersion,
        _keyLastCheckTime,
        _keyLastReleaseNotes,
        _keyLastDownloadUrl,
        _keyLastAssetName,
        _keyLastAssetSize,
        _keyLastAssetDigest,
      ]) {
        await prefs.remove(key);
      }
    } catch (e) {
      // Silent failure
    }
  }
}

/// Information about available updates
class UpdateInfo {
  final String latestVersion;
  final String currentVersion;
  final String releaseUrl;
  final bool hasNewVersion;
  final String? releaseNotes;
  final String? downloadUrl;
  final String? assetName;
  final int? assetSize;
  final String? assetDigest;

  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.releaseUrl,
    required this.hasNewVersion,
    this.releaseNotes,
    this.downloadUrl,
    this.assetName,
    this.assetSize,
    this.assetDigest,
  });

  @override
  String toString() {
    return 'UpdateInfo(latest: $latestVersion, current: $currentVersion, hasNew: $hasNewVersion, downloadUrl: $downloadUrl, assetName: $assetName, size: $assetSize)';
  }
}
