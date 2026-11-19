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
    'preference failures preserve the source and allow retry or fallback',
    () async {
      const channel = MethodChannel('plugins.flutter.io/shared_preferences');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final newDirectory = Directory(p.join(root.path, 'new'));
      await _writeFile(oldDirectory, '123/track.mp3', 'saved audio');
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
          p.join(oldDirectory.path, '123', 'track.mp3'),
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
      expect(await oldDirectory.exists(), isFalse);
      expect(
        await File(
          p.join(newDirectory.path, '123', 'track.mp3'),
        ).readAsString(),
        'saved audio',
      );

      final support = await _useSupportRoot(root);
      final missingPath = p.join(root.path, 'missing');
      await StorageService.setString(
        StorageService.customDownloadPathKey,
        missingPath,
      );
      expect(
        (await DownloadPathService.getDownloadDirectory()).path,
        p.join(support.path, 'downloads'),
      );
      expect(DownloadPathService.getCustomPath(), missingPath);
    },
  );

  test('a staging failure preserves all source directories', () async {
    final oldDirectory = Directory(p.join(root.path, 'old'));
    final newDirectory = Directory(p.join(root.path, 'new'));
    await _writeFile(oldDirectory, '123/track.mp3', 'first');
    await _writeFile(oldDirectory, '456/track.mp3', 'second');
    await _setCurrentPath(oldDirectory.path);
    final blocked = File(p.join(oldDirectory.path, '456', 'track.mp3'));

    Future<void> verifyFailure() async {
      final result = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(result.success, isFalse);
      expect(DownloadPathService.getCustomPath(), oldDirectory.path);
      expect(await blocked.exists(), isTrue);
      expect(
        await File(
          p.join(oldDirectory.path, '123', 'track.mp3'),
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
        p.join(oldDirectory.path, '456', 'linked.mp3'),
      ).create(blocked.path);
      await verifyFailure();
    }
  });

  test(
    'setCustomPath copies managed directories and preserves other files',
    () async {
      final oldDirectory = Directory(p.join(root.path, 'old'));
      final newDirectory = Directory(p.join(root.path, 'new'));
      await _writeFile(oldDirectory, '123/track.mp3', 'numeric work');
      await _writeFile(oldDirectory, 'RJ123456/voice.mp3', 'RJ work');
      await _writeFile(oldDirectory, 'subtitle_library/line.srt', 'subtitle');
      await _writeFile(oldDirectory, 'unmanaged/keep.txt', 'keep me');
      await _writeFile(oldDirectory, 'root-note.txt', 'keep this too');
      await _setCurrentPath(oldDirectory.path);

      final result = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(result.success, isTrue);
      expect(result.fileCount, 3);
      expect(
        await File(
          p.join(newDirectory.path, '123', 'track.mp3'),
        ).readAsString(),
        'numeric work',
      );
      expect(
        await File(
          p.join(newDirectory.path, 'RJ123456', 'voice.mp3'),
        ).readAsString(),
        'RJ work',
      );
      expect(
        await File(
          p.join(newDirectory.path, 'subtitle_library', 'line.srt'),
        ).readAsString(),
        'subtitle',
      );
      expect(
        await Directory(p.join(oldDirectory.path, '123')).exists(),
        isFalse,
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
      await _writeFile(oldDirectory, '123/source.mp3', 'source');
      await _writeFile(newDirectory, '123/existing.mp3', 'existing');
      await _setCurrentPath(oldDirectory.path);

      final result = await DownloadPathService.setCustomPath(newDirectory.path);

      expect(result.success, isFalse);
      expect(result.message, contains('同名项目'));
      expect(
        await File(p.join(oldDirectory.path, '123', 'source.mp3')).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(newDirectory.path, '123', 'existing.mp3'),
        ).readAsString(),
        'existing',
      );
      expect(
        await File(p.join(newDirectory.path, '123', 'source.mp3')).exists(),
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
      await _writeFile(oldDirectory, '123/source.mp3', 'source');
      await _setCurrentPath(oldDirectory.path);

      final result = await DownloadPathService.setCustomPath(
        nestedDirectory.path,
      );

      expect(result.success, isFalse);
      expect(result.message, contains('重叠'));
      expect(
        await File(p.join(oldDirectory.path, '123', 'source.mp3')).exists(),
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
      await _writeFile(oldDirectory, '123/source.mp3', 'source');
      await nestedDirectory.create(recursive: true);
      await _setCurrentPath(oldDirectory.path);

      final equivalentPath = p.join(nestedDirectory.path, '..');
      final result = await DownloadPathService.setCustomPath(equivalentPath);

      expect(result.success, isTrue);
      expect(result.message, contains('无需迁移'));
      expect(
        await File(p.join(oldDirectory.path, '123', 'source.mp3')).exists(),
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
      await _writeFile(customDirectory, '123/track.mp3', 'managed');
      await _writeFile(customDirectory, 'notes/keep.txt', 'keep');
      await _setCurrentPath(customDirectory.path);

      final result = await DownloadPathService.migrateToDefaultPath();

      expect(result.success, isTrue);
      expect(
        await File(
          p.join(defaultDirectory.path, '123', 'track.mp3'),
        ).readAsString(),
        'managed',
      );
      expect(
        await Directory(p.join(customDirectory.path, '123')).exists(),
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
      await _writeFile(customDirectory, '123/source.mp3', 'source');
      await _writeFile(defaultDirectory, '123/existing.mp3', 'existing');
      await _setCurrentPath(customDirectory.path);

      final result = await DownloadPathService.migrateToDefaultPath();

      expect(result.success, isFalse);
      expect(result.message, contains('同名项目'));
      expect(
        await File(
          p.join(customDirectory.path, '123', 'source.mp3'),
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(defaultDirectory.path, '123', 'existing.mp3'),
        ).readAsString(),
        'existing',
      );
      expect(
        p.equals(
          DownloadPathService.getCustomPath()!,
          customDirectory.path,
        ),
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
    await _writeFile(customDirectory, '123/source.mp3', 'source');
    await _setCurrentPath(customDirectory.path);

    final result = await DownloadPathService.migrateToDefaultPath();

    expect(result.success, isFalse);
    expect(result.message, contains('重叠'));
    expect(
      await File(p.join(customDirectory.path, '123', 'source.mp3')).exists(),
      isTrue,
    );
    expect(
      p.equals(DownloadPathService.getCustomPath()!, customDirectory.path),
      isTrue,
    );
  });
}
