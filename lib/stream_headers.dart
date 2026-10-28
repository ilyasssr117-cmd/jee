Map<String, String> streamHeaders(Uri streamUri, String? pageUrl) {
  final pageUri = Uri.tryParse(pageUrl?.trim() ?? '');
  final hasPage = pageUri != null &&
      (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
      pageUri.host.isNotEmpty;
  final origin = hasPage ? pageUri.origin : streamUri.origin;
  final referer = hasPage ? pageUri.toString() : '$origin/';
  return <String, String>{
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
        'Mobile/15E148 Safari/604.1',
    'Referer': referer,
    'Origin': origin,
    'Accept': '*/*',
  };
}
