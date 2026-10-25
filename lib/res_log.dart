import 'package:flutter/foundation.dart';

/// Debug-only trace of every video that is opened and played:
///
///     page  : the video page URL (it contains the video number and title)
///     video : the stream URL extracted from that page
///
/// The app only *prints* one tagged line per video. An app running on an
/// emulator or TV cannot write into your project folder, so the companion
/// script `tool/res_logger.dart` (run on the computer) collects these lines
/// and saves them to `res.txt` in the project root. Nothing is stored on the
/// device. In release builds this does nothing at all.
abstract final class ResLog {
  static const String tag = '[RES]';

  static String? _last;

  static void video({required String? pageUrl, required String videoUrl}) {
    if (!kDebugMode) return;
    final page = (pageUrl ?? '').trim();
    final video = videoUrl.trim();
    if (page.isEmpty || video.isEmpty) return;
    final line = '$tag $page | $video';
    if (line == _last) return; // Same video re-initialised (retry / resume).
    _last = line;
    debugPrint(line);
  }
}
