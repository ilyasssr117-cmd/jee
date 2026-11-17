import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'content_source.dart';

/// Small disk-backed Reels history.
///
/// The file stores only encoded reel IDs. Lookups scan the file as a stream
/// and keep only the current response's candidate IDs in memory; the entire
/// watch history is never loaded into RAM.
class ReelSeenStore {
  ReelSeenStore(this.source);

  final ContentSource source;
  Future<File>? _fileFuture;
  static final Map<String, Future<void>> _writeTails = <String, Future<void>>{};

  Future<void> get _writeTail =>
      _writeTails[source.name] ?? Future<void>.value();

  /// Stable, compact key for a reel's media URL (query/fragment stripped), so
  /// the same clip is recognised even if the source hands out a new ID.
  static String urlKey(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return '';
    return 'u:${uri.host}${uri.path}';
  }

  static const int _maxFileBytes = 1024 * 1024; // ~1 MB of IDs
  static const int _keepTailBytes = 640 * 1024;

  String _encode(String id) =>
      base64Url.encode(utf8.encode(id)).replaceAll('=', '');

  Future<File> _file() => _fileFuture ??= _resolveFile();

  Future<File> _resolveFile() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}'
        'reels_seen_${source.name}_v1.txt');
  }

  /// Returns only IDs from [ids] which already exist in persistent history.
  /// Memory use is proportional to the current network batch, not history size.
  Future<Set<String>> findSeenIds(Iterable<String> ids) async {
    final wanted = <String, String>{};
    for (final id in ids) {
      final value = id.trim();
      if (value.isNotEmpty) wanted[_encode(value)] = value;
    }
    if (wanted.isEmpty) return <String>{};

    try {
      await _writeTail;
      final file = await _file();
      if (!await file.exists()) return <String>{};
      final found = <String>{};
      await for (final line in file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (wanted.containsKey(line)) {
          found.add(wanted[line]!);
          if (found.length == wanted.length) break;
        }
      }
      return found;
    } catch (_) {
      // A history read failure must not prevent playback. The ID is still
      // written after it becomes visible, so normal operation repairs this.
      return <String>{};
    }
  }

  /// Marks a reel as watched by ID and (optionally) media URL.
  Future<void> markSeen(String id, {String? url}) {
    final keys = <String>[
      if (id.trim().isNotEmpty) id.trim(),
      if (url != null && urlKey(url).isNotEmpty) urlKey(url),
    ];
    if (keys.isEmpty) return Future<void>.value();
    final payload = keys.map((k) => '${_encode(k)}\n').join();
    final previous = _writeTail;
    final task = previous.then((_) async {
      final file = await _file();
      await file.writeAsString(payload, mode: FileMode.append, flush: true);
      await _trimIfNeeded(file);
    });
    _writeTails[source.name] = task.catchError((Object _) {});
    return task;
  }

  /// Keeps the history file small: when it grows past the limit only the most
  /// recent entries are kept. Only a ~640 KB tail is ever read into memory.
  Future<void> _trimIfNeeded(File file) async {
    try {
      final length = await file.length();
      if (length <= _maxFileBytes) return;
      final raf = await file.open();
      List<int> tail;
      try {
        await raf.setPosition(length - _keepTailBytes);
        tail = await raf.read(_keepTailBytes);
      } finally {
        await raf.close();
      }
      final newline = tail.indexOf(0x0A);
      final trimmed = newline < 0 ? tail : tail.sublist(newline + 1);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(trimmed, flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  /// Deletes the watched-reels history of every content source.
  static Future<void> clearAll() async {
    try {
      final directory = await getApplicationSupportDirectory();
      if (!await directory.exists()) return;
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('reels_seen_')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }
}
