import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vxtube_final/ads/age_gate.dart';
import 'package:vxtube_final/ads/vast.dart';

/// Ad networks, tried in order. The first one that returns a playable ad wins;
/// if none does, the main video simply plays. Put the best-paying network first.
const List<String> kVastUrls = <String>[
  // 1) ExoClick (zone 6083398)
  'https://s.magsrv.com/v1/vast.php?idz=6083398',
  // 2) HilltopAds (zone 7609485)
  'https://direct-league.com/d-mjFfzOd.GpN/vJZiGuUs/ceOmO9puLZxU/lskZPWTHcR2uMfDhkp0/OdDjUdtGNvzDYGwyOzTHQ/4MO-QC',
  // 3) ClickAdilla (AD Code 471519, wrapper)
  'https://vast.yomeno.xyz/vast?spot_id=1506531',
];

/// Total time the user may wait for an ad before the main video plays.
const Duration _kAdBudget = Duration(seconds: 10);
const Duration _kPerNetworkBudget = Duration(seconds: 5);
const int kAdEveryNVideos = 2;

/// A full-screen ad is shown in Reels after every N reels the user swipes to.
const int kReelAdEveryN = 5;
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

/// Tries each network in [kVastUrls] in order, within a total time budget.
Future<VastAd?> fetchFirstAvailable() async {
  final clock = Stopwatch()..start();
  for (var i = 0; i < kVastUrls.length; i++) {
    final remaining = _kAdBudget - clock.elapsed;
    if (remaining <= Duration.zero) break;
    final budget = remaining < _kPerNetworkBudget ? remaining : _kPerNetworkBudget;
    final ad = await fetchVast(kVastUrls[i]).timeout(
      budget,
      onTimeout: () => null,
    );
    if (ad != null) {
      debugPrint('[ADS] Ad received from network #${i + 1}.');
      return ad;
    }
    debugPrint('[ADS] Network #${i + 1} had no ad; trying next.');
  }
  return null;
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

    debugPrint('[ADS] Fetching VAST (waterfall) for video #$count.');
    final ad = await fetchFirstAvailable();
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

/// Fetches an ad for the Reels feed (no video counter involved). Returns null
/// when the user is under 18 / unconfirmed or no network has an ad; the reels
/// simply continue in that case.
Future<VastAd?> requestReelAd(BuildContext context) async {
  try {
    if (!context.mounted) return null;
    if (!await confirmAge(context)) return null;
    final ad = await fetchFirstAvailable();
    debugPrint('[ADS] Reel ad ${ad == null ? 'not available' : 'ready'}.');
    return ad;
  } catch (error) {
    debugPrint('[ADS] Reel ad request failed safely: ${error.runtimeType}.');
    return null;
  }
}
