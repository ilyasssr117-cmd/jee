import 'package:flutter/services.dart';

/// Browsing screens: portrait, status bar visible.
Future<void> applyBrowseOrientation() async {
  try {
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  } catch (_) {}
}

/// The player is landscape and immersive by default; [portrait] is used for
/// vertical (9:16) videos so they fill the screen.
Future<void> applyPlayerOrientation({bool portrait = false}) async {
  try {
    await SystemChrome.setPreferredOrientations(
      portrait
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  } catch (_) {}
}
