import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'image_headers.dart';
import 'local_store.dart';
import 'models.dart';

/// One picture saved on the phone.
class SavedPhoto {
  const SavedPhoto({required this.id, required this.file});

  /// Same id as [AlbumPhoto.id] (the file part of the site's address).
  final String id;

  /// File name inside the album's folder.
  final String file;

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'file': file};

  static SavedPhoto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final file = raw['file'];
    if (id is! String || file is! String || file.contains('/')) return null;
    return SavedPhoto(id: id, file: file);
  }
}

/// A photo album saved on the phone (shown in Library > Albums).
class SavedAlbum {
  SavedAlbum({
    required this.id,
    required this.title,
    required this.url,
    required this.dir,
    this.modelName,
    List<SavedPhoto>? photos,
    DateTime? savedAt,
  })  : photos = photos ?? <SavedPhoto>[],
        savedAt = savedAt ?? DateTime.now();

  final String id;
  final String title;
  final String url;

  /// Folder name inside the photos folder.
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
    if (id is! String || title is! String || url is! String || dir is! String) {
      return null;
    }
    if (dir.isEmpty || dir.contains('/') || dir.contains('..')) return null;
    final photos = <SavedPhoto>[];
    final list = raw['photos'];
    if (list is List) {
      for (final entry in list) {
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
      modelName: raw['model'] as String?,
      photos: photos,
      savedAt: millis is int
          ? DateTime.fromMillisecondsSinceEpoch(millis)
          : DateTime.now(),
    );
  }
}

/// Progress of the photos being saved for one album.
class PhotoJob {
  PhotoJob(this.total);

  final int total;
  int done = 0;
  int failed = 0;
  bool cancelled = false;
}

/// Saves album pictures on the phone (documents/photos/<album>/...) and keeps
/// the list of saved albums.
///
/// From there the pictures can be opened offline in Library > Albums or sent
/// to the Photos app with the iOS share sheet.
class PhotoStore extends ChangeNotifier {
  PhotoStore._();

  /// For tests: a folder and an HTTP client of your own.
  @visibleForTesting
  PhotoStore.forTesting({required Directory root, http.Client? client})
      : _root = root,
        _client = client;

  static final PhotoStore instance = PhotoStore._();

  static const String _key = 'photo_albums_v1';
  static const int _parallel = 3;

  Directory? _root;
  http.Client? _client;
  final List<SavedAlbum> _albums = <SavedAlbum>[];
  final Map<String, PhotoJob> _jobs = <String, PhotoJob>{};

  /// Newest first.
  List<SavedAlbum> get albums => List<SavedAlbum>.unmodifiable(_albums);

  int get totalPhotos =>
      _albums.fold<int>(0, (sum, album) => sum + album.photos.length);

  // -------------------------------------------------------------------------
  // Start-up
  // -------------------------------------------------------------------------

  /// Call once at start-up (after [LocalStore.init]).
  Future<void> init() async {
    if (_root == null) {
      try {
        final documents = await getApplicationDocumentsDirectory();
        _root = Directory('${documents.path}/photos');
      } catch (error) {
        debugPrint('[PHOTOS] Storage unavailable: $error');
      }
    }
    final root = _root;
    if (root != null && !root.existsSync()) root.createSync(recursive: true);
    load();
  }

