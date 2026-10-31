import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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

  final List<DownloadItem> _items = <DownloadItem>[];
  late final UnmodifiableListView<DownloadItem> _view =
      UnmodifiableListView<DownloadItem>(_items);

  final Map<String, DownloadTask> _tasks = <String, DownloadTask>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _pausing = <String>{};
  final Map<String, String> _thumbs = <String, String>{};

  final Map<String, String> _directUrls = <String, String>{};
  Directory? _dir;
  bool _running = false;

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
    try {
      final documents = await getApplicationDocumentsDirectory();
      final dir = Directory('${documents.path}/downloads');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir;
    } catch (error) {
      debugPrint('[DOWNLOADS] Storage unavailable: $error');
    }

    _items.clear();
    _thumbs.clear();
    final dir = _dir;
    for (final raw in LocalStore.readList(_key)) {
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
        final fileName =
            decoded['f'] is String ? decoded['f'] as String : null;
        final entry = DownloadItem(
          video: video,
          status: status,
          fileName: fileName,
          thumbName: decoded['i'] is String ? decoded['i'] as String : null,
          bytesTotal: decoded['b'] is int ? decoded['b'] as int : 0,
          error: decoded['e'] is String ? decoded['e'] as String : null,
          addedAt: DateTime.fromMillisecondsSinceEpoch(
            decoded['t'] is int ? decoded['t'] as int : 0,
          ),
        );

        if (status == DownloadStatus.done) {
          entry.bytes.value = entry.bytesTotal;
          if (localPathOf(entry) == null) continue;
        } else if (dir != null && fileName != null) {
          final part = File('${dir.path}/$fileName.part');
          entry.bytes.value = part.existsSync() ? part.lengthSync() : 0;
        }

        final thumb = entry.thumbName;
        if (thumb != null && dir != null && File('${dir.path}/$thumb').existsSync()) {
          _thumbs[video.id] = '${dir.path}/$thumb';
        } else {
          entry.thumbName = null;
        }
        _items.add(entry);
      } catch (_) {
      }
    }
    _items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _cleanOrphans();
    await _initDownloader();
  }

  Future<void> _initDownloader() async {
    try {
      final downloader = FileDownloader();
      await downloader.configure(
        globalConfig: <(String, dynamic)>[
          (Config.holdingQueue, (2, null, null)),
        ],
        androidConfig: <(String, dynamic)>[
          (Config.runInForeground, Config.always),
        ],
      );
      downloader.configureNotificationForGroup(
        FileDownloader.defaultGroup,
        running: const TaskNotification('Downloading {progress}', '{displayName}'),
        complete: const TaskNotification('Download complete', '{displayName}'),
        error: const TaskNotification('Download failed', '{displayName}'),
        paused: const TaskNotification('Download paused', '{displayName}'),
        progressBar: true,
      );
      downloader.registerCallbacks(
        taskStatusCallback: _onStatus,
        taskProgressCallback: _onProgress,
      );
      await downloader.trackTasks();

      for (final entry in List<DownloadItem>.of(_items)) {
        if (entry.status == DownloadStatus.done) continue;
        final record = await downloader.database.recordForId(_taskId(entry));
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
      _persist();
      notifyListeners();
    } catch (error) {
      debugPrint('[DOWNLOADS] Background downloader unavailable: $error');
    }
  }

  String _taskId(DownloadItem entry) {
    final safe = entry.video.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'dl_${safe.length > 80 ? safe.substring(0, 80) : safe}';
  }

  DownloadItem? _itemForTask(Task task) {
    final id = task.metaData;
    return id.isEmpty ? null : item(id);
  }

  void _markDone(DownloadItem entry) {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null || name == null) return;
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) {
      entry
        ..status = DownloadStatus.failed
        ..error = 'The downloaded file is missing. Tap resume.';
      return;
    }
    final size = file.lengthSync();
    entry
      ..status = DownloadStatus.done
      ..bytesTotal = size
      ..error = null;
    entry.bytes.value = size;
  }

  void _onStatus(TaskStatusUpdate update) {
    final entry = _itemForTask(update.task);
    if (entry == null) return;
    final id = entry.video.id;
    switch (update.status) {
      case TaskStatus.enqueued:
      case TaskStatus.running:
      case TaskStatus.waitingToRetry:
        if (entry.status != DownloadStatus.paused || !_pausing.contains(id)) {
          entry.status = DownloadStatus.downloading;
        }
      case TaskStatus.complete:
        _markDone(entry);
        if (entry.status == DownloadStatus.done) Haptics.play(Haptic.medium);
      case TaskStatus.paused:
        entry.status = DownloadStatus.paused;
        _pausing.remove(id);
      case TaskStatus.canceled:
        if (_cancelled.remove(id)) {
          _items.remove(entry);
          _thumbs.remove(id);
          _tasks.remove(id);
          unawaited(_deleteFiles(entry));
        } else if (_pausing.remove(id)) {
          entry.status = DownloadStatus.paused;
          entry.bytes.value = 0;
        } else {
          entry.status = DownloadStatus.paused;
        }
      case TaskStatus.notFound:
        entry
          ..status = DownloadStatus.failed
          ..error = 'The video file wasn\u2019t found on the server.';
      case TaskStatus.failed:
        final text = update.exception?.description ?? '';
        entry
          ..status = DownloadStatus.failed
          ..error = text.contains('Socket') || text.contains('timed out')
              ? 'Connection problem. Tap resume.'
              : 'Download failed. Tap resume.';
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
        .where((e) =>
            e.status == DownloadStatus.downloading ||
            e.status == DownloadStatus.queued)
        .toList();
    if (active.isEmpty) {
      if (_activityOn) {
        _activityOn = false;
        final anyDone = _items.any((e) => e.status == DownloadStatus.done);
        unawaited(NativeBridge.instance.endLiveActivity(
          title: _lastActiveTitle,
          finished: anyDone,
        ));
      }
      return;
    }
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastActivity) < const Duration(seconds: 1)) {
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
    unawaited(NativeBridge.instance.updateLiveActivity(
      title: current.video.title,
      progress: total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : -1,
      count: active.length,
    ));
  }

  void _onProgress(TaskProgressUpdate update) {
    final entry = _itemForTask(update.task);
    if (entry == null) return;
    if (update.progress < 0) return;
    final expected = update.expectedFileSize;
    if (expected > 0 && entry.bytesTotal != expected) {
      entry.bytesTotal = expected;
      notifyListeners();
    }
    final total = entry.bytesTotal;
    if (total > 0) entry.bytes.value = (update.progress * total).round();
    _syncActivity();
  }

  void _cleanOrphans() {
    final dir = _dir;
    if (dir == null) return;
    final owned = <String>{
      for (final entry in _items)
        if (entry.fileName != null) '${entry.fileName}.part',
    };
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.part') && !owned.contains(name)) {
          entity.deleteSync();
        }
      }
    } catch (_) {}
  }

  String? localPathOf(DownloadItem entry) {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null || name == null || entry.status != DownloadStatus.done) {
      return null;
    }
    final path = '${dir.path}/$name';
    return File(path).existsSync() ? path : null;
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

  void enqueueDirect(Video video, String url) {
    _directUrls[video.id] = url;
    enqueue(video);
  }

  void enqueue(Video video) {
    final existing = item(video.id);
    if (existing != null) {
      if (existing.status == DownloadStatus.failed ||
          existing.status == DownloadStatus.paused) {
        resume(video.id);
      }
      return;
    }
    _items.insert(0, DownloadItem(video: video.withoutStream()));
    _persist();
    notifyListeners();
    unawaited(_pump());
  }

  void resume(String id) {
    final entry = item(id);
    if (entry == null ||
        (entry.status != DownloadStatus.paused &&
            entry.status != DownloadStatus.failed)) {
      return;
    }
    final task = _tasks[id];
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
    final task = _tasks[id];
    if (entry.status == DownloadStatus.downloading && task != null) {
      _cancelled.add(id);
      await FileDownloader().cancelTaskWithId(task.taskId);
      return;
    }
    _tasks.remove(id);
    _items.remove(entry);
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

      final stored = entry.video.isReel ? entry.video.streamUrl.trim() : '';
      final direct = _directUrls[id] ?? (stored.isEmpty ? null : stored);
      final resolved = direct != null
          ? entry.video.copyWith(streamUrl: direct)
          : await videoRepository
              .resolveForPlayback(entry.video.copyWith(streamUrl: ''));

      final url = resolved.streamUrl.trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
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
              '[DOWNLOADS] Cookie lookup failed (${error.runtimeType}).');
        }
      }

      var finalUri = uri;
      try {
        finalUri = await resolveFinalStreamUri(uri, headers);
      } catch (_) {}

      entry.fileName ??= _newFileName(id);
      final fileName = entry.fileName!;
      final stale = File('${dir.path}/$fileName');
      if (stale.existsSync()) stale.deleteSync();

      unawaited(_saveThumbnail(entry, dir, pageUrl));

      await _ensureNotificationPermission();

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
    } on _DownloadFailure catch (failure) {
      entry
        ..status = DownloadStatus.failed
        ..error = failure.message;
    } catch (error) {
      debugPrint('[DOWNLOADS] $id failed to start: ${error.runtimeType}');
      entry
        ..status = DownloadStatus.failed
        ..error = error is TimeoutException || error is SocketException
            ? 'Connection problem. Tap resume.'
            : 'Download failed. Tap resume.';
    } finally {
      _persist();
      notifyListeners();
      _syncActivity(force: true);
    }
  }

  bool _askedForNotifications = false;

  Future<void> _ensureNotificationPermission() async {
    if (_askedForNotifications) return;
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
    final short = safe.length > 60 ? safe.substring(0, 60) : safe;
    return '${short}_${DateTime.now().millisecondsSinceEpoch}.mp4';
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
        uri.host.isEmpty) {
      return;
    }
    try {
      final base = streamHeaders(uri, pageUrl);
      final response = await http.get(uri, headers: <String, String>{
        'User-Agent': base['User-Agent'] ?? '',
        'Referer': base['Referer'] ?? '',
        'Accept': 'image/*,*/*;q=0.8',
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;
      final name = '${entry.fileName ?? _newFileName(id)}.thumb';
      await File('${dir.path}/$name').writeAsBytes(response.bodyBytes);
      entry.thumbName = name;
      _thumbs[id] = '${dir.path}/$name';
      _persist();
      notifyListeners();
    } catch (error) {
      debugPrint('[DOWNLOADS] Thumbnail not saved (${error.runtimeType}).');
    }
  }

  Future<void> _deleteFiles(DownloadItem entry) async {
    final dir = _dir;
    if (dir == null) return;
    for (final name in <String?>[
      entry.fileName,
      entry.fileName == null ? null : '${entry.fileName}.part',
      entry.thumbName,
    ]) {
      if (name == null) continue;
      try {
        final file = File('${dir.path}/$name');
        if (file.existsSync()) await file.delete();
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
