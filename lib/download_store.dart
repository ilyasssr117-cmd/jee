import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'models.dart';
import 'stream_headers.dart';
import 'touch.dart';
import 'video_json.dart';
import 'video_repository.dart';

enum DownloadStatus { queued, downloading, done, failed }

/// One saved (or saving) video.
class DownloadItem {
  DownloadItem({
    required this.video,
    this.status = DownloadStatus.queued,
    this.fileName,
    this.bytesTotal = 0,
    this.error,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  final Video video;
  DownloadStatus status;
  String? fileName;
  int bytesTotal;
  String? error;
  final DateTime addedAt;

  /// Bytes written so far. Own notifier, so a progress tick rebuilds only the
  /// small progress widgets and never whole lists.
  final ValueNotifier<int> bytes = ValueNotifier<int>(0);

  /// 0..1, or null while the total size is unknown.
  double? get progress => bytesTotal > 0
      ? (bytes.value / bytesTotal).clamp(0.0, 1.0).toDouble()
      : null;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _DownloadFailure implements Exception {
  const _DownloadFailure(this.message);

  final String message;
}

/// Saves videos (plain MP4 links) to the phone for offline watching.
///
/// Needs the `path_provider` package in pubspec.yaml.
/// The request carries the same headers + access cookie as the player (see
/// stream_headers.dart). One download runs at a time; the rest wait.
class DownloadStore extends ChangeNotifier {
  DownloadStore._();

  static final DownloadStore instance = DownloadStore._();

  static const String _key = 'downloads_v1';

  final List<DownloadItem> _items = <DownloadItem>[];
  late final UnmodifiableListView<DownloadItem> _view =
      UnmodifiableListView<DownloadItem>(_items);

  final Map<String, http.Client> _clients = <String, http.Client>{};
  final Set<String> _cancelled = <String>{};
  Directory? _dir;
  bool _running = false;

  /// Newest first.
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

  // -------------------------------------------------------------------------
  // Start-up
  // -------------------------------------------------------------------------

  /// Call once at start-up (after [LocalStore.init]).
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
    for (final raw in LocalStore.readList(_key)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) continue;
        final meta = decoded['v'];
        if (meta is! Map<String, dynamic>) continue;
        final video = videoFromJson(meta);
        if (video == null) continue;
        final index = decoded['s'];
        var status = index is int &&
                index >= 0 &&
                index < DownloadStatus.values.length
            ? DownloadStatus.values[index]
            : DownloadStatus.failed;
        String? error = decoded['e'] is String ? decoded['e'] as String : null;
        // The app was closed while it was saving: offer a retry.
        if (status == DownloadStatus.queued ||
            status == DownloadStatus.downloading) {
          status = DownloadStatus.failed;
          error = 'Interrupted. Tap retry.';
        }
        final entry = DownloadItem(
          video: video,
          status: status,
          fileName: decoded['f'] is String ? decoded['f'] as String : null,
          bytesTotal: decoded['b'] is int ? decoded['b'] as int : 0,
          error: error,
          addedAt: DateTime.fromMillisecondsSinceEpoch(
            decoded['t'] is int ? decoded['t'] as int : 0,
          ),
        );
        if (status == DownloadStatus.done) {
          entry.bytes.value = entry.bytesTotal;
          // The file vanished (storage cleaned by the system): forget it.
          if (localPathOf(entry) == null) continue;
        }
        _items.add(entry);
      } catch (_) {
        // Skip a corrupt entry.
      }
    }
    _items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _cleanPartials();
  }

  void _cleanPartials() {
    final dir = _dir;
    if (dir == null) return;
    try {
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.part')) entity.deleteSync();
      }
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

  String? localPathOf(DownloadItem entry) {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null || name == null || entry.status != DownloadStatus.done) {
      return null;
    }
    final path = '${dir.path}/$name';
    return File(path).existsSync() ? path : null;
  }

