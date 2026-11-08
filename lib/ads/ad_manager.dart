import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'age_gate.dart';
import 'vast.dart';

const String kVastUrl = 'https://s.magsrv.com/v1/vast.php?idz=6083398';
const int kAdEveryNVideos = 2;
const String _videoCountKey = 'video_count_v3';

// Serialize increments so rapid transitions cannot read the same old value.
Future<void> _counterTail = Future<void>.value();

Future<int> _incrementVideoCount(SharedPreferences preferences) async {
  final previous = _counterTail;
  final release = Completer<void>();
  _counterTail = release.future;
  await previous;
  try {
    // Migrate the existing counter without resetting the user's schedule.
    final oldCount = preferences.getInt(_videoCountKey) ??
        preferences.getInt('video_count_v2') ??
        preferences.getInt('video_count') ??
        0;
    final count = oldCount + 1;
    await preferences.setInt(_videoCountKey, count);
    return count;
  } finally {
    release.complete();
  }
}

/// Requests an ad on normal online video opens #1, #3, #5, etc.
/// Reels and local/offline videos are excluded by PlayerPage before this call.
/// A VAST no-fill or network failure never blocks the main video.
Future<VastAd?> getAdIfDue(
  BuildContext context, {
  required String videoId,
}) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final count = await _incrementVideoCount(preferences);
    final due = (count - 1) % kAdEveryNVideos == 0;
    debugPrint(
      '[ADS] Eligible online video #$count (id=$videoId): '
      '${due ? 'request VAST' : 'alternating slot: no ad'}',
    );
    if (!due) return null;
    if (!context.mounted) {
      debugPrint('[ADS] Player context was disposed before age check.');
      return null;
    }
    if (!await confirmAge(context)) {
      debugPrint('[ADS] Age was not confirmed; ad skipped.');
      return null;
    }

    debugPrint('[ADS] Fetching ExoClick VAST for video #$count.');
    final ad = await fetchVast(kVastUrl);
    if (ad == null) {
      debugPrint(
        '[ADS] No playable VAST ad returned for video #$count; '
        'main video will play.',
      );
    } else {
      debugPrint('[ADS] Playable VAST ad received for video #$count.');
    }
    return ad;
  } catch (error) {
    debugPrint('[ADS] Ad request failed safely: ${error.runtimeType}.');
    return null;
  }
}
