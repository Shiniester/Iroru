import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'log_service.dart';
import 'storage_service.dart';
import 'subtitle_library_rules.dart';

final _log = LogService.instance;

enum DownloadFolder {
  audio('audio'),
  comics('comics'),
  videos('videos'),
  subtitles(SubtitleLibraryRules.libraryFolderName);

  const DownloadFolder(this.directoryName);

  final String directoryName;

  Directory inRoot(Directory root) =>
      Directory(p.join(root.path, directoryName));
}

/// 下载路径管理服务
class DownloadPathService {
  static const _customPathKey = StorageService.customDownloadPathKey;

  /// 获取当前下载路径（自定义路径或默认路径）
  static Future<Directory> getDownloadDirectory() async {
    final customPath = getCustomPath();
    if (customPath != null && customPath.isNotEmpty) {
      return Directory(Platform.isIOS ? await _iosFilesPath() : customPath);
    }
    return _getDefaultDownloadDirectory();
  }

  static Future<Directory> getDirectory(DownloadFolder folder) async {
    final directory = folder.inRoot(await getDownloadDirectory());
    await directory.create(recursive: true);
    return directory;
  }

  /// 获取默认下载路径
  static Future<Directory> _getDefaultDownloadDirectory() async {
    final supportDirectory = await getApplicationSupportDirectory();
    final downloadDir = Directory(p.join(supportDirectory.path, 'downloads'));
    if (!await downloadDir.exists()) {
      await downloadDir.create(recursive: true);
    }
    return downloadDir;
  }

  /// 获取自定义路径（如果设置了）
  static String? getCustomPath() {
    return StorageService.getString(_customPathKey);
  }

  /// 检查是否设置了自定义路径
  static bool hasCustomPath() => getCustomPath()?.isNotEmpty ?? false;

  /// 选择自定义下载目录
  /// 返回 null 表示用户取消选择
  /// 返回路径字符串表示成功
  static Future<String?> pickCustomDirectory() async {
    // 根据平台不同处理
    if (Platform.isAndroid) {
      return await _pickDirectoryAndroid();
    } else if (Platform.isIOS) {
      return _iosFilesPath();
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return await _pickDirectoryDesktop();
    }
    return null;
  }

  /// Android 平台选择目录
  static Future<String?> _pickDirectoryAndroid() async {
    // Android 11+ 需要 MANAGE_EXTERNAL_STORAGE 权限
    if (await _requestStoragePermission()) {
      final result = await FilePicker.platform.getDirectoryPath();
      return result;
    }
    return null;
  }

  static Future<String> _iosFilesPath() async {
    final documents = await getApplicationDocumentsDirectory();
    return p.join(documents.path, 'Downloads');
  }

  /// 桌面平台（Windows/macOS/Linux）选择目录
  static Future<String?> _pickDirectoryDesktop() async {
    final result = await FilePicker.platform.getDirectoryPath();
    return result;
  }

  /// 请求存储权限（Android）
  static Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true;

    // Android 13+ (API 33+) 使用新的权限模型
    if (Platform.version.contains('13') ||
        Platform.version.contains('14') ||
        Platform.version.contains('15')) {
      // Android 13+ 不再需要 MANAGE_EXTERNAL_STORAGE
      // 使用 scoped storage
      return true;
    }

