import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'age_gate.dart';
import 'vast.dart';

const String kVastUrl = 'https://s.magsrv.com/v1/vast.php?idz=6083398';
const int kAdEveryNVideos = 2;

/// Fetches an ad only on odd-numbered network video opens after age consent.
/// A missing or unavailable preference store fails open and shows no ad.
Future<VastAd?> getAdIfDue(BuildContext context) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final count = (preferences.getInt('video_count') ?? 0) + 1;
    await preferences.setInt('video_count', count);
    if ((count - 1) % kAdEveryNVideos != 0) return null;
    if (!context.mounted || !await confirmAge(context)) return null;
    return await fetchVast(kVastUrl);
  } catch (_) {
    return null;
  }
}
