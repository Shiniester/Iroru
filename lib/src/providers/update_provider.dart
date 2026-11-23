import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/update_service.dart';

export '../services/update_service.dart'
    show UpdateChannel, UpdateInfo, UpdateService;

/// Provider for the update service singleton
final updateServiceProvider = Provider<UpdateService>((ref) {
  return UpdateService();
});

/// Provider for update information
final updateInfoProvider = StateProvider<UpdateInfo?>((ref) => null);

/// Provider to track if red dot should be shown (only when not notified yet)
final showUpdateRedDotProvider = StateProvider<bool>((ref) => false);

/// Provider to track if there's a new version available (regardless of notification status)
final hasNewVersionProvider = StateProvider<bool>((ref) => false);

enum UpdateCheckOutcome { available, upToDate, noBetaRelease, failed, stale }

class UpdateCheckResult {
  const UpdateCheckResult(this.outcome, [this.updateInfo]);

  final UpdateCheckOutcome outcome;
  final UpdateInfo? updateInfo;
}

enum UpdateCheckState {
  idle,
  automatic,
  manual;

  bool get isChecking => this != idle;
  bool get isCheckingManually => this == manual;
}

/// Coordinates update checks and owns all writes to the app-wide update state.
class UpdateCheckController extends StateNotifier<UpdateCheckState> {
  UpdateCheckController(this._updateService, this._ref)
    : super(UpdateCheckState.idle);

  final UpdateService _updateService;
  final Ref _ref;

  int _requestId = 0;
  int _selectionId = 0;
  UpdateChannel? _activeChannel;
  UpdateChannel? _selectedChannel;
  bool _channelSelectionPending = false;
  int? _readRequestId;

  UpdateChannel? get selectedChannel => _selectedChannel;

  Future<UpdateCheckResult> checkForUpdates({
    bool force = false,
    bool autoCheck = false,
    UpdateChannel? channel,
  }) async {
    if (!mounted ||
        (autoCheck && (state.isCheckingManually || _channelSelectionPending))) {
      return const UpdateCheckResult(UpdateCheckOutcome.stale);
    }
    final requestId = ++_requestId;
    _activeChannel = channel;
    state = autoCheck ? UpdateCheckState.automatic : UpdateCheckState.manual;

    var channelRevision = _updateService.channelRevision;
    try {
      final selectedChannel =
          channel ?? await _updateService.getUpdateChannel();
      if (!_isCurrent(requestId, channelRevision)) {
        return const UpdateCheckResult(UpdateCheckOutcome.stale);
      }
      if (_selectedChannel != null && selectedChannel != _selectedChannel) {
        return const UpdateCheckResult(UpdateCheckOutcome.stale);
      }
      _selectedChannel ??= selectedChannel;
      _activeChannel = selectedChannel;
      channelRevision = _updateService.channelRevision;

      final updateInfo = await _updateService.checkForUpdates(
        force: force,
        channel: selectedChannel,
      );
      if (!_isCurrent(requestId, channelRevision)) {
        return const UpdateCheckResult(UpdateCheckOutcome.stale);
      }

      final available = updateInfo?.hasNewVersion == true;
      final shouldShowRedDot = autoCheck && available
          ? await _updateService.shouldShowRedDot(channel: selectedChannel)
          : false;
      if (!_isCurrent(requestId, channelRevision)) {
        return const UpdateCheckResult(UpdateCheckOutcome.stale);
      }

      final alreadyRead = _readRequestId == requestId;
      _publish(updateInfo, available, shouldShowRedDot && !alreadyRead);
      if (available && (!autoCheck || alreadyRead)) {
        await _markAsNotified(selectedChannel);
        if (!_isCurrent(requestId, channelRevision)) {
          return const UpdateCheckResult(UpdateCheckOutcome.stale);
        }
      }

      if (available) {
        return UpdateCheckResult(UpdateCheckOutcome.available, updateInfo);
      }
      return UpdateCheckResult(
        selectedChannel == UpdateChannel.beta && updateInfo == null
            ? UpdateCheckOutcome.noBetaRelease
            : UpdateCheckOutcome.upToDate,
      );
    } catch (_) {
      if (!_isCurrent(requestId, channelRevision)) {
        return const UpdateCheckResult(UpdateCheckOutcome.stale);
      }
      return const UpdateCheckResult(UpdateCheckOutcome.failed);
    } finally {
      if (_isCurrent(requestId, channelRevision)) {
        state = UpdateCheckState.idle;
        _activeChannel = null;
        if (_readRequestId == requestId) _readRequestId = null;
      }
    }
  }

