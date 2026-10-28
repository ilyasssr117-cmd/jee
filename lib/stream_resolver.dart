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

/// Forgets every remembered final address (Settings -> Clear cache).
void clearFinalStreamUris() => _finalUris.clear();

/// Finds the address a stream link finally points to.
///
/// The video link usually answers with a redirect (Location header) to the
/// real file. Following it once, here, with the SAME headers and cookie that
/// the player uses, means the video player can talk to the final server
/// directly: no redirect on every range request, and the cookie is not lost
/// on the way to the second host.
///
/// The answer is remembered for a few minutes and shared between callers that
/// ask at the same time, so the same link is never probed twice. [refresh]
/// skips the remembered answer (reconnect after a failure).
///
/// Never throws: any problem returns [uri] unchanged (and is not remembered).
Future<Uri> resolveFinalStreamUri(
  Uri uri,
  Map<String, String> headers, {
  int maxHops = 5,
  Duration timeout = const Duration(seconds: 10),
  bool refresh = false,
}) {
  final key = uri.toString();
  if (!refresh) {
    final hit = _finalUris[key];
    if (hit != null && DateTime.now().isBefore(hit.expires)) {
      return Future<Uri>.value(hit.uri);
    }
    final running = _finalUriRunning[key];
    if (running != null) return running;
  }
  final future = _probe(uri, headers, maxHops, timeout).then((result) {
    if (result.ok) {
      _finalUris.remove(key);
      _finalUris[key] = _FinalUri(result.uri, DateTime.now().add(_finalUriTtl));
      while (_finalUris.length > _finalUriMax) {
        _finalUris.remove(_finalUris.keys.first);
      }
    }
    return result.uri;
  });
  final tracked = future.whenComplete(() {
    _finalUriRunning.remove(key);
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
  try {
    var current = uri;
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
      return (uri: current, ok: true); // The real file; closed without a body.
    }
    return (uri: current, ok: true);
  } catch (_) {
    return (uri: uri, ok: false);
  } finally {
    client.close();
  }
}
