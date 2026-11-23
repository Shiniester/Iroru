import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../services/download_path_service.dart';
import '../services/log_service.dart';
import 'comic_library.dart';
import 'comic_models.dart';
import 'comic_source.dart';
import 'comic_images.dart';

enum ComicDownloadStatus { queued, downloading, paused, failed, complete }

class ComicDownloadTask {
  ComicDownloadTask({
    required this.comic,
    required this.chapter,
    required this.directory,
    this.status = ComicDownloadStatus.queued,
    this.pages = const [],
    this.completed = 0,
    this.error,
    this.coverPath,
  });
  final Comic comic;
  final ComicChapter chapter;
  String directory;
  String? _relativeDirectory;
  ComicDownloadStatus status;
  List<ComicPage> pages;
  int completed;
  String? error;
  String? coverPath;
  String get id => jsonEncode([comic.source, comic.id, chapter.id]);
  Map<String, dynamic> toJson() => {
    'comic': comic.toJson(),
    'chapter': chapter.toJson(),
    if (_relativeDirectory case final relative?)
      'relativeDirectory': relative
    else
      'directory': directory,
    'status': status.name,
    'pages': pages.map((p) => p.toJson()).toList(),
    'completed': completed,
    'error': error,
    'coverPath': _relativeDirectory != null && coverPath != null
        ? p.basename(coverPath!)
        : coverPath,
  };
  factory ComicDownloadTask.fromJson(Map<String, dynamic> j) {
    final relativeDirectory = j['relativeDirectory'] as String?;
    return ComicDownloadTask(
      comic: Comic.fromJson(j['comic']),
      chapter: ComicChapter.fromJson(j['chapter']),
      directory: relativeDirectory ?? j['directory'],
      status: ComicDownloadStatus.values.byName(j['status']),
      pages: (j['pages'] as List).map((v) => ComicPage.fromJson(v)).toList(),
      completed: j['completed'],
      error: j['error'],
      coverPath: j['coverPath'],
    ).._relativeDirectory = relativeDirectory;
  }

  void _setDirectory(Directory root) {
    final relativeDirectory = _relativeDirectory;
    if (relativeDirectory == null) return;
    directory = p.join(root.path, relativeDirectory);
    final cover = coverPath;
    if (cover != null) coverPath = p.join(directory, p.basename(cover));
  }

  String pathFor(int index) => p.join(directory, '$index.image');
}

class ComicDownloads extends ChangeNotifier {
  ComicDownloads(this.library, this.sourceFor, {this.imageLoader}) {
    ready = _restore();
  }
  final ComicImageLoader? imageLoader;
  final ComicLibrary library;
  final ComicSource Function(String) sourceFor;
  late final Future<void> ready;
  final List<ComicDownloadTask> tasks = [];
  CancelToken? _cancel;
  String? _activeId;
  Future<void>? _running;
  Completer<void>? _activeTask;
  Directory? _downloadRoot;
  int _editingTasks = 0;
  bool _disposed = false;

  Future<void> _restore() async {
    final restored = (await library.loadTasks())
        .map(ComicDownloadTask.fromJson)
        .toList();
    if (restored.any((task) => task._relativeDirectory != null)) {
      await _getDownloadRoot();
    }
    for (final task in restored) {
      if (_downloadRoot case final root?) task._setDirectory(root);
      if (task.status == ComicDownloadStatus.downloading ||
          task.status == ComicDownloadStatus.queued) {
        task.status = ComicDownloadStatus.paused;
      }
    }
    tasks.addAll(restored);
    _notify();
  }

  void setDownloadRoot(Directory root) {
    final comicsRoot = DownloadFolder.comics.inRoot(root);
    _downloadRoot = comicsRoot;
    for (final task in tasks) {
      task._setDirectory(comicsRoot);
    }
    _notify();
  }

  int get activeDownloadCount {
    final active = tasks
        .where(
          (task) =>
              task.id == _activeId ||
              task.status == ComicDownloadStatus.queued ||
              task.status == ComicDownloadStatus.downloading,
        )
        .length;
    return active == 0 && _editingTasks > 0 ? 1 : active;
  }

