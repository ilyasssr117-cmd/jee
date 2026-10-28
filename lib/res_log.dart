import 'package:flutter/foundation.dart';

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
