import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Single source of truth for device class (TV fixes 5.5/5.7).
///
/// Previously "is this a TV?" was answered in four places with three
/// different rules (native MainActivity, platform_ui, HomePage, and a
/// width>=900 heuristic in the source picker). Now the native channel
/// is queried exactly once, during bootstrap, and every consumer reads
/// [isTelevision]. Layout size (tablet/foldable) is a SEPARATE axis:
/// a wide window is not a television.
abstract final class DeviceProfile {
  static bool _detected = false;

  /// True only for real Android TV / Google TV devices, as reported by
  /// the native UiMode/Leanback check in MainActivity.
  static bool isTelevision = false;

  static Future<void> detect({bool force = false}) async {
    if (_detected && !force) return;
    _detected = true;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      isTelevision = await const MethodChannel(
            'com.tv.watch_tube/device',
          ).invokeMethod<bool>('isTelevision') ??
          false;
    } on PlatformException {
      // Older builds: fall back to the non-TV experience.
    } on MissingPluginException {
      // Non-Android / tests: not a television.
    }
  }

  /// Logical size of the primary view.
  static ui.Size get logicalSize {
    final view = ui.PlatformDispatcher.instance.views.first;
    return view.physicalSize / view.devicePixelRatio;
  }

  /// Tablet / foldable / large-window tier: shortest side >= 600dp.
  /// Used for responsive layout only — never for TV classification.
  static bool get isLargeScreen => logicalSize.shortestSide >= 600;
}
