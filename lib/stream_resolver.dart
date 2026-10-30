import 'dart:async';
import 'dart:collection';

import 'package:http/http.dart' as http;

class _FinalUri {
  const _FinalUri(this.uri, this.expires);

  final Uri uri;
  final DateTime expires;
}

const Duration _finalUriTtl = Duration(minutes: 10);
const int _finalUriMax = 32;

final LinkedHashMap<String, _FinalUri> _finalUris =
    LinkedHashMap<String, _FinalUri>();
final Map<String, Future<Uri>> _finalUriRunning = <String, Future<Uri>>{};

void clearFinalStreamUris() {
  _finalUris.clear();
  _finalUriRunning.clear();
}

String _contextKey(Uri uri, Map<String, String> headers) {
  final names = headers.keys.toList()..sort();
  final buffer = StringBuffer(uri.toString());
  for (final name in names) {
    buffer
      ..write('\n')
      ..write(name.toLowerCase())
      ..write(':')
      ..write(headers[name]);
  }
  return buffer.toString();
}

Future<Uri> resolveFinalStreamUri(
  Uri uri,
  Map<String, String> headers, {
  int maxHops = 5,
  Duration timeout = const Duration(seconds: 10),
  bool refresh = false,
}) {
  final key = _contextKey(uri, headers);
  if (!refresh) {
    final hit = _finalUris[key];
    if (hit != null && DateTime.now().isBefore(hit.expires)) {
      return Future<Uri>.value(hit.uri);
    }
    final running = _finalUriRunning[key];
    if (running != null) return running;
  }

  late final Future<Uri> tracked;
  final probe = _probe(uri, headers, maxHops, timeout).then((result) {
    if (result.ok && identical(_finalUriRunning[key], tracked)) {
      _finalUris.remove(key);
      _finalUris[key] = _FinalUri(result.uri, DateTime.now().add(_finalUriTtl));
      while (_finalUris.length > _finalUriMax) {
        _finalUris.remove(_finalUris.keys.first);
      }
    }
    return result.uri;
  });
  tracked = probe.whenComplete(() {
    if (identical(_finalUriRunning[key], tracked)) {
      _finalUriRunning.remove(key);
    }
  });
  _finalUriRunning[key] = tracked;
  return tracked;
}

Future<({Uri uri, bool ok})> _probe(
  Uri uri,
  Map<String, String> headers,
  int maxHops,
  Duration timeout,
) async {
  final client = http.Client();
  var current = uri;
  try {
    for (var hop = 0; hop < maxHops; hop++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(<String, String>{...headers, 'Range': 'bytes=0-0'});
      final response = await client.send(request).timeout(timeout);
      final location = response.headers['location'];
      if (response.isRedirect && location != null && location.isNotEmpty) {
        await response.stream.drain<void>().timeout(
              const Duration(seconds: 3),
              onTimeout: () {},
            );
        current = current.resolve(location);
        continue;
      }
      final status = response.statusCode;
      return (uri: current, ok: status >= 200 && status < 300);
    }
    return (uri: current, ok: false);
  } catch (_) {
    return (uri: uri, ok: false);
  } finally {
    client.close();
  }
}
