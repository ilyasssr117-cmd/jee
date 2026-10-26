import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'local_store.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'stream_headers.dart';
import 'touch.dart';
import 'video_json.dart';
import 'video_repository.dart';

/// New values are only ever added at the END (the index is saved to disk).
enum DownloadStatus { queued, downloading, done, failed, paused }

/// One saved (or saving) video.
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

  /// Bytes written so far. Own notifier, so a progress tick rebuilds only the
  /// small progress widgets and never whole lists.
  final ValueNotifier<int> bytes = ValueNotifier<int>(0);

  /// 0..1, or null while the total size is unknown.
  double? get progress => bytesTotal > 0
      ? (bytes.value / bytesTotal).clamp(0.0, 1.0).toDouble()
      : null;

  /// Part of the file is already on the phone (a resume continues from it).
  bool get hasPartial => status != DownloadStatus.done && bytes.value > 0;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Paused implements Exception {
  const _Paused();
}

class _DownloadFailure implements Exception {
  const _DownloadFailure(this.message);

  final String message;
}

/// Saves videos (plain MP4 links) to the phone for offline watching.
///
/// * Needs the `path_provider` package in pubspec.yaml.
/// * The request carries the same headers + cookie as the player (the cookie
///   comes from `videoRepository.getPlaybackCookieHeader`, untouched).
/// * RESUME: the half-downloaded file is kept and continues with a Range
///   request, also automatically when the server drops the connection.
/// * The thumbnail is saved next to the video, so lists look right offline.
class DownloadStore extends ChangeNotifier {
  DownloadStore._();

  static final DownloadStore instance = DownloadStore._();

  static const String _key = 'downloads_v1';

  /// Silent reconnects without progress before giving up.
  static const int _maxStalledAttempts = 5;

  final List<DownloadItem> _items = <DownloadItem>[];
  late final UnmodifiableListView<DownloadItem> _view =
      UnmodifiableListView<DownloadItem>(_items);

