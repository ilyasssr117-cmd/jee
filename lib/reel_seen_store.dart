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

  Future<void> markSeen(String id) {
    final value = id.trim();
    if (value.isEmpty) return Future<void>.value();
    final encoded = _encode(value);
    final previous = _writeTail;
    final task = previous.then((_) async {
      final file = await _file();
      await file.writeAsString('$encoded\n', mode: FileMode.append, flush: true);
    });
    _writeTails[source.name] = task.catchError((Object _) {});
    return task;
  }
}
