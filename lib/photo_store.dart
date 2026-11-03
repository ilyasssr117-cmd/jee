import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'media_headers.dart';
import 'local_store.dart';
import 'models.dart';

bool _isSafePhotoLeaf(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.contains('..') &&
    !value.contains('/') &&
    !value.contains('\\') &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$').hasMatch(value);

class SavedPhoto {
  const SavedPhoto({required this.id, required this.file});

  final String id;

  final String file;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'file': file};

  static SavedPhoto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final file = raw['file'];
    if (id is! String ||
        file is! String ||
        id.length > 512 ||
        !_isSafePhotoLeaf(file)) {
      return null;
    }
    return SavedPhoto(id: id, file: file);
  }
}

class SavedAlbum {
  /// Maximum number of photo records retained for one saved album.
  /// Keep this above the UI's supported large-album size so metadata survives
  /// app restarts instead of silently truncating at the first 200 entries.
  static const int maxPhotosPerAlbum = 5000;

  SavedAlbum({
    required this.id,
    required this.title,
    required this.url,
    required this.dir,
    this.modelName,
    List<SavedPhoto>? photos,
    DateTime? savedAt,
  }) : photos = photos ?? <SavedPhoto>[],
       savedAt = savedAt ?? DateTime.now();

  final String id;
  final String title;
  final String url;

  final String dir;
  final String? modelName;
  final List<SavedPhoto> photos;
  final DateTime savedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'url': url,
    'dir': dir,
    'model': modelName,
    'savedAt': savedAt.millisecondsSinceEpoch,
    'photos': <Object?>[for (final p in photos) p.toJson()],
  };

  static SavedAlbum? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    final url = raw['url'];
    final dir = raw['dir'];
    if (id is! String ||
        title is! String ||
        url is! String ||
        dir is! String ||
        id.isEmpty ||
        id.length > 512 ||
        title.length > 1000 ||
        url.length > 4096 ||
        !_isSafePhotoLeaf(dir)) {
      return null;
    }
    final albumUri = Uri.tryParse(url);
    if (albumUri == null ||
        (albumUri.scheme != 'http' && albumUri.scheme != 'https') ||
        albumUri.host.isEmpty ||
        albumUri.userInfo.isNotEmpty) {
      return null;
    }
    final photos = <SavedPhoto>[];
    final list = raw['photos'];
    if (list is List) {
      for (final entry in list.take(maxPhotosPerAlbum)) {
        final photo = SavedPhoto.fromJson(entry);
        if (photo != null) photos.add(photo);
      }
    }
    final millis = raw['savedAt'];
    return SavedAlbum(
      id: id,
      title: title,
      url: url,
      dir: dir,
      modelName: raw['model'] is String
          ? (raw['model'] as String).substring(
              0,
              (raw['model'] as String).length.clamp(0, 256).toInt(),
            )
          : null,
      photos: photos,
      savedAt: millis is int
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : DateTime.now(),
    );
  }
}

class _PhotoSaveCancelled implements Exception {
  const _PhotoSaveCancelled();
}

class PhotoJob {
  PhotoJob(this.total);

  final int total;
  int done = 0;
  int failed = 0;
  bool cancelled = false;
}

class PhotoStore extends ChangeNotifier {
  PhotoStore._();

  @visibleForTesting
  PhotoStore.forTesting({required Directory root, http.Client? client})
    : _root = root,
      _client = client;

  static final PhotoStore instance = PhotoStore._();

  static const String _key = 'photo_albums_v1';
  static const int _parallel = 2;
  static const int _maxGlobalParallel = 4;
  static const int _maxPhotosPerAlbum = SavedAlbum.maxPhotosPerAlbum;
  static const int _maxSavedAlbums = 40;
  // High-resolution originals can exceed 8 MB. These limits remain bounded,
  // but no longer make ordinary 1,000-photo albums fail around image 100.
  static const int _maxPhotoBytes = 40 * 1024 * 1024;
  static const int _maxAlbumBytes = 3 * 1024 * 1024 * 1024;
  int _activeTransfers = 0;
  final Queue<Completer<void>> _transferWaiters = Queue<Completer<void>>();

