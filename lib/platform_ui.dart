import 'package:flutter/services.dart';

import 'device_profile.dart';

/// Orientation policy (fixes 07, TV-4/5.7):
/// - Television: landscape only, always — including the player, even
///   for portrait videos and even if the rotate control is used.
/// - Tablet/foldable (shortest side >= 600dp): free orientation.
/// - Phone: portrait for browsing, content-aware in the player.
Future<void> applyBrowseOrientation() async {
  try {
    await DeviceProfile.detect();
    final orientations = DeviceProfile.isTelevision
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : DeviceProfile.isLargeScreen
            ? DeviceOrientation.values
            : const [DeviceOrientation.portraitUp];
    await SystemChrome.setPreferredOrientations(orientations);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
}

Future<void> applyPlayerOrientation({bool portrait = false}) async {
  try {
    await DeviceProfile.detect();
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