  Future<UpdateCheckResult> selectUpdateChannel(
    UpdateChannel channel, {
    void Function()? onSaved,
  }) async {
    final selectionId = ++_selectionId;
    final previousChannel = _selectedChannel;
    ++_requestId;
    _readRequestId = null;
    _selectedChannel = channel;
    _channelSelectionPending = true;
    state = UpdateCheckState.idle;
    _publish(null, false, false);
    _ref.read(updateControllerProvider.notifier).reset();

    try {
      await _updateService.setUpdateChannel(channel);
    } catch (_) {
      if (!mounted) return const UpdateCheckResult(UpdateCheckOutcome.stale);
      final isCurrentSelection = selectionId == _selectionId;
      final wasCancelled =
          !_channelSelectionPending && _selectedChannel == channel;
      if (!isCurrentSelection && !wasCancelled) {
        return const UpdateCheckResult(UpdateCheckOutcome.stale);
      }
      _selectedChannel = previousChannel;
      _channelSelectionPending = false;
      return isCurrentSelection
          ? const UpdateCheckResult(UpdateCheckOutcome.failed)
          : const UpdateCheckResult(UpdateCheckOutcome.stale);
    }
    if (!mounted || selectionId != _selectionId) {
      return const UpdateCheckResult(UpdateCheckOutcome.stale);
    }
    _channelSelectionPending = false;
    onSaved?.call();
    return checkForUpdates(force: true, channel: channel);
  }

  void cancelManualCheck() {
    if (!mounted) return;
    if (_channelSelectionPending) {
      ++_selectionId;
      _channelSelectionPending = false;
    }
    if (state.isCheckingManually) {
      final cancelledRequest = ++_requestId;
      _activeChannel = null;
      _readRequestId = null;
      scheduleMicrotask(() {
        if (mounted && _requestId == cancelledRequest) {
          state = UpdateCheckState.idle;
        }
      });
    }
  }

  void markUpdatesRead() {
    _setRedDot(false);
    if (state.isChecking) {
      _readRequestId = _requestId;
      return;
    }
    unawaited(_markAsNotified(_activeChannel));
  }

  void _publish(UpdateInfo? updateInfo, bool hasNewVersion, bool showRedDot) {
    _ref.read(updateInfoProvider.notifier).state = hasNewVersion
        ? updateInfo
        : null;
    _ref.read(hasNewVersionProvider.notifier).state = hasNewVersion;
    _setRedDot(showRedDot);
  }

  void _setRedDot(bool visible) {
    _ref.read(showUpdateRedDotProvider.notifier).state = visible;
  }

  Future<void> _markAsNotified(UpdateChannel? channel) async {
    try {
      await _updateService.markAsNotified(channel: channel);
    } catch (_) {
      // Notification persistence must not fail an update check.
    }
  }

  bool _isCurrent(int requestId, int channelRevision) =>
      mounted &&
      requestId == _requestId &&
      channelRevision == _updateService.channelRevision;
}

/// Status of update download and installation
enum UpdateStatus { idle, downloading, readyToInstall, installing, failed }