  final Map<String, http.Client> _clients = <String, http.Client>{};
  final Set<String> _cancelled = <String>{};
  final Set<String> _paused = <String>{};
  final Map<String, String> _thumbs = <String, String>{};
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
        // The app was closed while it was saving: keep the part, offer resume.
        if (status == DownloadStatus.queued ||
            status == DownloadStatus.downloading) {
          status = DownloadStatus.paused;
        }
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
          // The file vanished (storage cleaned by the system): forget it.
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
        // Skip a corrupt entry.
      }
    }
    _items.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    _cleanOrphans();
  }

  /// Deletes `.part` files that no list entry owns any more.
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

  /// Path of the saved thumbnail for [id] (a plain map lookup, safe in build).
  String? thumbPath(String id) => _thumbs[id];

  /// Opens the iOS share sheet: "Save Video" (Photos) or "Save to Files".
  Future<bool> shareFile(String id) async {
    final path = localPath(id);
    if (path == null) return false;
    return NativeBridge.instance.shareFile(path);
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /// Adds [video] to the queue (does nothing when already saved / saving).
  void enqueue(Video video) {
    final existing = item(video.id);
    if (existing != null) {
      if (existing.status == DownloadStatus.failed ||
          existing.status == DownloadStatus.paused) {
        resume(video.id);
      }
      return;
    }
    _items.insert(0, DownloadItem(video: video.copyWith(streamUrl: '')));
    _persist();
    notifyListeners();
    unawaited(_pump());
  }

  /// Continues a paused / failed download from where it stopped.
  void resume(String id) {
    final entry = item(id);
    if (entry == null ||
        (entry.status != DownloadStatus.paused &&
            entry.status != DownloadStatus.failed)) {
      return;
    }
    _paused.remove(id);
    entry
      ..status = DownloadStatus.queued
      ..error = null;
    notifyListeners();
    unawaited(_pump());
  }

  /// Stops a running download but keeps what is already saved.
  void pause(String id) {
    final entry = item(id);
    if (entry == null) return;
    if (entry.status == DownloadStatus.downloading) {
      _paused.add(id);
      _clients[id]?.close(); // _download() ends in the paused state.
    } else if (entry.status == DownloadStatus.queued) {
      entry.status = DownloadStatus.paused;
      _persist();
      notifyListeners();
    }
  }

  /// Cancels a download (partial data is deleted) or deletes a saved video.
  Future<void> remove(String id) async {
    final entry = item(id);
    if (entry == null) return;
    if (entry.status == DownloadStatus.downloading) {
      _cancelled.add(id);
      _clients[id]?.close();
      return; // _download() cleans up and removes the entry itself.
    }
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
    notifyListeners();

    http.Client? client;
    IOSink? sink;
    File? partRef;
    var finished = false;
    try {
      final dir = _dir;
      if (dir == null) {
        throw const _DownloadFailure('Storage isn\u2019t available.');
      }

      final resolved = await videoRepository
          .resolveForPlayback(entry.video.copyWith(streamUrl: ''));
      _checkStop(id);

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

      // The same file name is kept across pauses so a resume finds its part.
      entry.fileName ??= _newFileName(id);
      final fileName = entry.fileName!;
      final part = File('${dir.path}/$fileName.part');
      final target = File('${dir.path}/$fileName');
      partRef = part;

      // Thumbnail first (small): lists keep working offline.
      unawaited(_saveThumbnail(entry, dir, resolved.pageUrl ?? entry.video.pageUrl));

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
      _checkStop(id);

      client = http.Client();
      _clients[id] = client;

      var stalled = 0;
      var total = 0;
      while (true) {
        _checkStop(id);
        var offset = part.existsSync() ? part.lengthSync() : 0;
        final startedAt = offset;
        entry.bytes.value = offset;

        debugPrint(
          '[DOWNLOADS] GET host=${uri.host} from=$offset '
          'cookie=${cookie.isNotEmpty ? 'yes' : 'NO'}',
        );
        final response = await _open(client, uri, <String, String>{
          ...headers,
          'Range': 'bytes=$offset-',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        });
        debugPrint(
          '[DOWNLOADS] status=${response.statusCode} '
          'type=${response.headers['content-type']} '
          'length=${response.contentLength}',
        );

        if (response.statusCode == 416) {
          // The saved part doesn't match the server's file: start again.
          await response.stream.drain<void>().timeout(
                const Duration(seconds: 3),
                onTimeout: () {},
              );
          if (part.existsSync()) part.deleteSync();
          stalled++;
          if (stalled > _maxStalledAttempts) {
            throw const _DownloadFailure('Please try the download again.');
          }
          continue;
        }
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw _DownloadFailure(
            'The server refused the download (${response.statusCode}'
            '${cookie.isEmpty ? ', no cookie' : ''}).',
          );
        }
        final type = (response.headers['content-type'] ?? '').toLowerCase();
        if (type.contains('mpegurl') || type.contains('text/html')) {
          throw const _DownloadFailure('This video can\u2019t be downloaded.');
        }

        // 200 while we asked for a part: the server ignored Range. Restart.
        var append = offset > 0;
        if (response.statusCode == 200 && offset > 0) {
          offset = 0;
          append = false;
        }
        total = _totalSize(response, offset);
        if (total > 0 && entry.bytesTotal != total) {
          entry.bytesTotal = total;
          notifyListeners(); // The total size is known now.
        }

        final output = part.openWrite(
          mode: append ? FileMode.append : FileMode.write,
        );
        sink = output;
        var written = offset;
        var lastTick = DateTime.now();
        try {
          await for (final chunk in response.stream) {
            _checkStop(id);
            output.add(chunk);
            written += chunk.length;
            final now = DateTime.now();
            if (now.difference(lastTick) > const Duration(milliseconds: 200)) {
              lastTick = now;
              entry.bytes.value = written;
            }
          }
        } finally {
          // Whatever happened, what arrived is on disk and a resume uses it.
          await output.flush();
          await output.close();
          sink = null;
          entry.bytes.value = written;
        }

        if (total > 0 && written < total) {
          // The server closed early (speed limit / bad connection): carry on
          // from where it stopped, without bothering the viewer.
          stalled = written > startedAt ? 0 : stalled + 1;
          if (stalled > _maxStalledAttempts) {
            throw const _DownloadFailure('Connection lost. Tap resume.');
          }
          continue;
        }
        break;
      }

      if (entry.bytes.value <= 0) {
        throw const _DownloadFailure('The server sent an empty file.');
      }
      if (target.existsSync()) target.deleteSync();
      await part.rename(target.path);
      entry
        ..status = DownloadStatus.done
        ..bytesTotal = entry.bytes.value
        ..error = null;
      finished = true;
      Haptics.play(Haptic.medium);
    } on _Cancelled {
      _items.remove(entry);
      _thumbs.remove(id);
      await _deleteFiles(entry);
    } on _Paused {
      entry.status = DownloadStatus.paused;
    } on _DownloadFailure catch (failure) {
      entry
        ..status = DownloadStatus.failed
        ..error = failure.message;
    } catch (error) {
      debugPrint('[DOWNLOADS] $id failed: ${error.runtimeType}');
      if (_cancelled.contains(id)) {
        _items.remove(entry);
        _thumbs.remove(id);
        await _deleteFiles(entry);
      } else if (_paused.contains(id)) {
        entry.status = DownloadStatus.paused;
      } else {
        entry
          ..status = DownloadStatus.failed
          ..error = error is TimeoutException || error is SocketException
              ? 'Connection problem. Tap resume.'
              : 'Download failed. Tap resume.';
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client?.close();
      _clients.remove(id);
      _cancelled.remove(id);
      _paused.remove(id);
      if (!finished && partRef != null && entry.status == DownloadStatus.paused) {
        // Keep the part: remember how much there is.
        try {
          entry.bytes.value = partRef.existsSync() ? partRef.lengthSync() : 0;
        } catch (_) {}
      }
      _persist();
      notifyListeners();
    }
  }

  /// Throws when the viewer paused or cancelled this download.
  void _checkStop(String id) {
    if (_cancelled.contains(id)) throw const _Cancelled();
    if (_paused.contains(id)) throw const _Paused();
  }

  /// Follows redirects by hand so the cookie and headers survive a hop to
  /// another host (the HTTP client would drop them).
  Future<http.StreamedResponse> _open(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    var current = uri;
    for (var hop = 0; hop < 6; hop++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      final location = response.headers['location'];
      if (response.isRedirect && location != null && location.isNotEmpty) {
        await response.stream.drain<void>();
        current = current.resolve(location);
        continue;
      }
      return response;
    }
    throw const _DownloadFailure('Too many redirects.');
  }

  /// Full file size from Content-Range / Content-Length (0 when unknown).
  int _totalSize(http.StreamedResponse response, int offset) {
    final range = response.headers['content-range'];
    if (range != null) {
      final slash = range.lastIndexOf('/');
      if (slash >= 0) {
        final total = int.tryParse(range.substring(slash + 1).trim());
        if (total != null) return total;
      }
    }
    final length = response.contentLength;
    if (length == null || length <= 0) return 0;
    return response.statusCode == 206 ? offset + length : length;
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