  Future<Directory> _getDownloadRoot() async {
    if (_downloadRoot case final root?) return root;
    final root = await DownloadPathService.getDownloadDirectory();
    return _downloadRoot ??= DownloadFolder.comics.inRoot(root);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String component(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');
  Future<void> enqueue(Comic comic, List<ComicChapter> chapters) async {
    _editingTasks++;
    try {
      await ready;
      final root = await _getDownloadRoot();
      for (final chapter in chapters) {
        if (tasks.any(
          (task) =>
              task.comic.key == comic.key && task.chapter.id == chapter.id,
        )) {
          continue;
        }
        final relativeDirectory = p.join(
          comic.source,
          component(comic.id),
          component(chapter.id),
        );
        final task = ComicDownloadTask(
          comic: comic,
          chapter: chapter,
          directory: p.join(root.path, relativeDirectory),
        ).._relativeDirectory = relativeDirectory;
        tasks.add(task);
        await library.saveTask(task.id, task.toJson());
      }
      _notify();
      _start();
    } finally {
      _editingTasks--;
    }
  }

  void _start() {
    if (_disposed || _running != null) return;
    _running = _drain().whenComplete(() {
      _running = null;
      if (!_disposed &&
          tasks.any((t) => t.status == ComicDownloadStatus.queued)) {
        _start();
      }
    });
  }

  Future<void> _drain() async {
    while (!_disposed) {
      final queued = tasks.where((t) => t.status == ComicDownloadStatus.queued);
      if (queued.isEmpty) return;
      final task = queued.first;
      _activeId = task.id;
      _activeTask = Completer<void>();
      _cancel = CancelToken();
      task.status = ComicDownloadStatus.downloading;
      task.error = null;
      _notify();
      try {
        final source = sourceFor(task.comic.source);
        task.pages = await source.pages(task.comic, task.chapter);
        task.completed = 0;
        if (task.pages.isEmpty) {
          throw const ComicSourceException('This chapter has no pages.');
        }
        await Directory(task.directory).create(recursive: true);
        for (var i = 0; i < task.pages.length; i++) {
          if (task.status != ComicDownloadStatus.downloading || _disposed) {
            break;
          }
          final target = File(task.pathFor(i));
          if (!await target.exists()) {
            final bytes = imageLoader != null
                ? await imageLoader!(source, task.pages[i])
                : await loadComicImage(
                    source.http,
                    task.pages[i],
                    cancelToken: _cancel,
                  );
            if (task.status != ComicDownloadStatus.downloading || _disposed) {
              break;
            }
            final temp = File('${target.path}.part');
            await temp.writeAsBytes(bytes, flush: true);
            await temp.rename(target.path);
          }
          task.completed = i + 1;
          await library.saveTask(task.id, task.toJson());
          _notify();
        }
        if (task.status == ComicDownloadStatus.downloading &&
            task.completed == task.pages.length) {
          if (task.comic.cover.isNotEmpty) {
            try {
              final cover = ComicPage(task.comic.cover);
              final bytes = imageLoader != null
                  ? await imageLoader!(source, cover)
                  : await loadComicImage(
                      source.http,
                      cover,
                      cancelToken: _cancel,
                    );
              final file = File(p.join(task.directory, 'cover.image'));
              await file.writeAsBytes(bytes, flush: true);
              task.coverPath = file.path;
            } catch (_) {
              // A cover failure does not invalidate downloaded chapter pages.
            }
          }
          if (task.status == ComicDownloadStatus.downloading) {
            task.status = ComicDownloadStatus.complete;
          }
        }
      } catch (e) {
        if (task.status != ComicDownloadStatus.paused) {
          task.status = ComicDownloadStatus.failed;
          task.error = e.toString();
        }
      } finally {
        try {
          await library.saveTask(task.id, task.toJson());
        } catch (error) {
          task.status = ComicDownloadStatus.failed;
          task.error = error.toString();
          LogService.instance.error(
            'Comic download persistence: $error',
            tag: 'Comics',
          );
        } finally {
          _activeTask?.complete();
          _activeTask = null;
          _activeId = null;
          _cancel = null;
          _notify();
        }
      }
    }
  }

  Future<void> pause(ComicDownloadTask task) async {
    task.status = ComicDownloadStatus.paused;
    if (_activeId == task.id) _cancel?.cancel();
    await library.saveTask(task.id, task.toJson());
    _notify();
  }

  Future<void> resume(ComicDownloadTask task) async {
    if (_activeId == task.id) await _activeTask?.future;
    task.status = ComicDownloadStatus.queued;
    task.error = null;
    await library.saveTask(task.id, task.toJson());
    _notify();
    _start();
  }

  Future<void> remove(ComicDownloadTask task) async {
    _editingTasks++;
    try {
      await pause(task);
      if (_activeId == task.id) await _activeTask?.future;
      // Only remove this task's explicitly stored files, never the selected root.
      for (var i = 0; i < task.pages.length; i++) {
        for (final path in [task.pathFor(i), '${task.pathFor(i)}.part']) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
      }
      if (task.coverPath != null && await File(task.coverPath!).exists()) {
        await File(task.coverPath!).delete();
      }
      tasks.remove(task);
      await library.deleteTask(task.id);
      _notify();
    } finally {
      _editingTasks--;
    }
  }

  Future<List<ComicPage>?> offlinePages(
    Comic comic,
    ComicChapter chapter,
  ) async {
    await ready;
    for (final task in tasks) {
      if (task.comic.key == comic.key &&
          task.chapter.id == chapter.id &&
          task.status == ComicDownloadStatus.complete) {
        final pages = <ComicPage>[];
        for (var i = 0; i < task.pages.length; i++) {
          if (!await File(task.pathFor(i)).exists()) {
            task.status = ComicDownloadStatus.failed;
            task.error = 'Downloaded file is missing.';
            await library.saveTask(task.id, task.toJson());
            _notify();
            return null;
          }
          pages.add(ComicPage(task.pages[i].url, localPath: task.pathFor(i)));
        }
        return pages;
      }
    }
    return null;
  }

  List<Comic> get completedComics {
    final completed = <String, List<ComicDownloadTask>>{};
    for (final task in tasks) {
      if (task.status == ComicDownloadStatus.complete) {
        (completed[task.comic.key] ??= []).add(task);
      }
    }
    return completed.values.map((group) {
      final comic = group.last.comic;
      final chapters = {
        for (final task in group) task.chapter.id: task.chapter,
      };
      final cover = group.reversed
          .map((task) => task.coverPath)
          .nonNulls
          .firstOrNull;
      return Comic(
        source: comic.source,
        id: comic.id,
        title: comic.title,
        cover: comic.cover,
        description: comic.description,
        tags: comic.tags,
        chapters: [
          for (final chapter in comic.chapters)
            if (chapters.remove(chapter.id) != null) chapter,
          ...chapters.values,
        ],
        rating: comic.rating,
        extra: {...comic.extra, if (cover != null) 'localCover': cover},
      );
    }).toList();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
