import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'local_work_metadata_service.dart';
import 'log_service.dart';
import 'storage_service.dart';
import 'subtitle_library_rules.dart';

final _log = LogService.instance;

/// 下载路径管理服务
class DownloadPathService {
  static const _customPathKey = StorageService.customDownloadPathKey;

  /// 获取当前下载路径（自定义路径或默认路径）
  static Future<Directory> getDownloadDirectory() async {
    final customPath = getCustomPath();

    if (customPath != null && customPath.isNotEmpty) {
      final dir = Directory(customPath);
      if (await dir.exists()) {
        return dir;
      }
      try {
        if (!await _persistCustomPath(null)) {
          _log.warning('无法清除已失效的下载目录设置', tag: 'DownloadPath');
        }
      } catch (error) {
        _log.warning('无法清除已失效的下载目录设置: $error', tag: 'DownloadPath');
      }
    }

    return _getDefaultDownloadDirectory();
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
      return await _pickDirectoryIOS();
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

  /// iOS 平台选择目录
  static Future<String?> _pickDirectoryIOS() async {
    // iOS 使用文档选择器
    final result = await FilePicker.platform.getDirectoryPath();
    return result;
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
      return MigrationResult(success: true, message: '目录未改变，无需迁移');
    }

    if (await _pathsOverlap(oldDir, newDir)) {
      return MigrationResult(success: false, message: '原目录与新目录存在重叠，无法迁移');
    }

    // 确保新目录存在
    if (!await newDir.exists()) {
      try {
        await newDir.create(recursive: true);
      } catch (e) {
        return MigrationResult(success: false, message: '无法创建目录: $e');
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
        return MigrationResult(success: false, message: '保存下载路径设置失败');
      }
      return MigrationResult(success: true, message: '当前已使用默认路径');
    }

    return _migrateFiles(
      currentDir,
      defaultDir,
      savePath: () => _persistCustomPath(null),
    );
  }

  /// 迁移文件从旧目录到新目录
  /// 只迁移符合下载结构的文件（数字或 RJ 命名的 workId 文件夹）
  /// 保护用户可能存放在下载目录中的其他文件
  static Future<MigrationResult> _migrateFiles(
    Directory oldDir,
    Directory newDir, {
    required Future<bool> Function() savePath,
  }) async {
    Directory? stagingDir;
    final committedTargets = <Directory>[];
    var preferenceSaved = false;
    var fileCount = 0;
    var workFolderCount = 0;
    var skippedCount = 0;
    var errorCount = 0;
    final skippedItems = <String>[];

    try {
      // 检查旧目录是否存在
      if (!await oldDir.exists()) {
        if (!await savePath()) {
          return MigrationResult(success: false, message: '保存下载路径设置失败');
        }
        return MigrationResult(success: true, message: '原目录不存在，无需迁移');
      }

      if (await _pathsOverlap(oldDir, newDir)) {
        return MigrationResult(success: false, message: '原目录与新目录存在重叠，无法迁移');
      }

      final managedDirectories = <({Directory source, String name})>[];

      // 只遍历旧目录的第一层（不递归）
      await for (final entity in oldDir.list(followLinks: false)) {
        if (entity is Directory) {
          final folderName = p.basename(entity.path);
          final workId = LocalWorkMetadataService.parseWorkIdFromName(
            folderName,
          );

          // 迁移以数字命名的文件夹（作品文件夹）或字幕库文件夹
          if (workId != null ||
              folderName == SubtitleLibraryRules.libraryFolderName) {
            managedDirectories.add((source: entity, name: folderName));
          } else {
            // 跳过非作品命名且不是字幕库的文件夹（可能是用户的其他文件）
            skippedCount++;
            skippedItems.add(folderName);
            _log.debug('跳过文件夹: $folderName', tag: 'DownloadPath');
          }
        } else if (entity is File) {
          // 跳过下载目录根目录下的文件（可能是用户的其他文件）
          final fileName = p.basename(entity.path);
          skippedCount++;
          skippedItems.add(fileName);
          _log.debug('跳过根目录文件: $fileName', tag: 'DownloadPath');
        }
      }

      final conflictingItems = <String>[];
      for (final item in managedDirectories) {
        final destination = Directory(p.join(newDir.path, item.name));
        if (await _pathExists(destination.path)) {
          conflictingItems.add(item.name);
        }
      }
      if (conflictingItems.isNotEmpty) {
        return MigrationResult(
          success: false,
          message: '目标目录已存在同名项目，未迁移: ${conflictingItems.join(", ")}',
        );
      }

      if (managedDirectories.isNotEmpty) {
        stagingDir = await newDir.createTemp('.iroru-');
        for (final item in managedDirectories) {
          final stagedDirectory = Directory(p.join(stagingDir.path, item.name));
          await stagedDirectory.create(recursive: true);
          fileCount += await _copyDirectoryContents(
            item.source,
            stagedDirectory,
          );
          workFolderCount++;
        }

        for (final item in managedDirectories) {
          final stagedDirectory = Directory(p.join(stagingDir.path, item.name));
          final destination = Directory(p.join(newDir.path, item.name));
          if (await _pathExists(destination.path)) {
            throw FileSystemException('目标目录已存在同名项目', destination.path);
          }
          await stagedDirectory.rename(destination.path);
          committedTargets.add(destination);
        }
      }

      if (!await savePath()) {
        throw const FileSystemException('保存下载路径设置失败');
      }
      preferenceSaved = true;

      for (final item in managedDirectories) {
        try {
          await item.source.delete(recursive: true);
        } catch (e) {
          _log.error('删除原文件夹失败: ${item.name}, 错误: $e', tag: 'DownloadPath');
          errorCount++;
        }
      }

      // 检查旧目录是否为空，只有为空时才删除
      bool isOldDirEmpty = true;
      try {
        final remainingEntities = await oldDir.list().toList();
        isOldDirEmpty = remainingEntities.isEmpty;

        if (isOldDirEmpty) {
          try {
            await oldDir.delete(recursive: false);
            _log.info('已删除空的旧目录', tag: 'DownloadPath');
          } catch (e) {
            _log.error('删除空目录失败: $e', tag: 'DownloadPath');
            // 不影响迁移结果
          }
        } else {
          _log.info(
            '旧目录中还有 ${remainingEntities.length} 个项目，保留目录',
            tag: 'DownloadPath',
          );
        }
      } catch (e) {
        _log.error('检查旧目录是否为空时出错: $e', tag: 'DownloadPath');
      }

      String resultMessage = '迁移完成: $workFolderCount 个作品文件夹, $fileCount 个文件';
      if (skippedCount > 0) {
        resultMessage += '\n跳过 $skippedCount 个非下载项目（已保留）';
        if (skippedItems.length <= 5) {
          resultMessage += ': ${skippedItems.join(", ")}';
        }
      }
      if (errorCount > 0) {
        resultMessage += '\n$errorCount 个错误';
      }
      if (!isOldDirEmpty) {
        resultMessage += '\n原目录保留（包含其他文件）';
      }

      return MigrationResult(
        success: true,
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
      return MigrationResult(
        success: false,
        message: '迁移失败: $e',
        errorCount: errorCount,
      );
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
    // iOS 在沙盒限制下不建议支持自定义路径
    // 但可以通过文档选择器访问
    return Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isAndroid ||
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
  final bool success;
  final String message;
  final int fileCount;
  final int errorCount;

  MigrationResult({
    required this.success,
    required this.message,
    this.fileCount = 0,
    this.errorCount = 0,
  });
}
