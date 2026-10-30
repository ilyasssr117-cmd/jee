import 'package:flutter/foundation.dart';

import 'media_headers.dart';
import 'stream_resolver.dart';
import 'video_repository.dart';

class PlaybackSource {
  const PlaybackSource(this.url, this.headers);

  final String url;
  final Map<String, String> headers;
}

Future<PlaybackSource> resolvePlaybackSource(
  Uri streamUri,
  String? pageUrl, {
  bool refresh = false,
  bool tolerant = false,
}) async {
  var headers = streamHeaders(streamUri, pageUrl);
  final page = Uri.tryParse(pageUrl?.trim() ?? '');
  final validPage = page != null &&
      (page.scheme == 'http' || page.scheme == 'https') &&
      page.host.isNotEmpty;
  try {
    final cookie = await videoRepository.getPlaybackCookieHeader(
      streamUri: streamUri,
      pageUrl: validPage ? page.toString() : null,
      userAgent: headers['User-Agent'] ?? '',
      refresh: refresh,
    );
    if (cookie.isNotEmpty) {
      headers = <String, String>{...headers, 'Cookie': cookie};
    }
  } catch (_) {
    if (!tolerant) rethrow;
  }
  final finalUri =
      await resolveFinalStreamUri(streamUri, headers, refresh: refresh);
  return PlaybackSource(finalUri.toString(), headers);
}

abstract final class ResLog {
  static const String tag = '[RES]';

  static String? _last;

  static void video({required String? pageUrl, required String videoUrl}) {
    if (!kDebugMode) return;
    final page = Uri.tryParse((pageUrl ?? '').trim());
    final video = Uri.tryParse(videoUrl.trim());
    if (page == null ||
        video == null ||
        !page.hasAuthority ||
        !video.hasAuthority ||
        (page.scheme != 'http' && page.scheme != 'https') ||
        (video.scheme != 'http' && video.scheme != 'https')) {
      return;
    }
    final line = '$tag ${page.origin} | ${video.origin}';
    if (line == _last) return;
    _last = line;
    debugPrint(line);
  }
}
