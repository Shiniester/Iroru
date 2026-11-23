import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/history_record.dart';
import '../models/download_task.dart';
import '../providers/auth_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/history_provider.dart';
import '../services/history_database.dart';
import '../services/audio_player_service.dart';
import '../services/download_service.dart';
import '../services/cache_service.dart';
import '../services/log_service.dart';
import '../services/audio_file_url_resolver.dart';
import '../services/audio_track_queue_builder.dart';
import '../screens/work_detail_screen.dart';
import '../utils/string_utils.dart';
import '../utils/file_tree_utils.dart';
import '../utils/work_cover_prefetch.dart';
import '../utils/snackbar_util.dart';
import '../providers/lyric_provider.dart';
import '../providers/work_card_display_provider.dart';
import '../providers/works_provider.dart' show LayoutType;
import '../utils/age_rating.dart';
import '../utils/collection_grid_layout.dart';
import '../../l10n/app_localizations.dart';
import 'local_history_card.dart';
import 'privacy_blur_cover.dart';
import 'app_bottom_dock_transition.dart';
import 'work_cover_image.dart';
import 'age_rating_chip.dart';

final _log = LogService.instance;

class HistoryWorkCard extends ConsumerWidget {
  final HistoryRecord record;
  final VoidCallback? onTap;
  final LayoutType layoutType;

