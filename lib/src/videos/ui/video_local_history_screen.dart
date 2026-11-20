import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide LocalHistoryEntry;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../l10n/app_localizations.dart';
import '../../models/download_task.dart';
import '../../providers/auth_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/works_provider.dart';
import '../../services/download_file_path_service.dart';
import '../../services/download_service.dart';
import '../../services/file_preview_resolver.dart';
import '../../services/local_history_database.dart';
import '../../services/storage_service.dart';
import '../../utils/audio_source_headers.dart';
import '../../utils/file_tree_utils.dart';
import '../../utils/snackbar_util.dart';
import '../../utils/string_utils.dart';
import '../../widgets/app_bottom_dock_transition.dart';
import '../../widgets/app_navigation_scope.dart';
import '../../widgets/global_audio_player_wrapper.dart';
import '../../widgets/local_history_card.dart';
import '../../widgets/privacy_blur_cover.dart';
import '../video_browse_preferences.dart';
import '../video_download_task.dart';
import '../video_downloads.dart';
import '../video_library.dart';
import '../video_models.dart';
import '../video_providers.dart';
import 'video_collection_view.dart';
import 'video_details_screen.dart';
import 'work_video_playback_screen.dart';

typedef _ExternalHistoryVideo = ({
  VideoItem video,
  VideoDownloadTask? downloadedTask,
});

typedef _WorkHistoryVideo = ({
  int workId,
  String sourceIdentity,
  String videoId,
  String fileIdentity,
  String fileName,
  String folderPath,
  String? localPath,
});

class VideoLocalHistoryScreen extends ConsumerStatefulWidget {
  const VideoLocalHistoryScreen({super.key});

  @override
  ConsumerState<VideoLocalHistoryScreen> createState() =>
      _VideoLocalHistoryScreenState();
}

