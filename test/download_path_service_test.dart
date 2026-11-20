import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/src/services/download_path_service.dart';
import 'package:iroru/src/services/storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _setCurrentPath(String path) async {
  SharedPreferences.setMockInitialValues({
    StorageService.customDownloadPathKey: path,
  });
  final preferences = await SharedPreferences.getInstance();
  await StorageService.initCritical(preferences: preferences);
}

Future<void> _writeFile(
  Directory root,
  String relativePath,
  String contents,
) async {
  final file = File(p.joinAll([root.path, ...relativePath.split('/')]));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

Future<Directory> _useSupportRoot(Directory root) async {
  final support = Directory(p.join(root.path, 'support'));
  await support.create(recursive: true);
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (_) async => support.path);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return support;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-path-service-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test(
    'preference failures preserve the source and allow retry',
    () async {
      const channel = MethodChannel('plugins.flutter.io/shared_preferences');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final newDirectory = Directory(p.join(root.path, 'new'));
      await _writeFile(oldDirectory, 'audio/123/track.mp3', 'saved audio');
      var storedPath = oldDirectory.path;
      var acceptWrites = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getAll') {
          return {
            'flutter.${StorageService.customDownloadPathKey}': storedPath,
          };
        }
        if (call.method == 'setString') {
          if (!acceptWrites) return false;
          storedPath =
              (call.arguments as Map<Object?, Object?>)['value'] as String;
          return true;
        }
        if (call.method == 'remove') return false;
        throw MissingPluginException(call.method);
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await StorageService.initCritical();

      final failed = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(failed.success, isFalse);
      expect(DownloadPathService.getCustomPath(), oldDirectory.path);
      expect(
        await File(
          p.join(oldDirectory.path, 'audio', '123', 'track.mp3'),
        ).readAsString(),
        'saved audio',
      );
      expect(await newDirectory.list().isEmpty, isTrue);

      acceptWrites = true;
      final retried = await DownloadPathService.setCustomPath(
        newDirectory.path,
      );

      expect(retried.success, isTrue);
      expect(storedPath, newDirectory.path);
      expect(await oldDirectory.list().isEmpty, isTrue);
      for (final folder in DownloadFolder.values) {
        expect(await folder.inRoot(newDirectory).exists(), isTrue);
      }
      expect(
        await File(
          p.join(newDirectory.path, 'audio', '123', 'track.mp3'),
        ).readAsString(),
        'saved audio',
      );
    },
  );

  test('an unavailable custom root remains selected', () async {
    final missingPath = p.join(root.path, 'missing');
    await _setCurrentPath(missingPath);

    expect((await DownloadPathService.getDownloadDirectory()).path, missingPath);
    final result = await DownloadPathService.setCustomPath(
      p.join(root.path, 'new'),
    );
    expect(result.success, isFalse);
    expect(DownloadPathService.getCustomPath(), missingPath);
  });

  test('an older custom path is not adopted as the shared root', () async {
    final support = await _useSupportRoot(root);
    final oldDirectory = Directory(p.join(root.path, 'old'));
    await _writeFile(oldDirectory, 'videos/personal.mp4', 'personal file');
    SharedPreferences.setMockInitialValues({
      'custom_download_path': oldDirectory.path,
    });
    await StorageService.initCritical(
      preferences: await SharedPreferences.getInstance(),
    );

    expect(
      (await DownloadPathService.getDownloadDirectory()).path,
      p.join(support.path, 'downloads'),
    );
    expect(
      await File(
        p.join(oldDirectory.path, 'videos', 'personal.mp4'),
      ).readAsString(),
      'personal file',
    );
  });

  test('a destination cannot claim a folder absent from the source', () async {
    final source = Directory(p.join(root.path, 'source'));
    final target = Directory(p.join(root.path, 'target'));
    await _writeFile(source, 'audio/123/track.mp3', 'audio');
    await _writeFile(target, 'videos/personal.mp4', 'personal file');
    await _setCurrentPath(source.path);

    final result = await DownloadPathService.setCustomPath(target.path);

    expect(result.success, isFalse);
    expect(DownloadPathService.getCustomPath(), source.path);
    expect(
      await File(p.join(target.path, 'videos', 'personal.mp4')).readAsString(),
      'personal file',
    );
    expect(await DownloadFolder.audio.inRoot(target).exists(), isFalse);
  });

  test('a staging failure preserves all source directories', () async {
    final oldDirectory = Directory(p.join(root.path, 'old'));
    final newDirectory = Directory(p.join(root.path, 'new'));
    await _writeFile(oldDirectory, 'audio/123/track.mp3', 'first');
    await _writeFile(oldDirectory, 'videos/456/index.m3u8', 'second');
    await _setCurrentPath(oldDirectory.path);
    final blocked = File(
      p.join(oldDirectory.path, 'videos', '456', 'index.m3u8'),
    );

    Future<void> verifyFailure() async {
      final result = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(result.success, isFalse);
      expect(DownloadPathService.getCustomPath(), oldDirectory.path);
      expect(await blocked.exists(), isTrue);
      expect(
        await File(
          p.join(oldDirectory.path, 'audio', '123', 'track.mp3'),
        ).readAsString(),
        'first',
      );
      expect(await newDirectory.list().isEmpty, isTrue);
    }

    if (Platform.isWindows) {
      final handle = await blocked.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
        await verifyFailure();
      } finally {
        await handle.close();
      }
    } else {
      await Link(
        p.join(oldDirectory.path, 'videos', '456', 'linked.m3u8'),
      ).create(blocked.path);
      await verifyFailure();
    }
  });

  test(
    'setCustomPath copies managed directories and preserves other files',
    () async {
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final newDirectory = Directory(p.join(root.path, 'new'));
      const managedFiles = {
        'audio/RJ123456/voice.mp3': 'audio',
        'comics/source/book/chapter/0.image.part': 'partial comic',
        'videos/456/index.m3u8': 'video',
        'subtitle_library/line.srt': 'subtitle',
      };
      for (final entry in managedFiles.entries) {
        await _writeFile(oldDirectory, entry.key, entry.value);
      }
      await _writeFile(oldDirectory, '123/legacy.mp3', 'legacy layout');
      await _writeFile(oldDirectory, 'unmanaged/keep.txt', 'keep me');
      await _writeFile(oldDirectory, 'root-note.txt', 'keep this too');
      await _setCurrentPath(oldDirectory.path);

      final result = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(result.success, isTrue);
      expect(result.root?.path, newDirectory.path);
      expect(result.fileCount, managedFiles.length);
      for (final entry in managedFiles.entries) {
        final segments = entry.key.split('/');
        expect(
          await File(
            p.joinAll([newDirectory.path, ...segments]),
          ).readAsString(),
          entry.value,
        );
        expect(
          await Directory(p.join(oldDirectory.path, segments.first)).exists(),
          isFalse,
        );
      }
      expect(
        await File(
          p.join(oldDirectory.path, '123', 'legacy.mp3'),
        ).readAsString(),
        'legacy layout',
      );
      expect(
        await File(p.join(oldDirectory.path, 'unmanaged', 'keep.txt')).exists(),
        isTrue,
      );
      expect(
        await File(p.join(oldDirectory.path, 'root-note.txt')).exists(),
        isTrue,
      );
      expect(
        p.equals(DownloadPathService.getCustomPath()!, newDirectory.path),
        isTrue,
      );
    },
  );

  test(
    'setCustomPath leaves source and setting untouched on name conflict',
    () async {
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final newDirectory = Directory(p.join(root.path, 'new'));
      await _writeFile(oldDirectory, 'videos/123/source.mp4', 'source');
      await _writeFile(newDirectory, 'videos/123/existing.mp4', 'existing');
      await _setCurrentPath(oldDirectory.path);

      final result = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(result.success, isFalse);
      expect(result.message, contains('同名项目'));
      expect(
        await File(
          p.join(oldDirectory.path, 'videos', '123', 'source.mp4'),
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(newDirectory.path, 'videos', '123', 'existing.mp4'),
        ).readAsString(),
        'existing',
      );
      expect(
        await File(
          p.join(newDirectory.path, 'videos', '123', 'source.mp4'),
        ).exists(),
        isFalse,
      );
      expect(
        p.equals(DownloadPathService.getCustomPath()!, oldDirectory.path),
        isTrue,
      );
    },
  );

  test(
    'setCustomPath rejects overlapping directories without changing data',
    () async {
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final nestedDirectory = Directory(
        p.join(oldDirectory.path, 'nested-new'),
      );
      await _writeFile(oldDirectory, 'audio/123/source.mp3', 'source');
      await _setCurrentPath(oldDirectory.path);

      final result = await DownloadPathService.setCustomPath(
        nestedDirectory.path,
      );

      expect(result.success, isFalse);
      expect(result.message, contains('重叠'));
      expect(
        await File(
          p.join(oldDirectory.path, 'audio', '123', 'source.mp3'),
        ).exists(),
        isTrue,
      );
      expect(await nestedDirectory.exists(), isFalse);
      expect(
        p.equals(DownloadPathService.getCustomPath()!, oldDirectory.path),
        isTrue,
      );
    },
  );

  test(
    'setCustomPath treats equivalent paths as the current directory',
    () async {
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final nestedDirectory = Directory(p.join(oldDirectory.path, 'nested'));
      await _writeFile(oldDirectory, 'audio/123/source.mp3', 'source');
      await nestedDirectory.create(recursive: true);
      await _setCurrentPath(oldDirectory.path);

      final equivalentPath = p.join(nestedDirectory.path, '..');
      final result = await DownloadPathService.setCustomPath(equivalentPath);

      expect(result.success, isTrue);
      expect(result.message, contains('无需迁移'));
      expect(
        await File(
          p.join(oldDirectory.path, 'audio', '123', 'source.mp3'),
        ).exists(),
        isTrue,
      );
      expect(
        p.equals(DownloadPathService.getCustomPath()!, oldDirectory.path),
        isTrue,
      );
    },
  );

  test(
    'migrateToDefaultPath copies a custom directory to application support',
    () async {
      final support = await _useSupportRoot(root);
      final customDirectory = Directory(p.join(root.path, 'custom'));
      final defaultDirectory = Directory(p.join(support.path, 'downloads'));
      await _writeFile(customDirectory, 'audio/123/track.mp3', 'managed');
      await _writeFile(
        customDirectory,
        'subtitle_library/track.srt',
        'subtitle',
      );
      await _writeFile(customDirectory, 'notes/keep.txt', 'keep');
      await _setCurrentPath(customDirectory.path);

      final result = await DownloadPathService.migrateToDefaultPath();

      expect(result.success, isTrue);
      expect(
        await File(
          p.join(defaultDirectory.path, 'audio', '123', 'track.mp3'),
        ).readAsString(),
        'managed',
      );
      expect(
        await File(
          p.join(defaultDirectory.path, 'subtitle_library', 'track.srt'),
        ).readAsString(),
        'subtitle',
      );
      expect(
        await Directory(p.join(customDirectory.path, 'audio')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(customDirectory.path, 'notes', 'keep.txt'),
        ).readAsString(),
        'keep',
      );
      expect(DownloadPathService.getCustomPath(), isNull);
    },
  );

  test(
    'migrateToDefaultPath preserves both sides on default name conflict',
    () async {
      final support = await _useSupportRoot(root);
      final customDirectory = Directory(p.join(root.path, 'custom'));
      final defaultDirectory = Directory(p.join(support.path, 'downloads'));
      await _writeFile(customDirectory, 'comics/123/source.image', 'source');
      await _writeFile(
        defaultDirectory,
        'comics/123/existing.image',
        'existing',
      );
      await _setCurrentPath(customDirectory.path);

      final result = await DownloadPathService.migrateToDefaultPath();

      expect(result.success, isFalse);
      expect(result.message, contains('同名项目'));
      expect(
        await File(
          p.join(customDirectory.path, 'comics', '123', 'source.image'),
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(defaultDirectory.path, 'comics', '123', 'existing.image'),
        ).readAsString(),
        'existing',
      );
      expect(
        p.equals(DownloadPathService.getCustomPath()!, customDirectory.path),
        isTrue,
      );
    },
  );

  test(
    'migrateToDefaultPath rejects a child of the default download directory',
    () async {
      final support = await _useSupportRoot(root);
      final defaultDirectory = Directory(p.join(support.path, 'downloads'));
      final customDirectory = Directory(
        p.join(defaultDirectory.path, 'custom'),
      );
      await _writeFile(customDirectory, 'audio/123/source.mp3', 'source');
      await _setCurrentPath(customDirectory.path);

      final result = await DownloadPathService.migrateToDefaultPath();

      expect(result.success, isFalse);
      expect(result.message, contains('重叠'));
      expect(
        await File(
          p.join(customDirectory.path, 'audio', '123', 'source.mp3'),
        ).exists(),
        isTrue,
      );
      expect(
        p.equals(DownloadPathService.getCustomPath()!, customDirectory.path),
        isTrue,
      );
    },
  );
}
