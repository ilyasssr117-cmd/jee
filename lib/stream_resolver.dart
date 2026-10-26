import 'dart:async';

import 'package:http/http.dart' as http;

/// Finds the address a stream link finally points to.
///
/// The video link usually answers with a redirect (Location header) to the
/// real file. Following it once, here, with the SAME headers and cookie that
/// the player uses, means the video player can talk to the final server
/// directly: no redirect on every range request, and the cookie is not lost
/// on the way to the second host.
///
/// Never throws: any problem returns [uri] unchanged.
Future<Uri> resolveFinalStreamUri(
  Uri uri,
  Map<String, String> headers, {
  int maxHops = 5,
  Duration timeout = const Duration(seconds: 10),
}) async {
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
      return current; // The real file. The client is closed without a body.
    }
    return current;
  } catch (_) {
    return uri;
  } finally {
    client.close();
  }
}
