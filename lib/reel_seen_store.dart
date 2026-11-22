import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'content_source.dart';

class ReelSeenStore {
  ReelSeenStore(this.source);

  final ContentSource source;
  Future<File>? _fileFuture;
  static final Map<String, Future<void>> _writeTails = <String, Future<void>>{};

  Future<void> get _writeTail =>
      _writeTails[source.name] ?? Future<void>.value();

  static String urlKey(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return '';
    return 'u:${uri.host}${uri.path}';
  }

  static const int _maxFileBytes = 1024 * 1024;
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
      return <String>{};
    }
  }

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