class _VideoLocalHistoryScreenState
    extends ConsumerState<VideoLocalHistoryScreen> {
  final ScrollController _scrollController = ScrollController();
  late final VideoLibrary _library;
  late final VideoDownloads _downloads;
  late final Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    _library = ref.read(videoLibraryProvider);
    _downloads = ref.read(videoDownloadsProvider);
    _initialization = _initialize();
  }

  Future<void> _initialize() async {
    await _library.initialize();
    await _downloads.initialize().catchError((Object _) {});
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final layoutType = ref.watch(videoBrowseLayoutProvider);
    ref.watch(videoLibraryProvider);
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(s.localHistory)),
        body: FutureBuilder<void>(
          future: _initialization,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text(s.videoLoadFailed));
            }
            final entries = _library.historyEntries;
            return VideoCollectionView<LocalHistoryEntry>(
              items: entries,
              layoutType: layoutType,
              itemId: (entry) => entry.id,
              itemBuilder: (context, entry, _) =>
                  _historyCard(entry, layoutType),
              controller: _scrollController,
              pageStorageKey: const PageStorageKey<String>(
                'video-local-history',
              ),
              emptyBuilder: (_) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(s.noLocalHistory, textAlign: TextAlign.center),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _historyCard(LocalHistoryEntry entry, LayoutType layoutType) {
    final s = S.of(context);
    final sourceKey = _sourceKey(entry);
    final durationMs = _durationMs(entry);
    final positionMs = entry.position < 0 ? 0 : entry.position;
    final position = formatDuration(Duration(milliseconds: positionMs));
    final progressText = durationMs != null && durationMs > 0
        ? '$position / ${formatDuration(Duration(milliseconds: durationMs))}'
        : position;
    final video = sourceKey == 'work' ? null : _displayVideo(entry, sourceKey);

    return LocalHistoryCard(
      key: ValueKey('video-local-history-${entry.id}'),
      layoutType: layoutType,
      title: _title(entry),
      sourceLabel: _sourceLabel(sourceKey, s),
      cover: video == null
          ? PrivacyBlurCover(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.video_file_outlined)),
              ),
            )
          : VideoCover(video: video),
      onOpen: () => unawaited(_open(entry, resume: false)),
      onResume: () => unawaited(_open(entry, resume: true)),
      resumeLabel: s.resume,
      onRemove: () => unawaited(_confirmRemove(entry)),
      progressText: progressText,
      progressValue: durationMs != null && durationMs > 0
          ? positionMs / durationMs
          : null,
    );
  }

  Future<void> _open(LocalHistoryEntry entry, {required bool resume}) async {
    final workVideo = _workVideo(entry);
    if (workVideo != null) {
      await _openWorkVideo(workVideo);
      return;
    }

    final external = _externalVideo(entry);
    if (external == null) {
      if (mounted) {
        SnackBarUtil.showError(context, S.of(context).videoSourceUnavailable);
      }
      return;
    }
    await pushBottomDockRoute(
      context,
      builder: (_) => VideoDetailsScreen(
        video: external.video,
        downloadedTask: external.downloadedTask,
        autoPlayVideo: resume,
      ),
    );
  }

  Future<void> _openWorkVideo(_WorkHistoryVideo video) async {
    final localPath = await _downloadedWorkVideoPath(video);
    if (!mounted) return;
    final stream = localPath == null ? await _onlineWorkVideo(video) : null;
    if (!mounted) return;
    if (localPath == null && stream == null) {
      final s = S.of(context);
      SnackBarUtil.showError(
        context,
        video.sourceIdentity.startsWith('local:')
            ? s.videoFileNotExist
            : s.videoSourceUnavailable,
      );
      return;
    }
    await pushBottomDockRoute(
      context,
      builder: (_) => WorkVideoPlaybackScreen(
        videoId: video.videoId,
        fileIdentity: video.fileIdentity,
        fileName: video.fileName,
        folderPath: video.folderPath,
        localPath: localPath,
        streams: [if (stream != null) stream],
        appTabIndex: appVideoTabIndex,
      ),
    );
  }

  Future<String?> _downloadedWorkVideoPath(_WorkHistoryVideo video) async {
    try {
      final savedPath = video.localPath;
      final identity = p.normalize(video.fileIdentity);
      final normalizedSavedPath = savedPath == null
          ? null
          : p.normalize(savedPath);
      final tasks = ref.read(downloadServiceProvider).tasks.where((task) {
        return task.workId == video.workId &&
            (p.equals(p.normalize(task.fileName), identity) ||
                (normalizedSavedPath?.endsWith(
                      '${p.separator}${p.normalize(task.fileName)}',
                    ) ??
                    false));
      }).toList();
      if (tasks.isEmpty && savedPath != null) {
        return workVideoSourceIdentity(
                      workId: video.workId,
                      localPath: savedPath,
                    ) ==
                    video.sourceIdentity &&
                File(savedPath).existsSync()
            ? savedPath
            : null;
      }

      tasks.sort(
        (left, right) => (right.completedAt ?? right.createdAt).compareTo(
          left.completedAt ?? left.createdAt,
        ),
      );
      final checkedPaths = <String>{};
      for (final task in tasks) {
        if (task.status != DownloadStatus.completed) continue;
        final relativePath = p.normalize(task.fileName);
        if (!checkedPaths.add(relativePath)) continue;
        if (savedPath != null &&
            !video.sourceIdentity.startsWith('local:') &&
            workVideoSourceIdentity(
                  workId: video.workId,
                  localPath: savedPath,
                  downloadUrl: task.downloadUrl,
                ) !=
                video.sourceIdentity) {
          continue;
        }
        if (savedPath != null &&
            normalizedSavedPath!.endsWith('${p.separator}$relativePath') &&
            _matchesWorkVideoFile(video, task, savedPath)) {
          return savedPath;
        }
        if (!p.equals(relativePath, identity)) continue;
        final downloads = DownloadService.instance;
        final root = await downloads.getDownloadDirectory();
        final standardPath =
            DownloadFilePathService.localPathForWorkRelativePath(
              rootPath: root.path,
              workId: video.workId,
              relativePath: task.fileName,
            );
        if (_matchesWorkVideoFile(video, task, standardPath)) {
          return standardPath;
        }
        final workDirectory = await downloads.getWorkDirectory(video.workId);
        final path = DownloadFilePathService.localPathForRelativePath(
          rootPath: workDirectory.path,
          relativePath: task.fileName,
        );
        if (_matchesWorkVideoFile(video, task, path)) return path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _matchesWorkVideoFile(
    _WorkHistoryVideo video,
    DownloadTask task,
    String path,
  ) =>
      workVideoSourceIdentity(
            workId: video.workId,
            localPath: path,
            downloadUrl: task.downloadUrl,
          ) ==
          video.sourceIdentity &&
      File(path).existsSync();

  Future<VideoStream?> _onlineWorkVideo(_WorkHistoryVideo video) async {
    if (video.sourceIdentity.startsWith('local:')) return null;
    final auth = ref.read(authProvider);
    final host = auth.host ?? '';
    final token = auth.token ?? '';
    if (workVideoSourceIdentity(workId: video.workId, host: host) !=
            video.sourceIdentity ||
        (video.workId >= 0 && (host.isEmpty || token.isEmpty))) {
      return null;
    }

    try {
      final files = await ref
          .read(kikoeruApiServiceProvider)
          .getWorkTracks(video.workId);
      final file = FileTreeUtils.findFolderChildren(files, video.folderPath)
          .where(
            (file) =>
                FileTreeUtils.isVideo(file) &&
                FileTreeUtils.itemPath(video.folderPath, file) ==
                    video.fileIdentity,
          )
          .firstOrNull;
      if (file == null) return null;
      final result =
          await FilePreviewResolver(
            downloadRootPath: () async =>
                (await DownloadService.instance.getDownloadDirectory()).path,
          ).resolveOnlineVideoTarget(
            file: file,
            workId: video.workId,
            host: host,
            token: token,
            downloadedFiles: const {},
            fileRelativePaths: const {},
          );
      if (!mounted || result.status != PreviewVideoTargetStatus.ready) {
        return null;
      }
      final currentAuth = ref.read(authProvider);
      if (currentAuth.host != auth.host || currentAuth.token != auth.token) {
        return null;
      }
      return VideoStream(
        label: video.fileName,
        url: result.requireTarget.source,
        headers: sourceAwareMediaHeaders(
          video.workId,
          accountHeaders: StorageService.serverCookieHeaders,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _confirmRemove(LocalHistoryEntry entry) async {
    final s = S.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.deleteRecord),
        content: Text(s.deletePlayRecordConfirm(_title(entry))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _library.deleteHistory(entry.id);
    } catch (_) {
      if (mounted) SnackBarUtil.showError(context, s.deleteFailed);
    }
  }

  _ExternalHistoryVideo? _externalVideo(LocalHistoryEntry entry) {
    final details = entry.details;
    final storedStorageKey = _string(details['storageKey']);
    final downloadedTask = _downloads.forVideo(
      storedStorageKey?.isNotEmpty == true ? storedStorageKey! : entry.id,
    );
    final sourceKey = _sourceKey(entry, downloadedTask: downloadedTask);
    if (sourceKey != 'missav' && sourceKey != 'jable') return null;

    final videoId = _videoId(entry, sourceKey);
    if (videoId == null || videoId.isEmpty) return null;
    final pageUrl =
        stableVideoHistoryUrl(_string(details['pageUrl'])) ??
        stableVideoHistoryUrl(downloadedTask?.video.pageUrl);
    final downloadedOffline =
        downloadedTask?.status == VideoDownloadStatus.completed &&
        downloadedTask?.localPath?.isNotEmpty == true;
    if (pageUrl == null && !downloadedOffline) return null;

    final cover =
        stableVideoHistoryUrl(_string(details['cover'])) ??
        stableVideoHistoryUrl(downloadedTask?.video.cover) ??
        '';
    final durationMs = _durationMs(entry);
    final video = VideoItem(
      id: videoId,
      sourceKey: sourceKey,
      title: _title(entry),
      pageUrl: pageUrl ?? '',
      cover: cover,
      durationSeconds: durationMs == null ? null : (durationMs / 1000).ceil(),
    );
    return (video: video, downloadedTask: downloadedTask);
  }

  VideoItem _displayVideo(LocalHistoryEntry entry, String sourceKey) {
    final details = entry.details;
    final durationMs = _durationMs(entry);
    return VideoItem(
      id:
          _videoId(entry, sourceKey) ??
          _string(details['storageKey']) ??
          entry.id,
      sourceKey: sourceKey,
      title: _title(entry),
      pageUrl: stableVideoHistoryUrl(_string(details['pageUrl'])) ?? '',
      cover: stableVideoHistoryUrl(_string(details['cover'])) ?? '',
      durationSeconds: durationMs == null ? null : (durationMs / 1000).ceil(),
    );
  }

  _WorkHistoryVideo? _workVideo(LocalHistoryEntry entry) {
    if (!entry.id.startsWith('work:')) return null;
    final parts = entry.id.split(':');
    if (parts.length != 4 || int.tryParse(parts[2]) == null) return null;
    try {
      final sourceIdentity = Uri.decodeComponent(parts[1]);
      final fileIdentity = Uri.decodeComponent(parts[3]);
      return (
        workId: int.parse(parts[2]),
        sourceIdentity: sourceIdentity,
        videoId: entry.id,
        fileIdentity: fileIdentity,
        fileName: _title(entry),
        folderPath: _string(entry.details['folderPath']) ?? '',
        localPath: _string(entry.details['localPath']),
      );
    } on FormatException {
      return null;
    }
  }

  String _sourceKey(
    LocalHistoryEntry entry, {
    VideoDownloadTask? downloadedTask,
  }) =>
      _string(entry.details['sourceKey']) ??
      downloadedTask?.video.sourceKey ??
      (entry.id.startsWith('work:') ? 'work' : 'missav');

  String? _videoId(LocalHistoryEntry entry, String sourceKey) {
    final detailId = _string(entry.details['videoId']);
    if (detailId != null && detailId.isNotEmpty) return detailId;
    final storageKey = _string(entry.details['storageKey']);
    if (storageKey != null && storageKey.isNotEmpty) {
      final prefix = '$sourceKey:';
      return storageKey.startsWith(prefix)
          ? storageKey.substring(prefix.length)
          : storageKey;
    }
    final prefix = '$sourceKey:';
    return entry.id.startsWith(prefix)
        ? entry.id.substring(prefix.length)
        : entry.id;
  }

  String _title(LocalHistoryEntry entry) {
    for (final value in [
      _string(entry.details['title']),
      _string(entry.details['storageKey']),
      _string(entry.details['videoId']),
      entry.id,
    ]) {
      final title = value?.trim();
      if (title != null && title.isNotEmpty) return title;
    }
    return entry.id;
  }

  String _sourceLabel(String sourceKey, S s) {
    if (sourceKey == 'work') return s.navMy;
    for (final source in videoSourceOptions) {
      if (source.key == sourceKey) return source.name;
    }
    return sourceKey;
  }

  int? _durationMs(LocalHistoryEntry entry) =>
      _positiveInt(entry.details['durationMs']) ??
      switch (_positiveInt(entry.details['durationSeconds'])) {
        final seconds? => seconds * 1000,
        null => null,
      };

  static int? _positiveInt(Object? value) {
    final parsed = switch (value) {
      int number => number,
      num number => number.toInt(),
      _ => null,
    };
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static String? _string(Object? value) => switch (value) {
    String text => text,
    num number => number.toString(),
    _ => null,
  };
}
