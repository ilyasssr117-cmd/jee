import 'package:flutter/services.dart';

import 'device_profile.dart';

/// Orientation policy (fixes 07, TV-4/5.7):
/// - Television: landscape only, always — including the player, even
///   for portrait videos and even if the rotate control is used.
/// - Everything else: portrait for browsing (the contract the
///   platform_ui tests encode), content-aware in the player.
///   Large-screen layout freedom lives in the layout layer
///   (DeviceProfile.isLargeScreen), not in orientation locking.
///
/// The TV state is re-queried on every call, matching the original
/// behavior: DeviceProfile caches for layout consumers, but an
/// orientation decision must never act on a stale answer.
Future<void> applyBrowseOrientation() async {
  try {
    await DeviceProfile.detect(force: true);
    final orientations = DeviceProfile.isTelevision
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [DeviceOrientation.portraitUp];
    await SystemChrome.setPreferredOrientations(orientations);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
}

Future<void> applyPlayerOrientation({bool portrait = false}) async {
  try {
    await DeviceProfile.detect(force: true);
    // A television never rotates (fix TV-4): portrait content is
    // letterboxed inside the landscape TV interface instead.
    final effectivePortrait = portrait && !DeviceProfile.isTelevision;
    await SystemChrome.setPreferredOrientations(
      effectivePortrait
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
}
