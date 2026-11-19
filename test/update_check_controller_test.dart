import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/providers/update_provider.dart';

void main() {
  test('a manual check supersedes an in-flight startup check', () async {
    final service = _QueuedUpdateService();
    final container = ProviderContainer(
      overrides: [updateServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateCheckControllerProvider.notifier);

    final startupCheck = controller.checkForUpdates(autoCheck: true);
    await service.started[0].future;
    expect(
      container.read(updateCheckControllerProvider).isCheckingManually,
      isFalse,
    );
    final manualCheck = controller.checkForUpdates(force: true);
    await service.started[1].future;
    expect(
      container.read(updateCheckControllerProvider).isCheckingManually,
      isTrue,
    );
    expect(
      (await controller.checkForUpdates(autoCheck: true)).outcome,
      UpdateCheckOutcome.stale,
    );

    service.results[1].complete(_info('4.6.0'));
    final manualResult = await manualCheck;

    expect(manualResult.outcome, UpdateCheckOutcome.available);
    expect(container.read(updateInfoProvider)?.latestVersion, '4.6.0');
    expect(container.read(hasNewVersionProvider), isTrue);
    expect(container.read(showUpdateRedDotProvider), isFalse);
    expect(service.notifiedChannels, [UpdateChannel.stable]);
    expect(service.forces, [false, true]);

    service.results[0].complete(_info('4.5.0'));
    expect((await startupCheck).outcome, UpdateCheckOutcome.stale);
    expect(container.read(updateInfoProvider)?.latestVersion, '4.6.0');
    expect(container.read(showUpdateRedDotProvider), isFalse);
  });

  test('entering About marks an in-flight startup result as read', () async {
    final service = _QueuedUpdateService();
    final container = ProviderContainer(
      overrides: [updateServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateCheckControllerProvider.notifier);

    final startupCheck = controller.checkForUpdates(autoCheck: true);
    await service.started[0].future;
    controller.markUpdatesRead();
    service.results[0].complete(_info('4.6.0'));

    expect((await startupCheck).outcome, UpdateCheckOutcome.available);
    expect(container.read(updateInfoProvider)?.latestVersion, '4.6.0');
    expect(container.read(hasNewVersionProvider), isTrue);
    expect(container.read(showUpdateRedDotProvider), isFalse);
    expect(service.notifiedChannels, [UpdateChannel.stable]);
  });

  test(
    'a pending channel change rejects checks for the previous channel',
    () async {
      final service = _QueuedUpdateService();
      service.saveGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [updateServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final controller = container.read(updateCheckControllerProvider.notifier);

      final selection = controller.selectUpdateChannel(UpdateChannel.beta);
      await service.saveStarted.future;
      final staleManual = await controller.checkForUpdates(
        force: true,
        channel: UpdateChannel.stable,
      );

      expect(staleManual.outcome, UpdateCheckOutcome.stale);
      expect(service.forces, isEmpty);

      service.saveGate!.complete();
      await service.started[0].future;
      service.results[0].complete(_info('4.6.0-beta.1'));
      final result = await selection;

      expect(result.outcome, UpdateCheckOutcome.available);
      expect(container.read(updateInfoProvider)?.latestVersion, '4.6.0-beta.1');
    },
  );

  test(
    'leaving during a pending channel save skips the follow-up check',
    () async {
      final service = _QueuedUpdateService();
      service.saveGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [updateServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final controller = container.read(updateCheckControllerProvider.notifier);

      final selection = controller.selectUpdateChannel(UpdateChannel.beta);
      await service.saveStarted.future;
      controller.cancelManualCheck();

      service.saveGate!.complete();
      expect((await selection).outcome, UpdateCheckOutcome.stale);
      expect(service.channel, UpdateChannel.beta);
      expect(service.forces, isEmpty);
    },
  );

  test('a failed channel save restores the selected channel', () async {
    final service = _QueuedUpdateService();
    final container = ProviderContainer(
      overrides: [updateServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateCheckControllerProvider.notifier);

    final initialCheck = controller.checkForUpdates(
      force: true,
      channel: UpdateChannel.stable,
    );
    await service.started[0].future;
    service.results[0].complete(null);
    await initialCheck;

    service.failSave = true;
    final failedSelection = await controller.selectUpdateChannel(
      UpdateChannel.beta,
    );

    expect(failedSelection.outcome, UpdateCheckOutcome.failed);
    expect(controller.selectedChannel, UpdateChannel.stable);

    service.failSave = false;
    final nextCheck = controller.checkForUpdates(
      force: true,
      channel: UpdateChannel.stable,
    );
    await service.started[1].future;
    service.results[1].complete(null);
    expect((await nextCheck).outcome, UpdateCheckOutcome.upToDate);
  });

  test('a non-null older beta result is up to date', () async {
    final service = _QueuedUpdateService();
    final container = ProviderContainer(
      overrides: [updateServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    final controller = container.read(updateCheckControllerProvider.notifier);

    final check = controller.checkForUpdates(
      force: true,
      channel: UpdateChannel.beta,
    );
    await service.started[0].future;
    service.results[0].complete(
      const UpdateInfo(
        latestVersion: '4.3.0-beta.1',
        currentVersion: '4.4.0',
        releaseUrl: 'https://example.com/old-beta',
        hasNewVersion: false,
        isCrossChannel: true,
      ),
    );

    expect((await check).outcome, UpdateCheckOutcome.upToDate);
  });
}

UpdateInfo _info(String version) => UpdateInfo(
  latestVersion: version,
  currentVersion: '4.4.0',
  releaseUrl: 'https://example.com/$version',
  hasNewVersion: true,
);

class _QueuedUpdateService extends UpdateService {
  final results = [Completer<UpdateInfo?>(), Completer<UpdateInfo?>()];
  final started = [Completer<void>(), Completer<void>()];
  final forces = <bool>[];
  final notifiedChannels = <UpdateChannel>[];
  final saveStarted = Completer<void>();
  Completer<void>? saveGate;
  bool failSave = false;
  int _requestCount = 0;
  int _revision = 0;
  UpdateChannel channel = UpdateChannel.stable;

  @override
  int get channelRevision => _revision;

  @override
  Future<UpdateChannel> getUpdateChannel({String? packageName}) async =>
      UpdateChannel.stable;

  @override
  Future<void> setUpdateChannel(UpdateChannel channel) async {
    _revision++;
    if (failSave) throw StateError('save failed');
    this.channel = channel;
    if (!saveStarted.isCompleted) saveStarted.complete();
    await saveGate?.future;
  }

  @override
  Future<UpdateInfo?> checkForUpdates({
    bool force = false,
    UpdateChannel? channel,
  }) {
    final index = _requestCount++;
    forces.add(force);
    started[index].complete();
    return results[index].future;
  }

  @override
  Future<bool> shouldShowRedDot({UpdateChannel? channel}) async => true;

  @override
  Future<void> markAsNotified({UpdateChannel? channel}) async {
    notifiedChannels.add(channel ?? UpdateChannel.stable);
  }
}