  /// Path of the saved file for [id], or null when it isn't downloaded.
  String? localPath(String id) {
    final entry = item(id);
    return entry == null ? null : localPathOf(entry);
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /// Adds [video] to the queue (does nothing when already saved / saving).
  void enqueue(Video video) {
    final existing = item(video.id);
    if (existing != null && existing.status != DownloadStatus.failed) return;
    if (existing != null) _items.remove(existing);
    _items.insert(
      0,
      DownloadItem(video: video.copyWith(streamUrl: '')),
    );
    notifyListeners();
    unawaited(_pump());
  }

  void retry(String id) {
    final entry = item(id);
    if (entry == null || entry.status != DownloadStatus.failed) return;
    enqueue(entry.video);
  }

  /// Stops a running / waiting download, or deletes a saved one.
  Future<void> remove(String id) async {
    final entry = item(id);
    if (entry == null) return;
    if (entry.status == DownloadStatus.downloading) {
      _cancelled.add(id);
      _clients[id]?.close();
      return; // _download() cleans up and removes the entry itself.
    }
    _items.remove(entry);
    _persist();
    notifyListeners();
    await _deleteFile(entry);
  }

  Future<void> removeAll() async {
    for (final entry in List<DownloadItem>.of(_items)) {
      await remove(entry.video.id);
    }
  }

  // -------------------------------------------------------------------------
  // Queue
  // -------------------------------------------------------------------------

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        DownloadItem? next;
        // Oldest waiting item first.
        for (final entry in _items.reversed) {
          if (entry.status == DownloadStatus.queued) {
            next = entry;
            break;
          }
        }
        if (next == null) break;
        await _download(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _download(DownloadItem entry) async {
    final id = entry.video.id;
    entry.status = DownloadStatus.downloading;
    entry.error = null;
    entry.bytes.value = 0;
    entry.bytesTotal = 0;
    notifyListeners();

    http.Client? client;
    IOSink? sink;
    File? part;
    var success = false;
    try {
      final dir = _dir;
      if (dir == null) {
        throw const _DownloadFailure('Storage isn\u2019t available.');
      }

      final resolved = await videoRepository
          .resolveForPlayback(entry.video.copyWith(streamUrl: ''));
      if (_cancelled.contains(id)) throw const _Cancelled();

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

      final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final fileName =
          '${safe.length > 60 ? safe.substring(0, 60) : safe}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      part = File('${dir.path}/$fileName.part');
      final target = File('${dir.path}/$fileName');

      client = http.Client();
      _clients[id] = client;
      // Same cookie + headers as the player (cookie comes from the repository).
      final pageUrl = resolved.pageUrl ?? entry.video.pageUrl;
      final pageUri = Uri.tryParse(pageUrl?.trim() ?? '');
      final validPage = pageUri != null &&
          (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
          pageUri.host.isNotEmpty;
      final headers = streamHeaders(uri, pageUrl);
      var cookie = '';
      try {
        cookie = await videoRepository.getPlaybackCookieHeader(
          streamUri: uri,
          pageUrl: validPage ? pageUri.toString() : null,
          userAgent: headers['User-Agent'] ?? '',
        );
      } catch (error) {
        debugPrint('[DOWNLOADS] Cookie lookup failed (${error.runtimeType}).');
      }
      if (_cancelled.contains(id)) throw const _Cancelled();
      final request = http.Request('GET', uri)
        ..headers.addAll(<String, String>{
          ...headers,
          if (cookie.isNotEmpty) 'Cookie': cookie,
        });
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw _DownloadFailure(
          'The server refused the download (${response.statusCode}).',
        );
      }
      final type = (response.headers['content-type'] ?? '').toLowerCase();
      if (type.contains('mpegurl') || type.contains('text/html')) {
        throw const _DownloadFailure('This video can\u2019t be downloaded.');
      }

      entry.bytesTotal = response.contentLength ?? 0;
      notifyListeners(); // The total size is known now.

      sink = part.openWrite();
      var written = 0;
      var lastTick = DateTime.now();
      await for (final chunk in response.stream) {
        if (_cancelled.contains(id)) throw const _Cancelled();
        sink.add(chunk);
        written += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastTick) > const Duration(milliseconds: 200)) {
          lastTick = now;
          entry.bytes.value = written;
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      entry.bytes.value = written;
      if (written <= 0) {
        throw const _DownloadFailure('The server sent an empty file.');
      }

      if (target.existsSync()) target.deleteSync();
      await part.rename(target.path);
      entry
        ..status = DownloadStatus.done
        ..fileName = fileName
        ..bytesTotal = written
        ..error = null;
      success = true;
      Haptics.play(Haptic.medium);
    } on _Cancelled {
      _items.remove(entry);
    } on _DownloadFailure catch (failure) {
      entry
        ..status = DownloadStatus.failed
        ..error = failure.message;
    } catch (error) {
      debugPrint('[DOWNLOADS] $id failed: $error');
      if (_cancelled.contains(id)) {
        _items.remove(entry);
      } else {
        entry
          ..status = DownloadStatus.failed
          ..error = error is TimeoutException || error is SocketException
              ? 'Connection problem. Tap retry.'
              : 'Download failed. Tap retry.';
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close();
      _clients.remove(id);
      _cancelled.remove(id);
      if (!success && part != null) {
        try {
          if (part.existsSync()) part.deleteSync();
        } catch (_) {}
      }
      _persist();
      notifyListeners();
    }
  }

  Future<void> _deleteFile(DownloadItem entry) async {
    final dir = _dir;
    final name = entry.fileName;
    if (dir == null || name == null) return;
    try {
      final file = File('${dir.path}/$name');
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  void _persist() => LocalStore.writeList(
        _key,
        _items
            .map(
              (entry) => jsonEncode(<String, dynamic>{
                'v': videoToJson(entry.video),
                's': entry.status.index,
                'f': entry.fileName,
                'b': entry.bytesTotal,
                'e': entry.error,
                't': entry.addedAt.millisecondsSinceEpoch,
              }),
            )
            .toList(),
      );
}