/// State of the current update download and installation operation
class UpdateState {
  final UpdateStatus status;
  final double progress; // 0.0 to 1.0
  final int receivedBytes;
  final int totalBytes;
  final String? downloadedFilePath;
  final String? errorMessage;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.progress = 0.0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.downloadedFilePath,
    this.errorMessage,
  });

  UpdateState copyWith({
    UpdateStatus? status,
    double? progress,
    int? receivedBytes,
    int? totalBytes,
    String? downloadedFilePath,
    String? errorMessage,
  }) {
    return UpdateState(
      status: status ?? this.status,
      progress: progress ?? this.progress,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedFilePath: downloadedFilePath ?? this.downloadedFilePath,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Controller for downloading and installing app updates
class UpdateController extends StateNotifier<UpdateState> {
  final UpdateService _updateService;
  CancelToken? _cancelToken;

  UpdateController(this._updateService) : super(const UpdateState());

  /// Start downloading the update asset specified in [info].
  Future<void> startDownload(UpdateInfo info) async {
    _cancelToken?.cancel('Another update download started');
    _cancelToken = null;
    final downloadUrl = info.downloadUrl;
    if (downloadUrl == null) {
      state = const UpdateState(
        status: UpdateStatus.failed,
        errorMessage: '未找到适用于当前系统的安装包',
      );
      return;
    }

    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    state = UpdateState(
      status: UpdateStatus.downloading,
      progress: 0.0,
      receivedBytes: 0,
      totalBytes: info.assetSize ?? 0,
    );

    try {
      final fileName = info.assetName ?? 'Iroru_update';
      final file = await _updateService.downloadUpdate(
        downloadUrl: downloadUrl,
        fileName: fileName,
        assetDigest: info.assetDigest,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          if (!_isCurrentDownload(cancelToken) || cancelToken.isCancelled) {
            return;
          }
          final progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
          state = state.copyWith(
            status: UpdateStatus.downloading,
            progress: progress,
            receivedBytes: received,
            totalBytes: total > 0 ? total : (info.assetSize ?? 0),
          );
        },
      );

      if (!_isCurrentDownload(cancelToken) || cancelToken.isCancelled) {
        return;
      }
      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        progress: 1.0,
        downloadedFilePath: file.path,
      );

      // Automatically trigger installation after download finishes
      await _install(cancelToken: cancelToken);
    } catch (e) {
      if (!_isCurrentDownload(cancelToken)) return;
      if (cancelToken.isCancelled) {
        state = const UpdateState(status: UpdateStatus.idle);
      } else {
        state = state.copyWith(
          status: UpdateStatus.failed,
          errorMessage: e.toString(),
        );
      }
    }
  }

  /// Cancel any active download.
  void cancelDownload() {
    _cancelToken?.cancel('User cancelled download');
    _cancelToken = null;
    state = const UpdateState(status: UpdateStatus.idle);
  }

  /// Launch the installer for the downloaded update.
  Future<bool> install() {
    final cancelToken = _cancelToken;
    if (cancelToken == null) return Future.value(false);
    return _install(cancelToken: cancelToken);
  }

  Future<bool> _install({required CancelToken cancelToken}) async {
    final path = state.downloadedFilePath;
    if (path == null || !_isCurrentDownload(cancelToken)) return false;

    state = state.copyWith(status: UpdateStatus.installing);
    final success = await _updateService.installUpdate(path);
    if (!_isCurrentDownload(cancelToken) || state.downloadedFilePath != path) {
      return false;
    }
    state = state.copyWith(
      status: UpdateStatus.readyToInstall,
      errorMessage: success ? null : '打开安装程序失败',
    );
    return success;
  }

  /// Reset the controller to idle state.
  void reset() {
    _cancelToken?.cancel();
    _cancelToken = null;
    state = const UpdateState(status: UpdateStatus.idle);
  }

  bool _isCurrentDownload(CancelToken token) => identical(_cancelToken, token);

  @override
  void dispose() {
    _cancelToken?.cancel();
    _cancelToken = null;
    super.dispose();
  }
}

/// Provider for update download/install state and actions
final updateControllerProvider =
    StateNotifierProvider<UpdateController, UpdateState>((ref) {
      final updateService = ref.watch(updateServiceProvider);
      return UpdateController(updateService);
    });

final updateCheckControllerProvider =
    StateNotifierProvider<UpdateCheckController, UpdateCheckState>((ref) {
      final updateService = ref.watch(updateServiceProvider);
      return UpdateCheckController(updateService, ref);
    });
