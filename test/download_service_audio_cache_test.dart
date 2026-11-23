import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/models/download_task.dart';
import 'package:iroru/src/services/audio_cache_files.dart';
import 'package:iroru/src/services/cache_service.dart';
import 'package:iroru/src/services/download_service.dart';
import 'package:iroru/src/services/storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'downloads the requested audio instead of reusing automatic cache',
    () async {
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      final root = await Directory.systemTemp.createTemp(
        'kikoflu_download_audio_cache_',
      );
      final previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
        PathProviderPlatform.instance = previousPathProvider;
        HttpOverrides.global = previousHttpOverrides;
        if (await root.exists()) await root.delete(recursive: true);
      });

      final wav = _wavBytes();
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final start = range == null
            ? 0
            : int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        final body = start == 0 ? wav : wav.sublist(start);
        request.response.statusCode = start == 0
            ? HttpStatus.ok
            : HttpStatus.partialContent;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.contentLength = body.length;
        if (start > 0) {
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${wav.length - 1}/${wav.length}',
          );
        }
        request.response.add(body);
        await request.response.close();
      });

      final url = 'http://${server.address.host}:${server.port}/track.wav';
      final partialTask = DownloadTask(
        id: '1001:hash:1001/track-a',
        workId: 1001,
        workTitle: 'Work A',
        fileName: 'track-a.wav',
        hash: '1001/track-a',
        downloadUrl: url,
        totalBytes: wav.length,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      final completedCacheTask = DownloadTask(
        id: '1002:hash:1002/track-b',
        workId: 1002,
        workTitle: 'Work B',
        fileName: 'track-b.wav',
        hash: '1002/track-b',
        downloadUrl: url,
        totalBytes: wav.length,
        status: DownloadStatus.paused,
        createdAt: DateTime.utc(2026),
      );
      SharedPreferences.setMockInitialValues({
        StorageService.customDownloadPathKey: root.path,
        'download_tasks': jsonEncode([
          partialTask.toJson(),
          completedCacheTask.toJson(),
        ]),
        AudioCacheFiles.completeMetadataKey(completedCacheTask.hash!):
            DateTime.now().millisecondsSinceEpoch,
      });
      await StorageService.initCritical(
        preferences: await SharedPreferences.getInstance(),
      );
      final service = DownloadService.instance;
      addTearDown(() async {
        await service.flushPendingWrites();
        service.dispose();
      });
      await service.initialize();

      final m4a = <int>[
        0x00,
        0x00,
        0x00,
        0x1c,
        0x66,
        0x74,
        0x79,
        0x70,
        0x4d,
        0x34,
        0x41,
        0x20,
      ];
      final partial = await CacheService.audioCacheFiles.partialFile(
        partialTask.hash!,
        create: true,
      );
      await partial.writeAsBytes(m4a);
      final completedCache = await CacheService.audioCacheFiles.finalFile(
        completedCacheTask.hash!,
      );
      await completedCache.writeAsBytes(m4a);

      await _resumeAndWait(service, partialTask);
      expect(
        await File(
          p.join(root.path, 'audio', '${partialTask.workId}', partialTask.fileName),
        ).readAsBytes(),
        wav,
      );

      await _resumeAndWait(service, completedCacheTask);
      expect(
        await File(
          p.join(
            root.path,
            'audio',
            '${completedCacheTask.workId}',
            completedCacheTask.fileName,
          ),
        ).readAsBytes(),
        wav,
      );

      const addedHash = '1003/track-c';
      final addedCache = await CacheService.audioCacheFiles.finalFile(
        addedHash,
      );
      await addedCache.writeAsBytes(m4a);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(
        AudioCacheFiles.completeMetadataKey(addedHash),
        DateTime.now().millisecondsSinceEpoch,
      );
      final addedCompleted = service.taskChangesStream.firstWhere(
        (change) =>
            change.task?.workId == 1003 &&
            change.task?.status == DownloadStatus.completed,
      );
      await service.addTask(
        workId: 1003,
        workTitle: 'Work C',
        fileName: 'track-c.wav',
        downloadUrl: url,
        hash: addedHash,
        totalBytes: wav.length,
      );
      await addedCompleted.timeout(const Duration(seconds: 15));
      expect(
        await File(p.join(root.path, 'audio', '1003', 'track-c.wav')).readAsBytes(),
        wav,
      );
    },
  );
}

Future<void> _resumeAndWait(DownloadService service, DownloadTask task) async {
  final completed = service.taskChangesStream.firstWhere(
    (change) =>
        change.task?.id == task.id &&
        change.task?.status == DownloadStatus.completed,
  );
  await service.resumeTask(task.id);
  await completed.timeout(const Duration(seconds: 15));
}

List<int> _wavBytes() => [
  0x52,
  0x49,
  0x46,
  0x46,
  0x38,
  0x00,
  0x00,
  0x00,
  0x57,
  0x41,
  0x56,
  0x45,
  0x66,
  0x6d,
  0x74,
  0x20,
  0x10,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x80,
  0xbb,
  0x00,
  0x00,
  0x00,
  0x77,
  0x01,
  0x00,
  0x02,
  0x00,
  0x10,
  0x00,
  0x64,
  0x61,
  0x74,
  0x61,
  0x14,
  0x00,
  0x00,
  0x00,
  ...List<int>.generate(20, (index) => index),
];

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}
