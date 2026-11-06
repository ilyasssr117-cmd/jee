import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'analytics_service.dart';
import 'services/remote_config_service.dart';
import 'local_store.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'photo_saver.dart';
import 'media_headers.dart';
import 'stream_resolver.dart';
import 'touch.dart';
import 'video_json.dart';
import 'video_repository.dart';

enum DownloadStatus { queued, downloading, done, failed, paused }

class DownloadItem {
  DownloadItem({
    required this.video,
    this.status = DownloadStatus.queued,
    this.fileName,
    this.thumbName,
    this.bytesTotal = 0,
    int bytesDone = 0,
    this.error,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now() {
    bytes.value = bytesDone;
  }

  final Video video;
  DownloadStatus status;
  String? fileName;
  String? thumbName;
  int bytesTotal;
  String? error;
  final DateTime addedAt;

  final ValueNotifier<int> bytes = ValueNotifier<int>(0);

  double? get progress => bytesTotal > 0
      ? (bytes.value / bytesTotal).clamp(0.0, 1.0).toDouble()
      : null;

  bool get hasPartial => status != DownloadStatus.done && bytes.value > 0;
}

class _DownloadFailure implements Exception {
  const _DownloadFailure(this.message);

  final String message;
}

class DownloadStore extends ChangeNotifier {
  DownloadStore._();

  static final DownloadStore instance = DownloadStore._();

  static const String _key = 'downloads_v1';

  static const String _subDir = 'downloads';
  static const int _maxQueueItems = 160;
  static const int _maxVideoBytes = 2 * 1024 * 1024 * 1024;
  static final RegExp _safeFilePattern = RegExp(
    r'^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,159}$',
  );

  final List<DownloadItem> _items = <DownloadItem>[];
  late final UnmodifiableListView<DownloadItem> _view =
      UnmodifiableListView<DownloadItem>(_items);

  final Map<String, DownloadTask> _tasks = <String, DownloadTask>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _removing = <String>{};
  final Set<String> _pausing = <String>{};
  final Set<String> _sizeRejected = <String>{};
  final Map<String, String> _thumbs = <String, String>{};
  final Set<String> _pendingEnqueueIds = <String>{};

  final Map<String, String> _directUrls = <String, String>{};
  final http.Client _thumbClient = http.Client();
  Directory? _dir;
  bool _running = false;
  bool _initialized = false;
  Future<void>? _initialization;
  bool _downloaderInitialized = false;
  bool _downloaderConfigured = false;
  bool _downloaderCallbacksRegistered = false;
  Future<void>? _downloaderInitialization;

  List<DownloadItem> get items => _view;

  DownloadItem? item(String id) {
    for (final entry in _items) {
      if (entry.video.id == id) return entry;
    }
    return null;
  }

  int get doneCount =>
      _items.where((entry) => entry.status == DownloadStatus.done).length;

  int get totalBytes => _items
      .where((entry) => entry.status == DownloadStatus.done)
      .fold<int>(0, (sum, entry) => sum + entry.bytesTotal);

  Future<void> init() async {
    if (_initialized) return;
    final pending = _initialization;
    if (pending != null) {
      await pending;
      return;
    }

    late final Future<void> operation;
    operation = _initializeStorage().whenComplete(() {
      if (identical(_initialization, operation)) _initialization = null;
    });
    _initialization = operation;
    await operation;
  }

  Future<void> _initializeStorage() async {
    // Do not mark the store initialized until the directory is available.
    // A transient platform/storage failure can then be retried later.
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory('${documents.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    if (!await dir.exists()) {
      throw const FileSystemException(
          'Could not create the downloads directory.');
    }
    _dir = dir;

    for (final old in _items) {
      old.bytes.dispose();
    }
    _items.clear();
    _tasks.clear();
    if (_pendingEnqueueIds.isEmpty) _directUrls.clear();
    _thumbs.clear();

    for (final raw in LocalStore.readList(_key).take(_maxQueueItems * 3)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final meta = decoded['v'];
        if (meta is! Map<String, dynamic>) continue;
        final video = videoFromJson(meta);
        if (video == null) continue;
        final index = decoded['s'];
        var status =
            index is int && index >= 0 && index < DownloadStatus.values.length
                ? DownloadStatus.values[index]
                : DownloadStatus.failed;
        if (status == DownloadStatus.queued) status = DownloadStatus.paused;
        final rawFileName =
            decoded['f'] is String ? decoded['f'] as String : null;
        final fileName = _isSafeFileName(rawFileName) ? rawFileName : null;
        final entry = DownloadItem(
          video: video,
          status: status,
          fileName: fileName,
          thumbName: _isSafeFileName(
            decoded['i'] is String ? decoded['i'] as String : null,
          )
              ? decoded['i'] as String
              : null,
          bytesTotal: decoded['b'] is int &&
                  (decoded['b'] as int) >= 0 &&
                  (decoded['b'] as int) <= _maxVideoBytes
              ? decoded['b'] as int
              : 0,
          error: decoded['e'] is String ? decoded['e'] as String : null,
          addedAt: DateTime.fromMillisecondsSinceEpoch(
            decoded['t'] is int ? decoded['t'] as int : 0,
          ),
        );

        if (status == DownloadStatus.done) {
          entry.bytes.value = entry.bytesTotal;
          if (await _verifyLocalPathOf(entry) == null) {
            entry.bytes.dispose();
            continue;
          }
        } else if (fileName != null) {
          final part = File('${dir.path}/$fileName.part');
          final partialBytes = await part.exists() ? await part.length() : 0;
          if (partialBytes > _maxVideoBytes) {
            entry
              ..status = DownloadStatus.failed
              ..bytesTotal = 0
              ..error = 'This file exceeds the 2 GB download limit.';
            unawaited(_deleteFiles(entry));
          } else {
            entry.bytes.value = partialBytes;
          }
        }

        final thumb = entry.thumbName;
        if (thumb != null &&
            _isSafeFileName(thumb) &&
            await File('${dir.path}/$thumb').exists()) {
          _thumbs[video.id] = '${dir.path}/$thumb';
        } else {
          entry.thumbName = null;
        }
        _items.add(entry);
      } catch (_) {}
    }
    _items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (_items.length > _maxQueueItems) {
      final removable = _items
          .where((entry) => entry.status != DownloadStatus.downloading)
          .toList()
        ..sort((a, b) => a.addedAt.compareTo(b.addedAt));
      while (_items.length > _maxQueueItems && removable.isNotEmpty) {
        final old = removable.removeAt(0);
        if (!_items.remove(old)) continue;
        old.bytes.dispose();
        unawaited(_deleteFiles(old));
      }
    }

    _initialized = true;
    unawaited(_cleanOrphans());
    unawaited(_ensureDownloaderReady().catchError((Object error) {
      debugPrint(
        '[DOWNLOADS] Startup downloader setup failed; it will retry on demand: ${error.runtimeType}',
      );
    }));
  }

  Future<void> _ensureDownloaderReady() {
    if (_downloaderInitialized) return Future<void>.value();
    final pending = _downloaderInitialization;
    if (pending != null) return pending;

    late final Future<void> operation;
    operation = _initDownloader().whenComplete(() {
      if (identical(_downloaderInitialization, operation)) {
        _downloaderInitialization = null;
      }
    });
    _downloaderInitialization = operation;
    return operation;
  }

  Future<void> _initDownloader() async {
    try {
      final downloader = FileDownloader();
      if (!_downloaderConfigured) {
        await downloader.configure(
          globalConfig: <(String, dynamic)>[
            (Config.holdingQueue, (2, null, null)),
          ],
          androidConfig: <(String, dynamic)>[
            (Config.runInForeground, Config.always),
          ],
        );
        _downloaderConfigured = true;
      }
      if (!_downloaderCallbacksRegistered) {
        downloader.configureNotificationForGroup(
          FileDownloader.defaultGroup,
          running: const TaskNotification(
            'Downloading {progress}',
            '{displayName}',
          ),
          complete:
              const TaskNotification('Download complete', '{displayName}'),
          error: const TaskNotification('Download failed', '{displayName}'),
          paused: const TaskNotification('Download paused', '{displayName}'),
          progressBar: true,
        );
        downloader.registerCallbacks(
          taskStatusCallback: _onStatus,
          taskProgressCallback: _onProgress,
        );
        _downloaderCallbacksRegistered = true;
      }
      await downloader.trackTasks();

      for (final entry in List<DownloadItem>.of(_items)) {
        if (entry.status == DownloadStatus.done) continue;
        final record = await downloader.database.recordForId(_taskId(entry)) ??
            await downloader.database.recordForId(_legacyTaskId(entry));
        if (record == null) {
          if (entry.status == DownloadStatus.downloading) {
            entry.status = DownloadStatus.paused;
          }
          continue;
        }
        final task = record.task;
        if (task is DownloadTask) _tasks[entry.video.id] = task;
        switch (record.status) {
          case TaskStatus.enqueued:
          case TaskStatus.running:
          case TaskStatus.waitingToRetry:
            entry.status = DownloadStatus.downloading;
          case TaskStatus.paused:
            entry.status = DownloadStatus.paused;
          case TaskStatus.complete:
            _markDone(entry);
          default:
            if (entry.status == DownloadStatus.downloading) {
              entry.status = DownloadStatus.paused;
            }
        }
      }
      await downloader.resumeFromBackground();
      await downloader.rescheduleKilledTasks();
      _downloaderInitialized = true;
      _persist();
      notifyListeners();
    } catch (error) {
      debugPrint(
        '[DOWNLOADS] Background downloader unavailable: ${error.runtimeType}',
      );
      rethrow;
    }
  }

  Future<void> _enqueueAfterInitialization(Video video) async {
    final id = video.id;
    try {
      await init();
    } catch (error) {
      debugPrint(
        '[DOWNLOADS] Storage initialization retry failed: ${error.runtimeType}',
      );
      _pendingEnqueueIds.remove(id);
      final existing = item(id);
      if (existing != null) {
        existing
          ..status = DownloadStatus.failed
          ..error = 'Storage unavailable. Tap resume to retry.';
      } else if (_items.length < _maxQueueItems) {
        _items.insert(
          0,
          DownloadItem(
            video: video.copyWith(streamUrl: ''),
            status: DownloadStatus.failed,
            error: 'Storage unavailable. Tap resume to retry.',
          ),
        );
      }
      AnalyticsService.instance.trackDownload('failed', id);
      _persist();
      notifyListeners();
      return;
    }

    _pendingEnqueueIds.remove(id);
    final existing = item(id);
    if (existing != null) {
      if (existing.status == DownloadStatus.failed ||
          existing.status == DownloadStatus.paused) {
        existing
          ..status = DownloadStatus.queued
          ..error = null;
        _persist();
        notifyListeners();
        unawaited(_pump());
      }
      return;
    }
    if (_items.length >= _maxQueueItems) return;
    _items.insert(0, DownloadItem(video: video.copyWith(streamUrl: '')));
    _persist();
    notifyListeners();
    unawaited(_pump());
  }

  String _legacyTaskId(DownloadItem entry) {
    final safe = entry.video.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'dl_${safe.length > 80 ? safe.substring(0, 80) : safe}';
  }

  String _taskId(DownloadItem entry) {
    final id = entry.video.id;
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'dl_${safe.length > 60 ? safe.substring(0, 60) : safe}_${_stableHash(id)}';
  }

  static String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static bool _isSafeFileName(String? value) =>
      value != null &&
      value != '.' &&
      value != '..' &&
      !value.contains('..') &&
      !value.contains('/') &&
      !value.contains('\\') &&
      _safeFilePattern.hasMatch(value);

  DownloadItem? _itemForTask(Task task) {
    final id = task.metaData;
    return id.isEmpty ? null : item(id);
  }

  void _markDone(DownloadItem entry) {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null || name == null) return;
    if (!_isSafeFileName(name)) {
      entry
        ..status = DownloadStatus.failed
        ..error = 'The download file name is invalid. Tap resume.';
      return;
    }
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) {
      entry
        ..status = DownloadStatus.failed
        ..error = 'The downloaded file is missing. Tap resume.';
      return;
    }
    final size = file.lengthSync();
    if (size > _maxVideoBytes) {
      entry
        ..status = DownloadStatus.failed
        ..bytesTotal = 0
        ..error = 'This file exceeds the 2 GB download limit.';
      unawaited(_deleteFiles(entry));
      return;
    }
    entry
      ..status = DownloadStatus.done
      ..bytesTotal = size
      ..error = null;
    entry.bytes.value = size;
  }

  void _removeTaskEntry(DownloadItem entry) {
    final id = entry.video.id;
    _removing.remove(id);
    _cancelled.remove(id);
    _pausing.remove(id);
    _sizeRejected.remove(id);
    _tasks.remove(id);
    _directUrls.remove(id);
    _thumbs.remove(id);
    _items.remove(entry);
    entry.bytes.dispose();
    unawaited(_deleteFiles(entry));
  }

  void _onStatus(TaskStatusUpdate update) {
    final entry = _itemForTask(update.task);
    if (entry == null) return;
    final id = entry.video.id;
    final previousStatus = entry.status;
    switch (update.status) {
      case TaskStatus.enqueued:
      case TaskStatus.running:
      case TaskStatus.waitingToRetry:
        if (!_sizeRejected.contains(id) &&
            (entry.status != DownloadStatus.paused || !_pausing.contains(id))) {
          entry.status = DownloadStatus.downloading;
        }
      case TaskStatus.complete:
        if (_removing.contains(id) || _cancelled.contains(id)) {
          _removeTaskEntry(entry);
        } else if (_sizeRejected.remove(id)) {
          _tasks.remove(id);
          entry
            ..status = DownloadStatus.failed
            ..error = 'This file exceeds the 2 GB download limit.';
          unawaited(_deleteFiles(entry));
        } else {
          _tasks.remove(id);
          _directUrls.remove(id);
          _markDone(entry);
          if (entry.status == DownloadStatus.done) {
            Haptics.play(Haptic.medium);
          }
        }
      case TaskStatus.paused:
        entry.status = DownloadStatus.paused;
        _pausing.remove(id);
      case TaskStatus.canceled:
        _tasks.remove(id);
        if (_cancelled.contains(id) || _removing.contains(id)) {
          _removeTaskEntry(entry);
        } else if (_sizeRejected.remove(id)) {
          entry
            ..status = DownloadStatus.failed
            ..error = 'This file exceeds the 2 GB download limit.';
          unawaited(_deleteFiles(entry));
        } else if (_pausing.remove(id)) {
          entry.status = DownloadStatus.paused;
          entry.bytes.value = 0;
        } else {
          entry.status = DownloadStatus.paused;
        }
      case TaskStatus.notFound:
        if (_removing.contains(id) || _cancelled.contains(id)) {
          _removeTaskEntry(entry);
        } else {
          _tasks.remove(id);
          entry
            ..status = DownloadStatus.failed
            ..error = 'The video file wasn\u2019t found on the server.';
        }
      case TaskStatus.failed:
        if (_removing.contains(id) || _cancelled.contains(id)) {
          _removeTaskEntry(entry);
        } else {
          _tasks.remove(id);
          final sizeRejected = _sizeRejected.remove(id);
          final text = update.exception?.description ?? '';
          entry
            ..status = DownloadStatus.failed
            ..error = sizeRejected
                ? 'This file exceeds the 2 GB download limit.'
                : (text.contains('Socket') || text.contains('timed out'))
                    ? 'Connection problem. Tap resume.'
                    : 'Download failed. Tap resume.';
          if (sizeRejected) unawaited(_deleteFiles(entry));
        }
    }
    if (entry.status == DownloadStatus.done &&
        previousStatus != DownloadStatus.done) {
      AnalyticsService.instance.trackDownload('completed', id);
    } else if (entry.status == DownloadStatus.failed &&
        previousStatus != DownloadStatus.failed) {
      AnalyticsService.instance.trackDownload('failed', id);
    }
    _persist();
    notifyListeners();
    _syncActivity(force: true);
  }

  DateTime _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);
  bool _activityOn = false;
  String _lastActiveTitle = 'Downloads';

  void _syncActivity({bool force = false}) {
    final active = _items
        .where(
          (e) =>
              e.status == DownloadStatus.downloading ||
              e.status == DownloadStatus.queued,
        )
        .toList();
    if (active.isEmpty) {
      if (_activityOn) {
        _activityOn = false;
        final anyDone = _items.any((e) => e.status == DownloadStatus.done);
        unawaited(
          NativeBridge.instance.endLiveActivity(
            title: _lastActiveTitle,
            finished: anyDone,
          ),
        );
      }
      return;
    }
    final now = DateTime.now();
    if (!force && now.difference(_lastActivity) < const Duration(seconds: 1)) {
      return;
    }
    _lastActivity = now;
    _activityOn = true;
    var done = 0;
    var total = 0;
    for (final e in active) {
      if (e.bytesTotal > 0) {
        done += e.bytes.value;
        total += e.bytesTotal;
      }
    }
    final current = active.firstWhere(
      (e) => e.status == DownloadStatus.downloading,
      orElse: () => active.first,
    );
    _lastActiveTitle = current.video.title;
    unawaited(
      NativeBridge.instance.updateLiveActivity(
        title: current.video.title,
        progress: total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : -1,
        count: active.length,
      ),
    );
  }

  void _onProgress(TaskProgressUpdate update) {
    final entry = _itemForTask(update.task);
    if (entry == null || _sizeRejected.contains(entry.video.id)) return;
    if (update.progress < 0) return;
    final expected = update.expectedFileSize;
    if (expected > _maxVideoBytes) {
      if (_sizeRejected.add(entry.video.id)) {
        entry
          ..status = DownloadStatus.failed
          ..error = 'This file exceeds the 2 GB download limit.';
        _persist();
        notifyListeners();
        final task = _tasks[entry.video.id];
        if (task != null) {
          unawaited(() async {
            try {
              await FileDownloader().cancelTaskWithId(task.taskId);
            } catch (_) {}
          }());
        }
      }
      return;
    }
    if (expected > 0 && entry.bytesTotal != expected) {
      entry.bytesTotal = expected;
      notifyListeners();
    }
    final total = entry.bytesTotal;
    if (total > 0) entry.bytes.value = (update.progress * total).round();
    _syncActivity();
  }

  Future<void> _cleanOrphans() async {
    final dir = _dir;
    if (dir == null) return;
    final owned = <String>{
      for (final entry in _items) ...<String>{
        if (_isSafeFileName(entry.fileName)) entry.fileName!,
        if (_isSafeFileName(entry.fileName)) '${entry.fileName}.part',
        if (_isSafeFileName(entry.thumbName)) entry.thumbName!,
        if (_isSafeFileName(entry.thumbName)) '${entry.thumbName}.part',
      },
    };
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('v_') && !owned.contains(name)) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  String? localPathOf(DownloadItem entry) {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null ||
        !_isSafeFileName(name) ||
        entry.status != DownloadStatus.done) {
      return null;
    }
    final path = '${dir.path}/$name';
    if (!File(path).existsSync()) return null;
    return path;
  }

  Future<String?> _verifyLocalPathOf(DownloadItem entry) async {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null ||
        !_isSafeFileName(name) ||
        entry.status != DownloadStatus.done) {
      return null;
    }
    final path = '${dir.path}/$name';
    if (!await File(path).exists()) return null;
    return path;
  }

  String? localPath(String id) {
    final entry = item(id);
    return entry == null ? null : localPathOf(entry);
  }

  String? thumbPath(String id) => _thumbs[id];

  Future<GallerySaveResult> saveToPhotos(String id) async {
    final path = localPath(id);
    if (path == null) return const GallerySaveResult(saved: 0, failed: 1);
    return PhotoSaver.saveVideoToGallery(path);
  }

  Future<bool> shareFile(String id) async {
    final path = localPath(id);
    if (path == null) return false;
    return NativeBridge.instance.shareFile(path);
  }

  bool enqueueDirect(Video video, String url) {
    if (!RemoteConfigService.instance.isFeatureEnabled('downloads')) {
      return false;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        url.length > 8192) {
      return false;
    }
    final existing = item(video.id);
    if (existing != null) {
      if (existing.status == DownloadStatus.paused ||
          existing.status == DownloadStatus.failed) {
        _directUrls[video.id] = url;
      }
      return enqueue(video);
    }
    _directUrls[video.id] = url;
    final accepted = enqueue(video);
    if (!accepted) _directUrls.remove(video.id);
    return accepted;
  }

  bool enqueue(Video video) {
    if (!RemoteConfigService.instance.isFeatureEnabled('downloads')) {
      return false;
    }
    final existing = item(video.id);
    if (existing != null) {
      if (existing.status == DownloadStatus.failed ||
          existing.status == DownloadStatus.paused) {
        resume(video.id);
      }
      return true;
    }
    if (_items.length >= _maxQueueItems) return false;
    if (!_initialized) {
      if (_pendingEnqueueIds.add(video.id)) {
        AnalyticsService.instance.trackDownload('started', video.id);
        unawaited(_enqueueAfterInitialization(video));
      }
      return true;
    }
    AnalyticsService.instance.trackDownload('started', video.id);
    _items.insert(0, DownloadItem(video: video.copyWith(streamUrl: '')));
    _persist();
    notifyListeners();
    unawaited(_pump());
    return true;
  }

  void resume(String id) {
    final entry = item(id);
    if (entry == null ||
        (entry.status != DownloadStatus.paused &&
            entry.status != DownloadStatus.failed)) {
      return;
    }
    AnalyticsService.instance.trackDownload('started', id);
    _sizeRejected.remove(id);
    if (!_initialized) {
      if (_pendingEnqueueIds.add(id)) {
        unawaited(_enqueueAfterInitialization(entry.video));
      }
      return;
    }
    final task = _downloaderInitialized ? _tasks[id] : null;
    if (entry.status == DownloadStatus.paused && task != null) {
      unawaited(() async {
        var resumed = false;
        try {
          resumed = await FileDownloader().resume(task);
        } catch (_) {}
        if (resumed) {
          entry
            ..status = DownloadStatus.downloading
            ..error = null;
        } else {
          _tasks.remove(id);
          entry
            ..status = DownloadStatus.queued
            ..error = null;
          unawaited(_pump());
        }
        _persist();
        notifyListeners();
      }());
      return;
    }
    entry
      ..status = DownloadStatus.queued
      ..error = null;
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> pause(String id) async {
    final entry = item(id);
    if (entry == null) return;
    if (entry.status == DownloadStatus.queued) {
      entry.status = DownloadStatus.paused;
      _persist();
      notifyListeners();
      return;
    }
    if (entry.status != DownloadStatus.downloading) return;
    final task = _tasks[id];
    if (task == null) {
      _pausing.add(id);
      entry.status = DownloadStatus.paused;
      _persist();
      notifyListeners();
      return;
    }
    _pausing.add(id);
    var ok = false;
    try {
      ok = await FileDownloader().pause(task);
    } catch (_) {}
    if (!ok) {
      await FileDownloader().cancelTaskWithId(task.taskId);
    }
  }

  Future<void> remove(String id) async {
    final entry = item(id);
    if (entry == null) return;
    _removing.add(id);
    _sizeRejected.remove(id);
    final task = _tasks[id];
    if (entry.status == DownloadStatus.downloading && task != null) {
      _cancelled.add(id);
      try {
        final cancelled = await FileDownloader().cancelTaskWithId(task.taskId);
        if (cancelled) return;
      } catch (_) {}
      _cancelled.remove(id);
    }
    _tasks.remove(id);
    _directUrls.remove(id);
    _items.remove(entry);
    _removing.remove(id);
    entry.bytes.dispose();
    _thumbs.remove(id);
    _persist();
    notifyListeners();
    await _deleteFiles(entry);
  }

  Future<void> removeAll() async {
    for (final entry in List<DownloadItem>.of(_items)) {
      await remove(entry.video.id);
    }
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        DownloadItem? next;
        for (final entry in _items.reversed) {
          if (entry.status == DownloadStatus.queued) {
            next = entry;
            break;
          }
        }
        if (next == null) break;
        await _prepareAndEnqueue(next);
      }
    } finally {
      _running = false;
    }
  }

  bool _stopPreparationIfNeeded(String id, DownloadItem entry) {
    if (!identical(item(id), entry) || _removing.contains(id)) return true;
    if (_pausing.remove(id)) {
      entry.status = DownloadStatus.paused;
      _persist();
      notifyListeners();
      return true;
    }
    return entry.status == DownloadStatus.paused;
  }

  Future<void> _prepareAndEnqueue(DownloadItem entry) async {
    final id = entry.video.id;
    entry.status = DownloadStatus.downloading;
    entry.error = null;
    notifyListeners();

    try {
      final dir = _dir;
      if (dir == null) {
        throw const _DownloadFailure('Storage isn\u2019t available.');
      }

      final direct = _directUrls[id];
      final resolved = direct != null
          ? entry.video.copyWith(streamUrl: direct)
          : await videoRepository.resolveForPlayback(
              entry.video.copyWith(streamUrl: ''),
            );
      if (_stopPreparationIfNeeded(id, entry)) return;

      final url = resolved.streamUrl.trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          url.length > 8192) {
        throw const _DownloadFailure('No downloadable link was found.');
      }
      if (url.toLowerCase().contains('.m3u8')) {
        throw const _DownloadFailure(
          'This video is a stream and can\u2019t be saved.',
        );
      }

      final pageUrl = resolved.pageUrl ?? entry.video.pageUrl;
      final pageUri = Uri.tryParse(pageUrl?.trim() ?? '');
      final validPage = pageUri != null &&
          (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
          pageUri.host.isNotEmpty;
      final headers = <String, String>{...streamHeaders(uri, pageUrl)};
      try {
        if (direct != null) throw const _DownloadFailure('direct');
        final cookie = await videoRepository.getPlaybackCookieHeader(
          streamUri: uri,
          pageUrl: validPage ? pageUri.toString() : null,
          userAgent: headers['User-Agent'] ?? '',
        );
        if (cookie.isNotEmpty) headers['Cookie'] = cookie;
      } catch (error) {
        if (direct == null) {
          debugPrint(
            '[DOWNLOADS] Cookie lookup failed (${error.runtimeType}).',
          );
        }
      }
      if (_stopPreparationIfNeeded(id, entry)) return;

      var finalUri = uri;
      try {
        finalUri = await resolveFinalStreamUri(uri, headers);
      } catch (_) {}
      if (finalUri.origin != uri.origin) {
        headers.removeWhere(
          (name, _) => const <String>{
            'cookie',
            'authorization',
            'proxy-authorization',
            'referer',
          }.contains(name.toLowerCase()),
        );
      }
      if (_stopPreparationIfNeeded(id, entry)) return;

      entry.fileName ??= _newFileName(id);
      final fileName = entry.fileName!;
      final stale = File('${dir.path}/$fileName');
      if (stale.existsSync()) stale.deleteSync();

      unawaited(_saveThumbnail(entry, dir, pageUrl));

      await _ensureNotificationPermission();
      if (_stopPreparationIfNeeded(id, entry)) return;
      // Initialization is lazy and retryable. A failed native/plugin setup
      // must not be treated as ready; resume will attempt initialization again.
      try {
        await _ensureDownloaderReady().timeout(const Duration(seconds: 40));
      } catch (error) {
        debugPrint(
          '[DOWNLOADS] Downloader setup retryable failure: ${error.runtimeType}',
        );
        throw const _DownloadFailure(
          'Background downloads are unavailable. Tap resume to retry.',
        );
      }
      if (_stopPreparationIfNeeded(id, entry)) return;

      final task = DownloadTask(
        taskId: _taskId(entry),
        url: finalUri.toString(),
        headers: headers,
        filename: fileName,
        directory: _subDir,
        baseDirectory: BaseDirectory.applicationDocuments,
        updates: Updates.statusAndProgress,
        retries: 3,
        allowPause: true,
        displayName: entry.video.title,
        metaData: id,
      );
      _tasks[id] = task;
      entry.bytes.value = 0;
      final started = await FileDownloader().enqueue(task);
      if (!started) {
        _tasks.remove(id);
        throw const _DownloadFailure('Couldn\u2019t start the download.');
      }
      if (!identical(item(id), entry) || _removing.contains(id)) {
        try {
          await FileDownloader().cancelTaskWithId(task.taskId);
        } catch (_) {}
        _tasks.remove(id);
        _directUrls.remove(id);
        return;
      }
      _directUrls.remove(id);
    } on _DownloadFailure catch (failure) {
      if (identical(item(id), entry)) {
        entry
          ..status = DownloadStatus.failed
          ..error = failure.message;
      }
    } catch (error) {
      debugPrint('[DOWNLOADS] Download setup failed (${error.runtimeType}).');
      if (identical(item(id), entry)) {
        entry
          ..status = DownloadStatus.failed
          ..error = error is TimeoutException || error is SocketException
              ? 'Connection problem. Tap resume.'
              : 'Download failed. Tap resume.';
      }
    } finally {
      if (!identical(item(id), entry)) {
        _removing.remove(id);
        _directUrls.remove(id);
      }
      _persist();
      notifyListeners();
      _syncActivity(force: true);
    }
  }

  bool _askedForNotifications = false;

  Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid || _askedForNotifications) return;
    _askedForNotifications = true;
    try {
      final permissions = FileDownloader().permissions;
      final status = await permissions.status(PermissionType.notifications);
      if (status != PermissionStatus.granted) {
        await permissions.request(PermissionType.notifications);
      }
    } catch (_) {}
  }

  String _newFileName(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final short = safe.length > 48 ? safe.substring(0, 48) : safe;
    return 'v_${short}_${_stableHash(id)}_${DateTime.now().millisecondsSinceEpoch}.mp4';
  }

  Future<void> _saveThumbnail(
    DownloadItem entry,
    Directory dir,
    String? pageUrl,
  ) async {
    final id = entry.video.id;
    if (_thumbs.containsKey(id)) return;
    final url = entry.video.thumbnailUrl?.trim() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    try {
      const maxBytes = 3 * 1024 * 1024;
      final base = streamHeaders(uri, pageUrl);
      final request = http.Request('GET', uri)
        ..headers.addAll(<String, String>{
          'User-Agent': base['User-Agent'] ?? '',
          'Referer': base['Referer'] ?? '',
          'Accept': 'image/*,*/*;q=0.8',
        });
      final response =
          await _thumbClient.send(request).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength! > maxBytes)) {
        await response.stream.drain<void>().timeout(
              const Duration(seconds: 3),
              onTimeout: () {},
            );
        return;
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        received += chunk.length;
        if (received > maxBytes) return;
        bytes.add(chunk);
      }
      final imageBytes = bytes.takeBytes();
      if (!identical(item(id), entry) || !_looksLikeImage(imageBytes)) return;
      final name = '${entry.fileName ?? _newFileName(id)}.thumb';
      if (!_isSafeFileName(name)) return;
      final file = File('${dir.path}/$name');
      final temp = File('${dir.path}/$name.part');
      await temp.writeAsBytes(imageBytes, flush: true);
      if (!identical(item(id), entry)) {
        if (await temp.exists()) await temp.delete();
        return;
      }
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      entry.thumbName = name;
      _thumbs[id] = file.path;
      _persist();
      notifyListeners();
    } catch (error) {
      debugPrint('[DOWNLOADS] Thumbnail not saved (${error.runtimeType}).');
    }
  }

  bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) return false;
    final jpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
    final png = bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    final gif = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
    final webp = bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    return jpeg || png || gif || webp;
  }

  Future<void> _deleteFiles(DownloadItem entry) async {
    final dir = _dir;
    if (dir == null) return;
    for (final name in <String?>[
      entry.fileName,
      entry.fileName == null ? null : '${entry.fileName}.part',
      entry.thumbName,
      entry.thumbName == null ? null : '${entry.thumbName}.part',
    ]) {
      if (!_isSafeFileName(name)) continue;
      try {
        final file = File('${dir.path}/$name');
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  void _persist() => LocalStore.writeList(
        _key,
        _items
            .map(
              (entry) => jsonEncode(<String, dynamic>{
                'v': videoToJson(entry.video),
                's': entry.status.index,
                'f': entry.fileName,
                'i': entry.thumbName,
                'b': entry.bytesTotal,
                'e': entry.error,
                't': entry.addedAt.millisecondsSinceEpoch,
              }),
            )
            .toList(),
      );
}
