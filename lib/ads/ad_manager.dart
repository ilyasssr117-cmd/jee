import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vxtube_final/ads/age_gate.dart';
import 'package:vxtube_final/ads/vast.dart';

const List<String> kVastUrls = <String>[
  'https://s.magsrv.com/v1/vast.php?idz=6083398',
  'https://direct-league.com/d-mjFfzOd.GpN/vJZiGuUs/ceOmO9puLZxU/lskZPWTHcR2uMfDhkp0/OdDjUdtGNvzDYGwyOzTHQ/4MO-QC',
  'https://vast.yomeno.xyz/vast?spot_id=1506531',
];

const Duration _kAdBudget = Duration(seconds: 10);
const Duration _kPerNetworkBudget = Duration(seconds: 5);
const int kAdEveryNVideos = 2;

const int kReelAdEveryN = 5;
const String _videoCountKey = 'video_count_v3';

Future<void> _counterTail = Future<void>.value();

Future<int> _incrementVideoCount(SharedPreferences preferences) async {
  final previous = _counterTail;
  final release = Completer<void>();
  _counterTail = release.future;
  await previous;
  try {
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
      return ad;
    }
  }
  return null;
}

Future<VastAd?> getAdIfDue(
  BuildContext context, {
  required String videoId,
}) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final count = await _incrementVideoCount(preferences);
    final due = (count - 1) % kAdEveryNVideos == 0;
    if (!due) return null;
    if (!context.mounted) {
      return null;
    }
    if (!await confirmAge(context)) {
      return null;
    }

    final ad = await fetchFirstAvailable();
    if (ad == null) {
    } else {
    }
    return ad;
  } catch (error) {
    return null;
  }
}