  Directory? _root;
  http.Client? _client;
  final List<SavedAlbum> _albums = <SavedAlbum>[];
  final Map<String, PhotoJob> _jobs = <String, PhotoJob>{};
  final Map<String, Completer<void>> _jobCompletions =
      <String, Completer<void>>{};

  List<SavedAlbum> get albums => List<SavedAlbum>.unmodifiable(_albums);

  int get totalPhotos =>
      _albums.fold<int>(0, (sum, album) => sum + album.photos.length);

  Future<void> init() async {
    if (_root == null) {
      try {
        final documents = await getApplicationDocumentsDirectory();
        _root = Directory('${documents.path}/photos');
      } catch (error) {
        debugPrint('[PHOTOS] Storage unavailable: ${error.runtimeType}');
      }
    }
    final root = _root;
    if (root != null && !await root.exists()) {
      await root.create(recursive: true);
    }
    load();
    unawaited(_purgeStalePhotoTemps());
  }

  void load() {
    _albums.clear();
    final raw = LocalStore.readString(_key);
    if (raw != null && raw.isNotEmpty && raw.length <= 4 * 1024 * 1024) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded.take(100)) {
            final album = SavedAlbum.fromJson(entry);
            if (album == null) continue;
            album.photos.removeWhere((p) => !_fileOf(album, p).existsSync());
            if (album.photos.isNotEmpty) _albums.add(album);
          }
        }
      } catch (error) {
        debugPrint('[PHOTOS] Saved list unreadable: ${error.runtimeType}');
      }
    }
    _albums.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    // Older installations may already contain more than the current save
    // limit. Preserve those albums; the limit only blocks creation of new ones.
    notifyListeners();
  }

  Future<void> _purgeStalePhotoTemps() async {
    final root = _root;
    if (root == null) return;
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    for (final album in _albums) {
      final dir = Directory('${root.path}/${album.dir}');
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (!name.startsWith('.') || !name.endsWith('.pending')) continue;
          if ((await entity.lastModified()).isBefore(cutoff)) {
            await entity.delete();
          }
        }
      } catch (_) {}
    }
  }

  void _persist() => LocalStore.writeString(
    _key,
    jsonEncode(<Object?>[for (final a in _albums) a.toJson()]),
  );

  SavedAlbum? album(String id) {
    for (final album in _albums) {
      if (album.id == id) return album;
    }
    return null;
  }

  bool isSaved(String albumId, String photoId) {
    final saved = album(albumId);
    return saved != null && saved.photos.any((p) => p.id == photoId);
  }

  int savedCount(String albumId, Iterable<AlbumPhoto> photos) =>
      photos.where((p) => isSaved(albumId, p.id)).length;

  PhotoJob? jobFor(String albumId) => _jobs[albumId];

  File fileOf(SavedAlbum album, SavedPhoto photo) => _fileOf(album, photo);

  File _fileOf(SavedAlbum album, SavedPhoto photo) {
    if (!_isSafePhotoLeaf(album.dir) || !_isSafePhotoLeaf(photo.file)) {
      throw const FormatException('Unsafe local photo path.');
    }
    return File('${_root?.path ?? ''}/${album.dir}/${photo.file}');
  }

  Future<int> savePhotos(
    AlbumRef album,
    List<AlbumPhoto> photos, {
    String? modelName,
    Map<String, String>? headers,
  }) async {
    final root = _root;
    final albumUri = Uri.tryParse(album.url);
    if (root == null ||
        _jobs.containsKey(album.id) ||
        album.id.isEmpty ||
        album.id.length > 512 ||
        album.url.length > 4096 ||
        album.title.length > 1000 ||
        albumUri == null ||
        (albumUri.scheme != 'http' && albumUri.scheme != 'https') ||
        albumUri.host.isEmpty ||
        albumUri.userInfo.isNotEmpty) {
      return 0;
    }

    final seenPhotoIds = <String>{};
    final alreadySaved = this.album(album.id)?.photos.length ?? 0;
    final remainingSlots = math
        .max(0, _maxPhotosPerAlbum - alreadySaved)
        .toInt();
    final todo = photos
        .where((p) => seenPhotoIds.add(p.id) && !isSaved(album.id, p.id))
        .take(remainingSlots)
        .toList();
    if (todo.isEmpty) return 0;

    var saved = this.album(album.id);
    final isNew = saved == null;
    saved ??= SavedAlbum(
      id: album.id,
      title: album.title.substring(0, math.min(album.title.length, 300)),
      url: album.url,
      dir: '${_safeName(album.id, fallback: 'album')}_${_stableHash(album.id)}',
      modelName: modelName?.substring(0, math.min(modelName.length, 256)),
    );
    final dir = Directory('${root.path}/${saved.dir}');
    await dir.create(recursive: true);
    var reservedBytes = await _directoryBytes(dir);
    if (reservedBytes >= _maxAlbumBytes) {
      if (isNew) await _deleteDir(dir);
      return 0;
    }

    // Re-check after the asynchronous directory scan so two taps for the same
    // album cannot start duplicate jobs or race the album-count limit.
    if (_jobs.containsKey(album.id)) return 0;
    final existingAfterScan = this.album(album.id);
    if (existingAfterScan != null) {
      saved = existingAfterScan;
    } else if (!isNew) {
      // The album was removed while the directory scan was in flight.
      await _deleteDir(dir);
      return 0;
    } else {
      // Keep a hard storage bound, but never silently delete a user's older
      // saved albums to make room for a new one.
      if (_albums.length >= _maxSavedAlbums) {
        await _deleteDir(dir);
        return 0;
      }
      _albums.insert(0, saved);
    }

    final job = PhotoJob(todo.length);
    final completion = Completer<void>();
    _jobs[album.id] = job;
    _jobCompletions[album.id] = completion;
    notifyListeners();

    final requestHeaders = headers ?? _defaultHeaders(album.url);
    var next = 0;
    var ok = 0;

    Future<void> worker() async {
      while (!job.cancelled) {
        final index = next++;
        if (index >= todo.length) return;
        final photo = todo[index];
        await _acquireTransfer();
        try {
          if (job.cancelled) return;
          final remaining = _maxAlbumBytes - reservedBytes;
          if (remaining <= 0) {
            job.failed++;
            return;
          }
          final byteBudget = math.min(_maxPhotoBytes, remaining).toInt();
          reservedBytes += byteBudget;
          var heldReservation = byteBudget;
          try {
            final name = await _download(
              photo,
              dir,
              requestHeaders,
              maxBytes: byteBudget,
              isCancelled: () => job.cancelled,
            );
            final savedFile = File('${dir.path}/$name');
            final actualBytes = await savedFile.length();
            reservedBytes -= heldReservation;
            heldReservation = actualBytes;
            reservedBytes += heldReservation;
            if (job.cancelled) {
              if (await savedFile.exists()) await savedFile.delete();
              reservedBytes -= heldReservation;
              heldReservation = 0;
              return;
            }
            saved!.photos.add(SavedPhoto(id: photo.id, file: name));
            ok++;
          } catch (_) {
            reservedBytes -= heldReservation;
            rethrow;
          }
        } catch (error) {
          if (!job.cancelled && error is! _PhotoSaveCancelled) {
            job.failed++;
            debugPrint('[PHOTOS] Image save failed (${error.runtimeType}).');
          }
        } finally {
          _releaseTransfer();
          job.done++;
          notifyListeners();
        }
      }
    }

    try {
      await Future.wait<void>([for (var i = 0; i < _parallel; i++) worker()]);
    } finally {
      if (identical(_jobs[album.id], job)) _jobs.remove(album.id);
      saved.photos.sort((a, b) => _compareIds(a.id, b.id));
      if (saved.photos.isEmpty) {
        _albums.remove(saved);
        await _deleteDir(dir);
      }
      _persist();
      notifyListeners();
      if (identical(_jobCompletions[album.id], completion)) {
        _jobCompletions.remove(album.id);
      }
      if (!completion.isCompleted) completion.complete();
    }
    return ok;
  }

  void cancel(String albumId) => _jobs[albumId]?.cancelled = true;

  Future<void> _acquireTransfer() async {
    if (_activeTransfers < _maxGlobalParallel) {
      _activeTransfers++;
      return;
    }
    final waiter = Completer<void>();
    _transferWaiters.addLast(waiter);
    await waiter.future;
  }

  void _releaseTransfer() {
    if (_transferWaiters.isNotEmpty) {
      _transferWaiters.removeFirst().complete();
      return;
    }
    if (_activeTransfers > 0) _activeTransfers--;
  }

  Future<String> _download(
    AlbumPhoto photo,
    Directory dir,
    Map<String, String> headers, {
    required int maxBytes,
    required bool Function() isCancelled,
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _downloadOnce(
          photo,
          dir,
          headers,
          maxBytes: maxBytes,
          isCancelled: isCancelled,
        );
      } on _PhotoSaveCancelled {
        rethrow;
      } on FormatException {
        rethrow;
      } on HttpException catch (error) {
        final match = RegExp(r'HTTP (\d{3})').firstMatch(error.message);
        final status = int.tryParse(match?.group(1) ?? '');
        final retryable =
            status == 408 ||
            status == 425 ||
            status == 429 ||
            (status != null && status >= 500 && status <= 599);
        if (!retryable || attempt == 2) rethrow;
      } on SocketException {
        if (attempt == 2) rethrow;
      } on HandshakeException {
        if (attempt == 2) rethrow;
      } on http.ClientException {
        if (attempt == 2) rethrow;
      } on TimeoutException {
        if (attempt == 2) rethrow;
      }
      if (isCancelled()) throw const _PhotoSaveCancelled();
      await Future<void>.delayed(Duration(milliseconds: 450 * (attempt + 1)));
    }
    throw const HttpException('Image download failed.');
  }

  Future<http.StreamedResponse> _sendImageRequest(
    Uri initialUri,
    Map<String, String> headers,
  ) async {
    var current = initialUri;
    var requestHeaders = <String, String>{...headers};
    const redirectCodes = <int>{301, 302, 303, 307, 308};

    for (var hop = 0; hop <= 5; hop++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(requestHeaders);
      final response = await (_client ??= http.Client())
          .send(request)
          .timeout(const Duration(seconds: 40));
      final location = response.headers['location'];
      if (!redirectCodes.contains(response.statusCode) ||
          location == null ||
          location.isEmpty) {
        return response;
      }
      await response.stream.drain<void>().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      if (hop == 5) {
        throw const HttpException('Too many image redirects.');
      }
      final next = current.resolve(location);
      if ((next.scheme != 'http' && next.scheme != 'https') ||
          (current.scheme == 'https' && next.scheme != 'https') ||
          next.host.isEmpty ||
          next.userInfo.isNotEmpty ||
          next.toString().length > 8192) {
        throw const FormatException('Unsafe image redirect.');
      }
      if (next.origin != current.origin) {
        requestHeaders = <String, String>{
          for (final entry in requestHeaders.entries)
            if (!const <String>{
              'cookie',
              'authorization',
              'proxy-authorization',
              'referer',
            }.contains(entry.key.toLowerCase()))
              entry.key: entry.value,
        };
      }
      current = next;
    }
    throw const HttpException('Too many image redirects.');
  }

  Future<String> _downloadOnce(
    AlbumPhoto photo,
    Directory dir,
    Map<String, String> headers, {
    required int maxBytes,
    required bool Function() isCancelled,
  }) async {
    final uri = Uri.tryParse(photo.fullUrl);
    if (uri == null ||
        photo.fullUrl.length > 8192 ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid image URL.');
    }

    final response = await _sendImageRequest(uri, headers);
    if (response.statusCode != 200) {
      await response.stream.drain<void>().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      throw HttpException('HTTP ${response.statusCode}');
    }
    if (response.contentLength != null && response.contentLength! > maxBytes) {
      await response.stream.drain<void>().timeout(
        const Duration(seconds: 3),
        onTimeout: () {},
      );
      throw const FormatException('Image is too large.');
    }

    final nameBase =
        '${_safeName(photo.id, fallback: 'photo')}_${_stableHash(photo.id)}';
    final name = '$nameBase.pending';
    final temp = File('${dir.path}/.$name');
    if (await temp.exists()) await temp.delete();
    final sink = temp.openWrite();
    final prefix = <int>[];
    var total = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 35),
      )) {
        if (isCancelled()) throw const _PhotoSaveCancelled();
        total += chunk.length;
        if (total > maxBytes) {
          throw const FormatException('Image is too large.');
        }
        if (prefix.length < 12) {
          prefix.addAll(chunk.take(12 - prefix.length));
        }
        sink.add(chunk);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
    await sink.close();
    if (isCancelled()) {
      if (await temp.exists()) await temp.delete();
      throw const _PhotoSaveCancelled();
    }

    final extension = _imageExtension(prefix);
    if (extension == null || total == 0) {
      if (await temp.exists()) await temp.delete();
      throw const FormatException('Not a valid image.');
    }

    final finalName = '$nameBase.$extension';
    final target = File('${dir.path}/$finalName');
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    return finalName;
  }

  Map<String, String> _defaultHeaders(String albumUrl) =>
      imageHeadersFor(albumUrl) ??
      const <String, String>{
        'User-Agent': kBrowserUserAgent,
        'Accept': 'image/*,*/*;q=0.8',
      };

  Future<void> removePhoto(String albumId, String photoId) async {
    // Avoid an in-flight save recreating a photo after the user removes it.
    if (_jobs.containsKey(albumId)) {
      cancel(albumId);
      final completion = _jobCompletions[albumId];
      if (completion != null) await completion.future;
    }
    final saved = album(albumId);
    if (saved == null) return;
    final photo = saved.photos.where((p) => p.id == photoId).firstOrNull;
    if (photo == null) return;
    try {
      final file = _fileOf(saved, photo);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    saved.photos.remove(photo);
    if (saved.photos.isEmpty) {
      _albums.remove(saved);
      unawaited(_deleteDir(Directory('${_root?.path ?? ''}/${saved.dir}')));
    }
    _persist();
    notifyListeners();
  }

  Future<void> removeAlbum(String albumId) async {
    cancel(albumId);
    // Wait for in-flight file writes before deleting the album directory.
    // This prevents a cancelled download from recreating files after removal.
    final completion = _jobCompletions[albumId];
    if (completion != null) await completion.future;
    final saved = album(albumId);
    if (saved == null) return;
    _albums.remove(saved);
    await _deleteDir(Directory('${_root?.path ?? ''}/${saved.dir}'));
    _persist();
    notifyListeners();
  }

  Future<void> _deleteDir(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<int> _directoryBytes(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          total += await entity.length();
          if (total >= _maxAlbumBytes) return total;
        }
      }
    } catch (_) {}
    return total;
  }

  static String? _imageExtension(List<int> b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'png';
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'webp';
    }
    return null;
  }

  static String _safeName(String value, {required String fallback}) {
    var name = value.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}/?$'), '');
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    name = name.replaceAll(RegExp(r'^_+|_+$'), '');
    if (name.length > 90) name = name.substring(name.length - 90);
    return name.isEmpty ? fallback : name;
  }

  static String _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static int _compareIds(String a, String b) {
    final na = _trailingNumber(a);
    final nb = _trailingNumber(b);
    if (na != null && nb != null && na != nb) return na.compareTo(nb);
    return a.compareTo(b);
  }

  static int? _trailingNumber(String id) {
    final match = RegExp(r'(\d+)\.[A-Za-z0-9]+/?$').firstMatch(id);
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}