  /// Reads the saved list; albums whose files vanished are dropped.
  void load() {
    _albums.clear();
    final raw = LocalStore.readString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded) {
            final album = SavedAlbum.fromJson(entry);
            if (album == null) continue;
            album.photos.removeWhere((p) => !_fileOf(album, p).existsSync());
            if (album.photos.isNotEmpty) _albums.add(album);
          }
        }
      } catch (error) {
        debugPrint('[PHOTOS] Saved list unreadable: $error');
      }
    }
    _albums.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    notifyListeners();
  }

  void _persist() => LocalStore.writeString(
        _key,
        jsonEncode(<Object?>[for (final a in _albums) a.toJson()]),
      );

  // -------------------------------------------------------------------------
  // Queries
  // -------------------------------------------------------------------------

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

  /// How many of [photos] are already saved in [albumId].
  int savedCount(String albumId, Iterable<AlbumPhoto> photos) =>
      photos.where((p) => isSaved(albumId, p.id)).length;

  PhotoJob? jobFor(String albumId) => _jobs[albumId];

  File fileOf(SavedAlbum album, SavedPhoto photo) => _fileOf(album, photo);

  File _fileOf(SavedAlbum album, SavedPhoto photo) =>
      File('${_root?.path ?? ''}/${album.dir}/${photo.file}');

  // -------------------------------------------------------------------------
  // Saving
  // -------------------------------------------------------------------------

  /// Saves [photos] of [album]; pictures that are already saved are skipped.
  /// Returns how many were saved now. Only one job per album runs at a time.
  Future<int> savePhotos(
    AlbumRef album,
    List<AlbumPhoto> photos, {
    String? modelName,
    Map<String, String>? headers,
  }) async {
    final root = _root;
    if (root == null || _jobs.containsKey(album.id)) return 0;

    final todo = photos.where((p) => !isSaved(album.id, p.id)).toList();
    if (todo.isEmpty) return 0;

    var saved = this.album(album.id);
    final isNew = saved == null;
    saved ??= SavedAlbum(
      id: album.id,
      title: album.title,
      url: album.url,
      dir: _safeName(album.id, fallback: 'album'),
      modelName: modelName,
    );
    final dir = Directory('${root.path}/${saved.dir}');
    dir.createSync(recursive: true);

    final job = PhotoJob(todo.length);
    _jobs[album.id] = job;
    notifyListeners();

    final requestHeaders = headers ?? _defaultHeaders(album.url);
    var next = 0;
    var ok = 0;

    Future<void> worker() async {
      while (!job.cancelled) {
        final index = next++;
        if (index >= todo.length) return;
        final photo = todo[index];
        try {
          final name = await _download(photo, dir, requestHeaders);
          saved!.photos.add(SavedPhoto(id: photo.id, file: name));
          if (isNew && this.album(album.id) == null) {
            _albums.insert(0, saved); // Appears in the Library with its 1st photo.
          }
          ok++;
        } catch (error) {
          job.failed++;
          debugPrint('[PHOTOS] ${photo.id} failed: ${error.runtimeType}');
        }
        job.done++;
        notifyListeners();
      }
    }

    try {
      await Future.wait<void>([for (var i = 0; i < _parallel; i++) worker()]);
    } finally {
      _jobs.remove(album.id);
      saved.photos.sort((a, b) => _compareIds(a.id, b.id));
      if (saved.photos.isEmpty) {
        _albums.remove(saved);
        _deleteDir(dir);
      }
      _persist();
      notifyListeners();
    }
    return ok;
  }

  /// Stops after the pictures being downloaded right now.
  void cancel(String albumId) => _jobs[albumId]?.cancelled = true;

  Future<String> _download(
    AlbumPhoto photo,
    Directory dir,
    Map<String, String> headers,
  ) async {
    final response = await (_client ??= http.Client())
        .get(Uri.parse(photo.fullUrl), headers: headers)
        .timeout(const Duration(seconds: 40));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final bytes = response.bodyBytes;
    final extension = _imageExtension(bytes);
    if (extension == null) {
      // An HTML error page (expired token) is not a picture.
      throw const FormatException('Not an image');
    }
    final name = '${_safeName(photo.id, fallback: 'photo')}.$extension';
    await File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
    return name;
  }

  Map<String, String> _defaultHeaders(String albumUrl) =>
      imageHeadersFor(albumUrl) ??
      const <String, String>{
        'User-Agent': kBrowserUserAgent,
        'Accept': 'image/*,*/*;q=0.8',
      };

  // -------------------------------------------------------------------------
  // Removing
  // -------------------------------------------------------------------------

  Future<void> removePhoto(String albumId, String photoId) async {
    final saved = album(albumId);
    if (saved == null) return;
    final photo = saved.photos.where((p) => p.id == photoId).firstOrNull;
    if (photo == null) return;
    try {
      final file = _fileOf(saved, photo);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    saved.photos.remove(photo);
    if (saved.photos.isEmpty) {
      _albums.remove(saved);
      _deleteDir(Directory('${_root?.path ?? ''}/${saved.dir}'));
    }
    _persist();
    notifyListeners();
  }

  Future<void> removeAlbum(String albumId) async {
    final saved = album(albumId);
    if (saved == null) return;
    cancel(albumId);
    _albums.remove(saved);
    _deleteDir(Directory('${_root?.path ?? ''}/${saved.dir}'));
    _persist();
    notifyListeners();
  }

  void _deleteDir(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// `jpg` / `png` / `webp` / `gif` from the first bytes, or null when the data
  /// is not a picture.
  static String? _imageExtension(List<int> b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8) return 'jpg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'png';
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'webp';
    }
    return null;
  }

  /// A file / folder name made of letters, digits, `.`, `-` and `_` only.
  static String _safeName(String value, {required String fallback}) {
    var name = value.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}/?$'), '');
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    name = name.replaceAll(RegExp(r'^_+|_+$'), '');
    if (name.length > 90) name = name.substring(name.length - 90);
    return name.isEmpty ? fallback : name;
  }

  /// Site order: by the number in the file name (`29944.jpg`), else by text.
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
