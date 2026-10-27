import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';

/// What happened when pictures were sent to the phone's Photos app.
class GallerySaveResult {
  const GallerySaveResult({
    required this.saved,
    this.denied = false,
    this.failed = 0,
  });

  /// Pictures that reached the Photos app.
  final int saved;

  /// The viewer refused (or turned off) access to Photos.
  final bool denied;

  /// Pictures that could not be saved for another reason.
  final int failed;
}

/// Saves picture files straight into the Photos app (iOS) / gallery (Android),
/// with the `gal` plugin. iOS needs `NSPhotoLibraryAddUsageDescription` in
/// Info.plist (see ios_setup/IOS_BUILD.md).
abstract final class PhotoSaver {
  /// Name of the album created in the Photos app.
  static const String albumName = 'Flow';

  static Future<GallerySaveResult> saveToGallery(List<String> paths) =>
      _save(paths, video: false);

  /// Saves a video file (mp4 / mov) into the Photos app.
  static Future<GallerySaveResult> saveVideoToGallery(String path) =>
      _save(<String>[path], video: true);

  static Future<GallerySaveResult> _save(
    List<String> paths, {
    required bool video,
  }) async {
    if (paths.isEmpty) return const GallerySaveResult(saved: 0);

    try {
      var allowed = await Gal.hasAccess();
      if (!allowed) allowed = await Gal.requestAccess();
      if (!allowed) return const GallerySaveResult(saved: 0, denied: true);
    } catch (error) {
      debugPrint('[PHOTOS] Access check failed: ${error.runtimeType}');
      return GallerySaveResult(saved: 0, failed: paths.length);
    }

    var saved = 0;
    for (final path in paths) {
      try {
        if (video) {
          await Gal.putVideo(path, album: albumName);
        } else {
          await Gal.putImage(path, album: albumName);
        }
        saved++;
      } catch (error) {
        debugPrint('[PHOTOS] Could not save a picture: ${error.runtimeType}');
      }
    }
    return GallerySaveResult(saved: saved, failed: paths.length - saved);
  }
}