  const HistoryWorkCard({
    super.key,
    required this.record,
    this.onTap,
    this.layoutType = LayoutType.bigGrid,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';
    final work = record.work;
    final showAgeRating = ref.watch(workCardDisplayProvider).showAgeRating;
    final isList = layoutType == LayoutType.list;
    final titleStyle = localHistoryCardTitleStyle(context);
    final listCoverSize = isList
        ? collectionListCoverSizeForTitle(context, titleStyle: titleStyle)
        : null;
    final listCoverCacheWidth = isList
        ? resolveWorkCoverCacheWidth(
            context,
            crossAxisCount: 1,
            listCoverWidth: listCoverSize!.width,
          )
        : null;

    final coverImage = createWorkCoverImageProvider(
      work: work,
      host: host,
      token: token,
      cacheWidth: listCoverCacheWidth,
    );
    final l10n = S.of(context);
    final track = record.lastTrack;
    final duration = track?.duration ?? Duration.zero;
    final position = formatDuration(
      Duration(milliseconds: record.lastPositionMs),
    );

    return LocalHistoryCard(
      layoutType: layoutType,
      title: work.title,
      sourceLabel: work.sourceLabel,
      cover: PrivacyBlurCover(
        child: WorkCoverImage(
          image: coverImage,
          fadeInDuration: const Duration(milliseconds: 500),
          placeholder: (context) => Container(
            color: Colors.grey[200],
            child: const Center(child: Icon(Icons.image, color: Colors.grey)),
          ),
          errorBuilder: (context, error, stack) => Container(
            color: Colors.grey[200],
            child: const Center(
              child: Icon(Icons.broken_image, color: Colors.grey),
            ),
          ),
        ),
      ),
      coverOverlay: showAgeRating && AgeRatingFormatter.hasValue(work.age)
          ? (scale) => AgeRatingChip(
              age: work.age,
              compact: true,
              fontSize: 10 * scale,
              padding: EdgeInsets.symmetric(
                horizontal: 6 * scale,
                vertical: 2 * scale,
              ),
            )
          : null,
      progressTitle: track?.title ?? l10n.notPlayedYet,
      progressText: track == null
          ? null
          : duration > Duration.zero
          ? '$position / ${formatDuration(duration)}'
          : position,
      progressTrailing: track != null && record.playlistTotal > 0
          ? '${record.playlistIndex + 1} / ${record.playlistTotal}'
          : null,
      progressValue: duration.inMilliseconds > 0
          ? record.lastPositionMs / duration.inMilliseconds
          : null,
      resumeLabel: l10n.resume,
      onResume: track == null ? null : () => _resumePlayback(context, ref),
      onOpen:
          onTap ??
          () => pushWorkDetailRoute(
            context,
            builder: (context) => WorkDetailScreen(
              work: work,
              initialCoverImageProvider: host.isEmpty ? null : coverImage,
            ),
          ),
      onRemove: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.deleteRecord),
          content: Text(l10n.deletePlayRecordConfirm(work.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancel),
            ),
            TextButton(
              onPressed: () {
                ref.read(historyProvider.notifier).remove(work.id);
                Navigator.pop(context);
              },
              child: Text(l10n.delete),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resumePlayback(BuildContext context, WidgetRef ref) async {
    final l10n = S.of(context);
    HistoryRecord? latestRecord;
    try {
      latestRecord = await HistoryDatabase.instance.getHistoryByWorkId(
        record.work.id,
      );
    } catch (e) {
      _log.captureOutput('Failed to load latest history: $e');
      if (context.mounted) {
        SnackBarUtil.showError(context, l10n.playbackFailed(e.toString()));
      }
      return;
    }
    if (!context.mounted) return;
    if (latestRecord == null || latestRecord.lastTrack == null) return;

    final historyRecord = latestRecord;
    final work = historyRecord.work;
    final authState = ref.read(authProvider);
    final host = authState.host ?? '';
    final token = authState.token ?? '';

    // 1. Get all files
    final apiService = ref.read(kikoeruApiServiceProvider);
    apiService.registerJapaneseAsmrWork(work);
    List<dynamic> allFiles = [];
    try {
      allFiles = await apiService.getWorkTracks(work.id);
      ref
          .read(fileListControllerProvider.notifier)
          .updateFiles(allFiles, workId: work.id);
    } catch (e) {
      _log.captureOutput('Failed to update file list: $e');

      // 尝试从已下载的任务中构建文件列表
      try {
        final tasks = await DownloadService.instance.getWorkTasks(work.id);
        if (tasks.isNotEmpty) {
          final downloadedFiles = tasks
              .where((t) => t.status == DownloadStatus.completed)
              .map(
                (t) => {
                  'title': t.fileName,
                  'name': t.fileName,
                  'hash': t.hash,
                  'type': 'file',
                },
              )
              .toList();

          if (downloadedFiles.isNotEmpty) {
            allFiles = downloadedFiles;
            ref
                .read(fileListControllerProvider.notifier)
                .updateFiles(allFiles, workId: work.id);
          }
        }
      } catch (e2) {
        _log.captureOutput('Failed to load downloaded files: $e2');
      }
    }

    if (allFiles.isEmpty) {
      // Fallback to single track if list fetch fails
      try {
        await AudioPlayerService.instance.updateQueue(
          [historyRecord.lastTrack!],
          autoplay: true,
          initialPosition: Duration(milliseconds: historyRecord.lastPositionMs),
        );
        if (AudioPlayerService.instance.isTrackLoading ||
            AudioPlayerService.instance.currentTrack?.id !=
                historyRecord.lastTrack!.id) {
          return;
        }
        ref.read(miniPlayerVisibilityProvider.notifier).show();
        ref.read(historyProvider.notifier).addOrUpdate(work);
      } catch (e) {
        _log.captureOutput('Failed to resume playback: $e');
        if (context.mounted) {
          SnackBarUtil.showError(context, l10n.playbackFailed(e.toString()));
        }
      }
      return;
    }

    // 2. Find the directory containing the last track and get its audio files
    List<dynamic> getSiblingAudioFiles(List<dynamic> files) {
      // Helper to check if a file matches the last track
      bool isTargetFile(dynamic file) {
        if (file['type'] == 'folder') return false;
        final fileHash = file['hash'];
        final fileName = file['title'] ?? file['name'];

        if (historyRecord.lastTrack!.hash != null &&
            fileHash == historyRecord.lastTrack!.hash) {
          return true;
        }
        // Fallback to title match if hash is missing
        return fileName == historyRecord.lastTrack!.title;
      }

      // Helper to extract audio files from a list
      List<dynamic> extractAudioFiles(List<dynamic> list) {
        return list
            .where(
              (file) => file['type'] != 'folder' && FileTreeUtils.isAudio(file),
            )
            .toList();
      }

      // Recursive search
      for (final file in files) {
        if (file['type'] == 'folder') {
          if (file['children'] != null) {
            // Check if target is in this folder's children (direct siblings)
            final children = file['children'] as List<dynamic>;
            if (children.any(isTargetFile)) {
              return extractAudioFiles(children);
            }
            // If not found directly, recurse deeper
            final result = getSiblingAudioFiles(children);
            if (result.isNotEmpty) return result;
          }
        } else {
          // Check if target is in the root list
          if (isTargetFile(file)) {
            return extractAudioFiles(files);
          }
        }
      }

      return [];
    }

    List<dynamic> audioFiles = getSiblingAudioFiles(allFiles);

    // If we couldn't find the specific directory (e.g. file moved/renamed),
    // fallback to flattening all files to ensure playback works
    if (audioFiles.isEmpty) {
      List<dynamic> flattenAudioFiles(List<dynamic> files) {
        final List<dynamic> result = [];
        for (final file in files) {
          if (file['type'] == 'folder') {
            if (file['children'] != null) {
              result.addAll(flattenAudioFiles(file['children']));
            }
          } else if (FileTreeUtils.isAudio(file)) {
            result.add(file);
          }
        }
        return result;
      }

      audioFiles = flattenAudioFiles(allFiles);
    }

    final downloadService = DownloadService.instance;

    // Current work cover URL
    final resolvedCoverUrl = work.getCoverImageUrl(host, token: token);
    final coverUrl = resolvedCoverUrl.isEmpty ? null : resolvedCoverUrl;

    final audioUrlResolver = AudioFileUrlResolver(
      resolveDownloadedPath: downloadService.getDownloadedFilePath,
      downloadRootPath: () async {
        final downloadDir = await downloadService.getDownloadDirectory();
        return downloadDir.path;
      },
      resolveCachedAudioPath: CacheService.getCachedAudioFile,
    );
    final vaNames = work.vas?.map((va) => va.name).toList() ?? [];
    final artistInfo = vaNames.isNotEmpty ? vaNames.join(', ') : null;
    final queue = await const AudioTrackQueueBuilder().build(
      audioFiles: audioFiles,
      selectedFile:
          historyRecord.lastTrack ??
          (audioFiles.isNotEmpty ? audioFiles.first : null),
      resolveUrl: (file) => audioUrlResolver.resolveOnline(
        file: file,
        workId: work.id,
        host: host,
        token: token,
        downloadedFiles: const {},
        fileRelativePaths: const {},
      ),
      workId: work.id,
      albumTitle: work.title,
      unknownTitle: l10n.unknown,
      artist: artistInfo,
      artworkUrl: coverUrl,
    );

    var tracks = queue.tracks;
    var index = queue.startIndex;

    if (tracks.isEmpty && historyRecord.lastTrack != null) {
      tracks = [historyRecord.lastTrack!];
      index = 0;
    }

    // 5. Play
    if (tracks.isNotEmpty) {
      try {
        await AudioPlayerService.instance.updateQueue(
          tracks,
          startIndex: index,
          autoplay: true,
          initialPosition: Duration(milliseconds: historyRecord.lastPositionMs),
        );
        if (AudioPlayerService.instance.isTrackLoading ||
            AudioPlayerService.instance.currentTrack?.id != tracks[index].id) {
          return;
        }
        ref.read(miniPlayerVisibilityProvider.notifier).show();
        ref.read(historyProvider.notifier).addOrUpdate(work);
      } catch (e) {
        _log.captureOutput('Failed to resume playback: $e');
        if (context.mounted) {
          SnackBarUtil.showError(context, l10n.playbackFailed(e.toString()));
        }
      }
    }
  }
}
