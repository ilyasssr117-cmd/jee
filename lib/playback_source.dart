import 'stream_headers.dart';
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