    // Android 11-12 需要 MANAGE_EXTERNAL_STORAGE
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }

    if (!status.isGranted) {
      // 如果没有获得权限，尝试基本的存储权限
      var storageStatus = await Permission.storage.status;
      if (!storageStatus.isGranted) {
        storageStatus = await Permission.storage.request();
      }
      return storageStatus.isGranted;
    }

    return status.isGranted;
  }

  /// 设置自定义下载路径并迁移文件
  /// 返回迁移结果消息
  static Future<MigrationResult> setCustomPath(String newPath) async {
    final newDir = Directory(p.normalize(newPath));
    final oldDir = await getDownloadDirectory();

    if (await _sameDirectory(oldDir, newDir)) {
      return MigrationResult(root: oldDir, message: '目录未改变，无需迁移');
    }

    if (await _pathsOverlap(oldDir, newDir)) {
      return MigrationResult(message: '原目录与新目录存在重叠，无法迁移');
    }

    // 确保新目录存在
    if (!await newDir.exists()) {
      try {
        await newDir.create(recursive: true);
      } catch (e) {
        return MigrationResult(message: '无法创建目录: $e');
      }
    }

    return _migrateFiles(
      oldDir,
      newDir,
      savePath: () => _persistCustomPath(newDir.path),
    );
  }

  /// 将下载目录迁移回默认路径
  static Future<MigrationResult> migrateToDefaultPath() async {
    final currentDir = await getDownloadDirectory();
    final defaultDir = await _getDefaultDownloadDirectory();

    if (await _sameDirectory(currentDir, defaultDir)) {
      if (!await _persistCustomPath(null)) {
        return MigrationResult(message: '保存下载路径设置失败');
      }
      return MigrationResult(root: defaultDir, message: '当前已使用默认路径');
    }

    return _migrateFiles(
      currentDir,
      defaultDir,
      savePath: () => _persistCustomPath(null),
    );
  }

  /// 迁移文件从旧目录到新目录
  static Future<MigrationResult> _migrateFiles(
    Directory oldDir,
    Directory newDir, {
    required Future<bool> Function() savePath,
  }) async {
    Directory? stagingDir;
    final committedTargets = <Directory>[];
    var preferenceSaved = false;
    var fileCount = 0;
    var skippedCount = 0;
    var errorCount = 0;
    final skippedItems = <String>[];

    try {
      // 检查旧目录是否存在
      if (!await oldDir.exists()) {
        return MigrationResult(message: '无法访问原下载目录。恢复原目录后重试。');
      }

      if (await _pathsOverlap(oldDir, newDir)) {
        return MigrationResult(message: '原目录与新目录存在重叠，无法迁移');
      }

      final managedDirectories = <String, Directory>{};

      await for (final entity in oldDir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (entity is Directory &&
            DownloadFolder.values.any((folder) => folder.directoryName == name)) {
          managedDirectories[name] = entity;
        } else {
          skippedCount++;
          skippedItems.add(name);
          _log.debug('跳过非下载项目: $name', tag: 'DownloadPath');
        }
      }

      final conflictingItems = <String>[];
      for (final folder in DownloadFolder.values) {
        final destination = folder.inRoot(newDir);
        if (await _pathExists(destination.path)) {
          conflictingItems.add(folder.directoryName);
        }
      }
      if (conflictingItems.isNotEmpty) {
        return MigrationResult(
          message: '目标目录已存在同名项目，未迁移: ${conflictingItems.join(", ")}',
        );
      }

      stagingDir = await newDir.createTemp('.iroru-');
      for (final folder in DownloadFolder.values) {
        final stagedDirectory = await folder.inRoot(stagingDir).create();
        final source = managedDirectories[folder.directoryName];
        if (source != null) {
          fileCount += await _copyDirectoryContents(source, stagedDirectory);
        }
      }
      for (final folder in DownloadFolder.values) {
        final destination = folder.inRoot(newDir);
        if (await _pathExists(destination.path)) {
          throw FileSystemException('目标目录已存在同名项目', destination.path);
        }
        await folder.inRoot(stagingDir).rename(destination.path);
        committedTargets.add(destination);
      }

      if (!await savePath()) {
        throw const FileSystemException('保存下载路径设置失败');
      }
      preferenceSaved = true;

      for (final entry in managedDirectories.entries) {
        try {
          await entry.value.delete(recursive: true);
        } catch (e) {
          _log.error('删除原文件夹失败: ${entry.key}, 错误: $e', tag: 'DownloadPath');
          errorCount++;
        }
      }

      String resultMessage =
          '已迁移 ${managedDirectories.length} 个目录和 $fileCount 个文件';
      if (skippedCount > 0) {
        resultMessage += '\n跳过 $skippedCount 个非下载项目（已保留）';
        if (skippedItems.length <= 5) {
          resultMessage += ': ${skippedItems.join(", ")}';
        }
      }
      if (errorCount > 0) {
        resultMessage += '\n$errorCount 个错误';
      }
      return MigrationResult(
        root: newDir,
        message: resultMessage,
        fileCount: fileCount,
        errorCount: errorCount,
      );
    } catch (e) {
      if (!preferenceSaved) {
        final rollbackErrors = await _rollbackCreatedTargets(committedTargets);
        if (rollbackErrors.isNotEmpty) {
          errorCount += rollbackErrors.length;
          _log.error(
            '回滚目标目录失败: ${rollbackErrors.join(", ")}',
            tag: 'DownloadPath',
          );
        }
      }
      return MigrationResult(message: '迁移失败: $e', errorCount: errorCount);
    } finally {
      if (stagingDir != null) {
        try {
          if (await stagingDir.exists()) {
            await stagingDir.delete(recursive: true);
          }
        } catch (e) {
          _log.error(
            '清理暂存目录失败: ${stagingDir.path}, 错误: $e',
            tag: 'DownloadPath',
          );
        }
      }
    }
  }

  static Future<int> _copyDirectoryContents(
    Directory source,
    Directory destination,
  ) async {
    var fileCount = 0;
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relativePath = p.relative(entity.path, from: source.path);
      final destinationPath = p.join(destination.path, relativePath);
      if (entity is File) {
        final destinationFile = File(destinationPath);
        await destinationFile.parent.create(recursive: true);
        await entity.copy(destinationPath);
        fileCount++;
      } else if (entity is Directory) {
        await Directory(destinationPath).create(recursive: true);
      } else {
        throw FileSystemException('不支持迁移链接', entity.path);
      }
    }
    return fileCount;
  }

  static Future<List<String>> _rollbackCreatedTargets(
    List<Directory> targets,
  ) async {
    final failures = <String>[];
    for (final target in targets.reversed) {
      try {
        if (await target.exists()) {
          await target.delete(recursive: true);
        }
      } catch (e) {
        failures.add('${target.path}: $e');
      }
    }
    return failures;
  }

  static Future<bool> _sameDirectory(Directory first, Directory second) async {
    return p.equals(await _resolvedPath(first), await _resolvedPath(second));
  }

  static Future<bool> _pathsOverlap(Directory first, Directory second) async {
    final firstPath = await _resolvedPath(first);
    final secondPath = await _resolvedPath(second);
    return p.equals(firstPath, secondPath) ||
        p.isWithin(firstPath, secondPath) ||
        p.isWithin(secondPath, firstPath);
  }

  static Future<String> _resolvedPath(Directory directory) async {
    final normalized = p.normalize(p.absolute(directory.path));
    if (!await directory.exists()) return normalized;
    try {
      return p.normalize(await directory.resolveSymbolicLinks());
    } on FileSystemException {
      return normalized;
    }
  }

  static Future<bool> _pathExists(String path) async {
    return await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound;
  }

  static Future<bool> _persistCustomPath(String? path) async {
    final preferences = await StorageService.getPrefs();
    var saved = false;
    try {
      saved = path == null
          ? await preferences.remove(_customPathKey)
          : await preferences.setString(_customPathKey, path);
      return saved;
    } finally {
      if (!saved) await preferences.reload();
    }
  }

  /// 检查平台是否支持自定义路径
  static bool isPlatformSupported() {
    return Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isLinux;
  }

  /// 获取平台友好的提示信息
  static String getPlatformHint() {
    if (Platform.isAndroid) {
      return 'Android: 将使用系统文件选择器，可能需要存储权限';
    } else if (Platform.isIOS) {
      return '';
    } else if (Platform.isWindows) {
      return 'Windows: 可选择任意可访问的目录';
    } else if (Platform.isMacOS) {
      return 'macOS: 可选择任意可访问的目录';
    }
    return '选择一个用于保存下载文件的目录';
  }
}

/// 迁移结果
class MigrationResult {
  final Directory? root;
  final String message;
  final int fileCount;
  final int errorCount;

  bool get success => root != null;

  MigrationResult({
    this.root,
    required this.message,
    this.fileCount = 0,
    this.errorCount = 0,
  });
}
