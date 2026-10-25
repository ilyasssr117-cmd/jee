import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/services.dart';

/// True on phones (short side under 600 logical px), read without a
/// BuildContext so it can be used before the first frame.
bool get isPhoneDevice {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return false;
  final view = views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  return size.shortestSide < 600;
}

/// Browsing screens: portrait on phones, landscape on TVs / tablets.
Future<void> applyBrowseOrientation() async {
  try {
    await SystemChrome.setPreferredOrientations(
      isPhoneDevice
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
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
