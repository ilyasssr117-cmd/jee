import 'stream_headers.dart';
import 'stream_resolver.dart';
import 'video_repository.dart';

/// Everything a player needs to open one video: the final address and the
/// exact headers (cookie included). Handing it on lets the next player skip
/// all the lookups that produced it (e.g. when Picture in Picture closes).
class PlaybackSource {
  const PlaybackSource(this.url, this.headers);

  final String url;
  final Map<String, String> headers;
}

/// The cookie plus the final address for [streamUri], using the repository's
/// remembered answers whenever they are fresh. [refresh] asks again (reconnect
/// after a failure). With [tolerant] a cookie problem only drops the cookie.
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
