/// Browser-like headers for native stream requests (same values the full
/// player uses), shared with the card preview.
Map<String, String> streamHeaders(Uri streamUri, String? pageUrl) {
  final pageUri = Uri.tryParse(pageUrl?.trim() ?? '');
  final hasPage = pageUri != null &&
      (pageUri.scheme == 'http' || pageUri.scheme == 'https') &&
      pageUri.host.isNotEmpty;
  final origin = hasPage ? pageUri.origin : streamUri.origin;
  final referer = hasPage ? pageUri.toString() : '$origin/';
  return <String, String>{
    'User-Agent': 'Mozilla/5.0 (Linux; Android 11; TV) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Referer': referer,
    'Origin': origin,
    'Accept': '*/*',
    'Cookie': 'kt_acctoken=OTQuMTA5LjI4LjI0MSwxNjAuMTc3LjE3Ni44NQ',
  };
}
