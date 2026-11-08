import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'download_store.dart';
import 'history_store.dart';
import 'models.dart';
import 'native_bridge.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';

class WidgetSync with WidgetsBindingObserver {
  WidgetSync._();

  static final WidgetSync instance = WidgetSync._();

  Timer? _timer;
  bool _started = false;
  bool _writing = false;
  bool _writeAgain = false;
  String? _thumbUrl;

  void start() {
    if (_started || !Platform.isIOS) return;
    _started = true;
    HistoryStore.instance.addListener(schedule);
    DownloadStore.instance.addListener(schedule);
    WidgetsBinding.instance.addObserver(this);

    NativeBridge.instance.onOpenUrl = _open;
    final pending = NativeBridge.instance.takePendingUrl();
    if (pending != null) _open(pending);

    schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _timer?.cancel();
      unawaited(_write());
    }
  }

  void schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () => unawaited(_write()));
  }

  Future<void> _write() async {
    if (_writing) {
      _writeAgain = true;
      return;
    }
    _writing = true;
    try {
      do {
        _writeAgain = false;
        await _writeOnce();
      } while (_writeAgain);
    } finally {
      _writing = false;
    }
  }

  Future<void> _writeOnce() async {
    try {
      final dir = await NativeBridge.instance.widgetContainerPath();
      if (dir == null) return;

      Video? resume;
      double? fraction;
      for (final entry in HistoryStore.instance.items) {
        final f = PlaybackProgress.instance.fraction(entry.video.id);
        if (f != null) {
          resume = entry.video;
          fraction = f;
          break;
        }
      }
      if (resume == null && HistoryStore.instance.items.isNotEmpty) {
        resume = HistoryStore.instance.items.first.video;
      }

      final thumb = File('$dir/resume.jpg');
      final wanted = resume?.thumbnailUrl?.trim();
      if (resume == null || wanted == null || wanted.isEmpty) {
        if (thumb.existsSync()) thumb.deleteSync();
        _thumbUrl = null;
      } else if (wanted != _thumbUrl || !thumb.existsSync()) {
        final uri = Uri.tryParse(wanted);
        if (uri != null &&
            (uri.scheme == 'http' || uri.scheme == 'https') &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            uri.toString().length <= 4096) {
          try {
            final imageBytes = await _fetchWidgetThumbnail(uri);
            if (imageBytes != null) {
              await thumb.writeAsBytes(imageBytes, flush: true);
              _thumbUrl = wanted;
            }
          } catch (_) {}
        }
      }

      var done = 0;
      var active = 0;
      var bytes = 0;
      var total = 0;
      for (final item in DownloadStore.instance.items) {
        if (item.status == DownloadStatus.done) {
          done++;
        } else if (item.status == DownloadStatus.downloading ||
            item.status == DownloadStatus.queued) {
          active++;
          if (item.bytesTotal > 0) {
            bytes += item.bytes.value;
            total += item.bytesTotal;
          }
        }
      }

      final json = <String, Object?>{
        'resumeId': resume?.id,
        'resumeTitle': resume?.title,
        'resumeProgress': fraction,
        'downloadsDone': done,
        'downloadsActive': active,
        'activeProgress': total > 0 ? (bytes / total).clamp(0.0, 1.0) : -1.0,
      };
      await File('$dir/widget.json')
          .writeAsString(jsonEncode(json), flush: true);
      await NativeBridge.instance.reloadWidgets();
    } catch (error) {
      debugPrint('[WIDGET] sync failed: ${error.runtimeType}');
    }
  }

  Future<Uint8List?> _fetchWidgetThumbnail(Uri uri) async {
    const maxBytes = 2 * 1024 * 1024;
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)
        ..headers['User-Agent'] =
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 ||
          (response.contentLength != null &&
              response.contentLength! > maxBytes)) {
        await response.stream.drain<void>().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        return null;
      }
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 8),
      )) {
        total += chunk.length;
        if (total > maxBytes) return null;
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      if (!_isImageBytes(bytes)) return null;
      return bytes;
    } finally {
      client.close();
    }
  }

  bool _isImageBytes(List<int> bytes) {
    if (bytes.length < 12) return false;
    final jpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
    final png =
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    final gif = bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46;
    final webp =
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    return jpeg || png || gif || webp;
  }

  Future<void> _open(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'watchtube' || uri.host != 'video') return;
    final id = uri.queryParameters['id'];
    if (id == null || id.isEmpty) return;

    Video? video;
    for (final entry in HistoryStore.instance.items) {
      if (entry.video.id == id) {
        video = entry.video;
        break;
      }
    }
    video ??= DownloadStore.instance.item(id)?.video;
    if (video == null) return;

    for (var i = 0; i < 40; i++) {
      final context = rootNavigatorKey.currentContext;
      if (context != null && context.mounted) {
        await launchPlayer(context, video);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
}
