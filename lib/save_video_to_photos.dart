import 'package:flutter/widgets.dart';

import 'download_store.dart';
import 'widgets/dialogs.dart';

Future<void> saveVideoToPhotos(
  BuildContext context,
  String videoId, {
  bool aboveBar = true,
}) async {
  final store = DownloadStore.instance;
  showToast(context, 'Saving to Photos\u2026', aboveBar: aboveBar);
  final result = await store.saveToPhotos(videoId);
  if (!context.mounted) return;

  if (result.denied) {
    showToast(
      context,
      'Allow access to Photos in Settings to save videos.',
      aboveBar: aboveBar,
    );
    return;
  }
  if (result.saved > 0) {
    showToast(context, 'Saved to Photos.', aboveBar: aboveBar);
    return;
  }
  final shared = await store.shareFile(videoId);
  if (!context.mounted) return;
  if (!shared) {
    showToast(context, 'Couldn\u2019t save the video.', aboveBar: aboveBar);
  }
}
