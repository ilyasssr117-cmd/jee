import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'age_gate.dart';
import 'vast.dart';

const String kVastUrl = 'https://s.magsrv.com/v1/vast.php?idz=6083398';
const int kAdEveryNVideos = 2;
const String _videoCountKey = 'video_count_v2';

// Serialize counter updates so two fast player transitions cannot read the
// same old value and accidentally consume the same alternating slot.
Future<void> _counterTail = Future<void>.value();

Future<int> _incrementVideoCount(SharedPreferences preferences) async {
  final previous = _counterTail;
  final release = Completer<void>();
  _counterTail = release.future;
  await previous;
  try {
    final count = (preferences.getInt(_videoCountKey) ?? 0) + 1;
    await preferences.setInt(_videoCountKey, count);
    return count;
  } finally {
    release.complete();
  }
}

/// Fetches an ad only on odd-numbered network video opens after age consent.
/// A missing or unavailable preference store fails open and shows no ad.
Future<VastAd?> getAdIfDue(
  BuildContext context, {
  required String videoId,
}) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final count = await _incrementVideoCount(preferences);
    final due = (count - 1) % kAdEveryNVideos == 0;
    debugPrint(
      '[ADS] Video open #$count (id=$videoId): ${due ? 'ad slot' : 'no-ad slot'}.',
    );
    if (!due) return null;
    if (!context.mounted || !await confirmAge(context)) {
      debugPrint('[ADS] Age not confirmed; skipping this ad slot.');
      return null;
    }
    final ad = await fetchVast(kVastUrl);
    if (ad == null) debugPrint('[ADS] VAST returned no playable ad.');
    return ad;
  } catch (error) {
    debugPrint('[ADS] Ad check failed safely: ${error.runtimeType}.');
    return null;
  }
}
