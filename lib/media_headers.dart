Map<String, String>? imageHeadersFor(String? pageUrl) {
  final uri = Uri.tryParse(pageUrl ?? '');
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return <String, String>{
    'Referer': '${uri.origin}/',
    'User-Agent': kBrowserUserAgent,
    'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
  };
}

const String kBrowserUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
    'Mobile/15E148 Safari/604.1';

Map<String, String> streamHeaders(Uri streamUri, String? pageUrl) {
  final pageUri = Uri.tryParse(pageUrl?.trim() ?? '');
  final hasPage = pageUri != null &&
      (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
      pageUri.host.isNotEmpty;
  final origin = hasPage ? pageUri.origin : streamUri.origin;
  final referer = hasPage ? pageUri.toString() : '$origin/';
  return <String, String>{
    'User-Agent': kBrowserUserAgent,
    'Referer': referer,
    'Origin': origin,
    'Accept': '*/*',
  };
}

const String kReelMediaOrigin = 'https://apiv2.tik.porn';

const Map<String, String> kReelMediaHeaders = <String, String>{
  'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 '
      'Mobile/15E148 Safari/604.1',
  'Referer': '$kReelMediaOrigin/',
  'Origin': kReelMediaOrigin,
  'Accept': '*/*',
};
