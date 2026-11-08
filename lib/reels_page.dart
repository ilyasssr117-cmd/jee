import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoIcons,
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        CupertinoActivityIndicator,
        showCupertinoModalPopup;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import 'app_theme.dart';
import 'analytics_service.dart';
import 'download_store.dart';
import 'error_text.dart';
import 'favorites_store.dart';
import 'local_store.dart';
import 'mini_player.dart';
import 'models.dart';
import 'photo_saver.dart';
import 'preview_manager.dart';
import 'reel_favorites.dart';
import 'services/remote_config_service.dart';
import 'touch.dart';
import 'widgets/app_button.dart';
import 'widgets/dialogs.dart';
import 'widgets/expandable_text.dart';

const String _kUserAgent = kReelUserAgent;

const String _kApiUrl = String.fromEnvironment(
  'REELS_API_URL',
  defaultValue: 'https://apiv2.tik.porn/getnextvideos',
);
const bool _kReelsSfwMode = bool.fromEnvironment(
  'REELS_SFW_MODE',
  defaultValue: false,
);
const Map<String, String> _kMediaHeaders = kReelMediaHeaders;

const int _kFirstBatch = 12;
const int _kNextBatch = 12;
const int _kPreloadAhead = 2;
const int _kMaxBufferedReels = 96;
const int _kReelHistoryKeep = 12;
const int _kReelTrimTrigger = 48;
const Duration _kNeighborPreloadDelay = Duration(milliseconds: 240);
const int _kMaxRefetchTries = 4;
const String _kClearKey = 'reels_clear_mode_v1';
const Duration _kReelDoubleTapWindow = Duration(milliseconds: 260);
const Duration _kReelLongPressDelay = Duration(milliseconds: 140);
const double _kReelMoveSlop = 14;

enum _ReelPlaybackState {
  idle,
  loading,
  playing,
  paused,
  buffering,
  failed,
  retrying,
}

String? _str(dynamic v) =>
    v is String && v.isNotEmpty && v.length <= 8192 ? v : null;

String _clipText(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

String? _url(dynamic v) {
  final s = _str(v);
  if (s == null) return null;
  final uri = Uri.tryParse(s);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.scheme == 'http' || uri.scheme == 'https' ? s : null;
}

String _titleOf(Map video) {
  final parsed = video['video_text']?['user_display_video_title']?['default']
      ?['parsed_text'];
  if (_str(parsed) != null) return _clipText(parsed as String, 240);
  return _clipText(_str(video['action_name']) ?? '', 240);
}

int _countOf(dynamic value) {
  if (value is num) {
    return value.clamp(0, 2147483647).toInt();
  }
  if (value is Map) {
    for (final key in const [
      'count',
      'total',
      'value',
      'like_count',
      'likes_count',
      'formatted',
      'display',
    ]) {
      if (!value.containsKey(key)) continue;
      final parsed = _countOf(value[key]);
      if (parsed > 0) return parsed;
    }
    return 0;
  }
  if (value is! String) return 0;
  final text = value.trim().toLowerCase().replaceAll(',', '');
  if (text.isEmpty) return 0;
  final match = RegExp(
    r'^(\d+(?:\.\d+)?)\s*([kmb])?\s*(?:likes?)?$',
  ).firstMatch(text);
  if (match == null) return 0;
  final number = double.tryParse(match.group(1) ?? '');
  if (number == null || !number.isFinite || number < 0) return 0;
  final multiplier = switch (match.group(2)) {
    'k' => 1000.0,
    'm' => 1000000.0,
    'b' => 1000000000.0,
    _ => 1.0,
  };
  return (number * multiplier).clamp(0, 2147483647).round();
}

int _likesOf(Map video) {
  const keys = [
    'like_count',
    'likes_count',
    'likeCount',
    'likesCount',
    'likes',
    'like',
    'total_likes',
    'totalLikes',
    'favorite_count',
    'favorites_count',
    'favourite_count',
    'upvote_count',
    'thumbs_up_count',
  ];
  for (final source in [
    video,
    video['statistics'],
    video['stats'],
    video['engagement'],
    video['counts'],
    video['video_statistics'],
    video['video_stats'],
    video['engagement_stats'],
    video['metadata'],
    video['meta'],
  ]) {
    if (source is! Map) continue;
    for (final key in keys) {
      if (!source.containsKey(key) || source[key] == null) continue;
      final parsed = _countOf(source[key]);
      if (parsed > 0) return parsed;
    }
  }
  return 0;
}

List<String> _tagsOf(Map video) {
  final raw = video['tags'];
  if (raw is! List) return const [];
  return [
    for (final t in raw.take(24))
      if (t is Map && _str(t['name']) != null)
        _clipText(t['name'] as String, 64),
  ];
}

List<ReelItem> parseReels(dynamic body) {
  if (body is! Map || body['data'] is! List) return const [];
  final out = <ReelItem>[];
  for (final raw in (body['data'] as List).take(48)) {
    if (raw is! Map) continue;
    final mp4 = _url(raw['mp4_url']);
    final hls = _url(raw['hls_url']);
    final url = mp4 ?? hls;
    if (url == null) continue;
    out.add(
      ReelItem(
        id: _clipText('${raw['video_id'] ?? url}', 256),
        videoUrl: url,
        fallbackUrl: mp4 != null ? hls : null,
        downloadUrl: _url(raw['download_url']),
        title: _titleOf(raw),
        thumbUrl: _url(raw['poster_url']) ?? _url(raw['thumbnail_url']),
        avatarUrl: _url(raw['user_avatar']),
        author: _clipText(_str(raw['user_name']) ?? '', 100),
        views: raw['view_count'] is num
            ? (raw['view_count'] as num).clamp(0, 2147483647).toInt()
            : 0,
        likes: _likesOf(raw),
        durationSec: raw['duration'] is num
            ? (raw['duration'] as num).clamp(0, 86400).toInt()
            : 0,
        tags: _tagsOf(raw),
      ),
    );
  }
  return out;
}

http.Client _makeClient() {
  try {
    if (Platform.isIOS || Platform.isMacOS) {
      return CupertinoClient.defaultSessionConfiguration();
    }
  } catch (_) {}
  return http.Client();
}

/// The Reels API rejects Windows' native HTTP fingerprint while accepting a
/// normal browser request. Use WebView2 for the API navigation on Windows;
/// its Chromium network stack matches the browser request that the service
/// accepts. The controller is headless and shared to avoid starting a browser
/// for each page of reels.
class _WindowsReelsBrowser {
  static WebviewController? _controller;
  static Future<void>? _initializing;
  static Future<void> _queue = Future<void>.value();

  static Future<List<ReelItem>> fetch(Uri uri) {
    final result = Completer<List<ReelItem>>();
    _queue = _queue.then((_) async {
      try {
        try {
          result.complete(await _fetch(uri));
        } catch (_) {
          // A newly launched WebView2 can occasionally remain on about:blank
          // after its first navigation. Recreate it once before falling back
          // to the native HTTP path.
          await _reset();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          result.complete(await _fetch(uri));
        }
      } catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint('[REELS] Windows browser fetch failed: $error');
        }
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  static Future<void> _reset() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.dispose();
    } catch (_) {}
  }

  static Future<List<ReelItem>> _fetch(Uri uri) async {
    var controller = _controller;
    if (controller == null) {
      final initializing = _initializing ??= () async {
        final browser = WebviewController();
        await browser.initialize();
        await browser.setSize(const Size(1280, 720));
        await browser.setDevToolsEnabled(false);
        _controller = browser;
      }();
      try {
        await initializing.timeout(const Duration(seconds: 20));
      } finally {
        if (identical(_initializing, initializing)) _initializing = null;
      }
      controller = _controller;
    }
    if (controller == null) {
      throw const HttpException('Windows browser could not be initialized.');
    }

    await controller.loadUrl(uri.toString());
    final deadline = DateTime.now().add(const Duration(seconds: 24));
    while (DateTime.now().isBefore(deadline)) {
      dynamic content;
      try {
        content = await controller.executeScript(
          'document.body ? document.body.innerText : ""',
        );
      } catch (_) {
        // Navigation may still be committing its document after loadUrl
        // returns. Keep polling until WebView2 exposes the response body.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        continue;
      }
      if (content is String) {
        final text = content.trim();
        if (text.startsWith('{') || text.startsWith('[')) {
          final decoded = jsonDecode(text);
          if (decoded is Map &&
              decoded['code'] != null &&
              decoded['code'] != 200) {
            throw const FormatException(
                'Reels service returned an error response.');
          }
          return parseReels(decoded);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    throw TimeoutException('Windows browser timed out fetching Reels.');
  }
}

/// Android WebView sends the Reels request through Chromium rather than
/// Dart's native HTTP stack, which can be rejected by the video service.
class _AndroidReelsBrowser {
  static const MethodChannel _channel =
      MethodChannel('com.tv.watch_tube/reels_browser');

  static Future<List<ReelItem>> fetch(Uri uri) async {
    final body = await _channel.invokeMethod<String>('fetchReels', {
      'url': uri.toString(),
      'headers': const {
        'Accept': 'application/json',
        'Origin': 'https://tik.porn',
        'Referer': 'https://tik.porn/',
      },
    }).timeout(const Duration(seconds: 28));
    if (body == null || body.isEmpty) {
      throw const HttpException('Android browser returned an empty response.');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['code'] != null && decoded['code'] != 200) {
      throw const FormatException('Reels service returned an error response.');
    }
    return parseReels(decoded);
  }
}

class _ReelsMethodNotAllowed implements Exception {
  const _ReelsMethodNotAllowed();
}

class _ReelsHttpFailure implements Exception {
  const _ReelsHttpFailure(this.statusCode, {this.retryAfter});
  final int statusCode;
  final Duration? retryAfter;
}

Uri _validatedReelsApiUri() {
  final uri = Uri.tryParse(_kApiUrl);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'REELS_API_URL must be a valid HTTP or HTTPS URL.',
    );
  }
  return uri;
}

class ReelsRepository {
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  final http.Client _client = _makeClient();

  static final Uri _api = _validatedReelsApiUri();
  static const Map<String, String> _headers = {
    'User-Agent': _kUserAgent,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'Origin': 'https://tik.porn',
    'Referer': 'https://tik.porn/',
  };

  Future<List<ReelItem>> _post(int amount) async {
    final req = http.Request('POST', _api)
      ..headers.addAll(_headers)
      ..bodyBytes = utf8.encode(
        jsonEncode({
          'amount': amount,
          'filter': [],
          'sfw_mode': _kReelsSfwMode ? 1 : 0,
          'forcerand': false,
          'first_chunk': false,
        }),
      );
    final res = await _sendBounded(req);
    return _decode(res);
  }

  Future<List<ReelItem>> _getOnce() async {
    if (Platform.isWindows) return _WindowsReelsBrowser.fetch(_api);
    if (Platform.isAndroid) return _AndroidReelsBrowser.fetch(_api);
    final req = http.Request('GET', _api)
      ..headers.addAll(const {
        'User-Agent': _kUserAgent,
        'Accept': 'application/json',
        'Origin': 'https://tik.porn',
        'Referer': 'https://tik.porn/',
      });
    return _decode(await _sendBounded(req));
  }

  Future<http.Response> _sendBounded(http.Request request) async {
    const maxResponseBytes = 6 * 1024 * 1024;
    final response =
        await _client.send(request).timeout(const Duration(seconds: 20));
    if (response.contentLength != null &&
        response.contentLength! > maxResponseBytes) {
      await response.stream.drain<void>().timeout(
            const Duration(seconds: 3),
            onTimeout: () {},
          );
      throw const FormatException('Reels response is too large.');
    }
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 24),
    )) {
      received += chunk.length;
      if (received > maxResponseBytes) {
        throw const FormatException('Reels response is too large.');
      }
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  Duration? _retryAfter(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds.clamp(0, 6).toInt());
    }
    DateTime? date = DateTime.tryParse(value.trim());
    if (date == null) {
      try {
        date = HttpDate.parse(value.trim());
      } catch (_) {}
    }
    if (date == null) return null;
    final remaining = date.difference(DateTime.now());
    if (remaining.isNegative) return Duration.zero;
    return remaining > const Duration(seconds: 6)
        ? const Duration(seconds: 6)
        : remaining;
  }

  List<ReelItem> _decode(http.Response res) {
    if (res.statusCode == 405 || res.statusCode == 501) {
      throw const _ReelsMethodNotAllowed();
    }
    if (res.statusCode != 200) {
      throw _ReelsHttpFailure(
        res.statusCode,
        retryAfter: _retryAfter(res.headers['retry-after']),
      );
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is Map && json['code'] != null && json['code'] != 200) {
      throw const FormatException('Reels service returned an error response.');
    }
    return parseReels(json);
  }

  Future<List<ReelItem>> _fetch(int amount) async {
    // The API's GET endpoint returns the resolved mp4/hls URLs used by the
    // player. Use it first; POST is retained as a compatibility fallback.
    // curl.exe is tried first on Windows so the request does not depend on
    // WebView2's profile, runtime initialization, or an offscreen window.
    if (Platform.isWindows) {
      try {
        final resolved = await _getWithWindowsCurl();
        if (resolved.isNotEmpty) return resolved;
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
              '[REELS] Windows curl fallback failed: ${error.runtimeType}');
        }
      }
    }
    try {
      final resolved = await _getOnce();
      if (resolved.isNotEmpty) return resolved;
    } catch (_) {}

    const retryableStatuses = <int>{408, 425, 429, 500, 502, 503, 504};
    for (var attempt = 0; attempt < 2; attempt++) {
      Duration? retryAfter;
      try {
        return await _post(amount);
      } on _ReelsMethodNotAllowed {
        return _getOnce();
      } on _ReelsHttpFailure catch (error) {
        if (!retryableStatuses.contains(error.statusCode) || attempt == 1) {
          rethrow;
        }
        retryAfter = error.retryAfter;
      } on SocketException {
        if (attempt == 1) rethrow;
      } on HandshakeException {
        if (attempt == 1) rethrow;
      } on http.ClientException {
        if (attempt == 1) rethrow;
      } on TimeoutException {
        if (attempt == 1) rethrow;
      }
      await Future<void>.delayed(
        retryAfter ?? Duration(milliseconds: 500 * (attempt + 1)),
      );
    }
    return _post(amount);
  }

  Future<List<ReelItem>> _getWithWindowsCurl() async {
    final result = await Process.run(
      'curl.exe',
      [
        '--fail',
        '--location',
        '--silent',
        '--show-error',
        '--max-time',
        '20',
        '--max-filesize',
        '${6 * 1024 * 1024}',
        '-H',
        'User-Agent: $_kUserAgent',
        '-H',
        'Accept: application/json',
        '-H',
        'Origin: https://tik.porn',
        '-H',
        'Referer: https://tik.porn/',
        _api.toString(),
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 22));

    if (result.exitCode != 0) {
      throw HttpException('curl.exe exited with code ${result.exitCode}.');
    }
    final body = result.stdout as String;
    if (utf8.encode(body).length > 6 * 1024 * 1024) {
      throw const FormatException('Reels response is too large.');
    }
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['code'] != null && decoded['code'] != 200) {
      throw const FormatException('Reels service returned an error response.');
    }
    return parseReels(decoded);
  }

  Future<List<ReelItem>> nextBatch(int amount) async {
    final fresh = <ReelItem>[];
    var emptyRounds = 0;
    var rounds = 0;
    while (fresh.length < amount &&
        rounds < 4 &&
        emptyRounds < _kMaxRefetchTries) {
      rounds++;
      final fetched = await _fetch(amount - fresh.length);
      var added = 0;
      for (final item in fetched) {
        final idKey = 'id:${item.id}';
        final urlKey = 'url:${item.videoUrl}';
        if (_seen.contains(idKey) || _seen.contains(urlKey)) continue;
        _seen
          ..add(idKey)
          ..add(urlKey);
        fresh.add(item);
        added++;
      }
      while (_seen.length > 1200) {
        _seen.remove(_seen.first);
      }
      emptyRounds = added == 0 ? emptyRounds + 1 : 0;
    }
    return fresh;
  }

  void dispose() => _client.close();
}

String _safeReelFileToken(String value) {
  // FNV-1a produces a stable filename without trusting API data as a path.
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String _compact(num n) => reelCompact(n);

String _clock(Duration d) => reelClock(d);

class ReelsPage extends StatefulWidget {
  const ReelsPage({super.key, required this.active, required this.bottomInset});

  /// True only while the Reels section is the visible one. When false the
  /// page keeps its state but pauses playback and releases spare decoders.
  final bool active;

  /// Safe-area spacing below controls; the tab bar is hidden while Reels is active.
  final double bottomInset;

  @override
  State<ReelsPage> createState() => _ReelsPageState();
}

class _ReelsPageState extends State<ReelsPage> with WidgetsBindingObserver {
  final ReelsRepository _repo = ReelsRepository();
  final http.Client _media = _makeClient();
  final PageController _pager = PageController(viewportFraction: 1.0);
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'Reels keyboard');
  final List<ReelItem> _items = <ReelItem>[];
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, _ReelPlaybackState> _reelStates = <int, _ReelPlaybackState>{};
  final Map<int, DateTime> _analyticsWatchStarted = <int, DateTime>{};
  final Set<String> _analyticsPlayedReels = <String>{};
  final Map<VideoPlayerController, VoidCallback> _controllerListeners = {};
  final Map<VideoPlayerController, Future<void>> _initializations = {};
  Future<void> _disposeTail = Future<void>.value();

  final ValueNotifier<Map<String, double>> _saving =
      ValueNotifier<Map<String, double>>(const {});

  bool _loading = false;
  bool _resumeOnForeground = false;
  bool _syncPending = false;
  bool _trimming = false;
  bool _exhausted = false;
  bool _muted = false;
  bool _clear = false;
  String? _error;
  int _current = 0;
  int? _pendingKeyboardPage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clear = LocalStore.readBool(_kClearKey, fallback: false);
    if (widget.active) {
      _focusForKeyboard();
      _claimPlayback();
      unawaited(_loadMore(first: true));
    }
  }

  void _claimPlayback() {
    unawaited(PreviewManager.instance.stopAndWait());
    unawaited(MiniPlayer.instance.close());
  }

  @override
  void didUpdateWidget(covariant ReelsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    if (widget.active) {
      _focusForKeyboard();
      _claimPlayback();
      if (_items.isEmpty && !_loading && !_exhausted) {
        unawaited(_loadMore(first: true));
      } else if (_items.isNotEmpty) {
        _syncControllers(_current);
      }
    } else {
      _pauseForLeaving();
    }
  }

  void _focusForKeyboard() {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _keyboardFocus.requestFocus();
    });
  }

  /// Leaving the Reels section: silence the current reel and free the spare
  /// decoder so the rest of the app has the memory back.
  void _pauseForLeaving() {
    _stopReelAnalytics(_current);
    for (final entry in _controllers.entries.toList()) {
      final controller = entry.value;
      if (controller.value.isInitialized) {
        unawaited(controller.pause());
        unawaited(controller.setVolume(0));
        unawaited(controller.setPlaybackSpeed(1));
      }
      if (entry.key != _current) _evictController(entry.key);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _controllers.values) {
      final listener = _controllerListeners.remove(controller);
      if (listener != null) controller.removeListener(listener);
      unawaited(_disposeReelController(controller));
    }
    _controllers.clear();
    _pager.dispose();
    _keyboardFocus.dispose();
    _repo.dispose();
    _media.close();
    _saving.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controllers[_current];
    if (state == AppLifecycleState.resumed) {
      if (c != null &&
          c.value.isInitialized &&
          _resumeOnForeground &&
          widget.active) {
        unawaited(c.play());
      }
      _resumeOnForeground = false;
      if (widget.active) _ensureNeighbors();
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (c != null && c.value.isInitialized && c.value.isPlaying) {
        _resumeOnForeground = true;
        unawaited(c.pause());
      }
      // Release the speculative decoder while the app is in the background.
      for (final index in _controllers.keys.toList()) {
        if (index != _current) _evictController(index);
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    // Keep only the visible decoder alive. The next reel can be prepared again
    // when the user returns to active browsing.
    for (final index in _controllers.keys.toList()) {
      if (index != _current) _evictController(index);
    }
  }

  Future<void> _loadMore({bool first = false}) async {
    // Reels pages are kept alive by the tab host. Do not fetch or prepare
    // media while this page is only an off-screen tab preview.
    if (!widget.active || _loading || _exhausted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final batch = await _repo.nextBatch(first ? _kFirstBatch : _kNextBatch);
      if (!mounted) return;
      setState(() {
        _items.addAll(batch);
        if (batch.isEmpty) _exhausted = true;
        _loading = false;
      });
      if (_items.isEmpty || !widget.active) return;
      if (first) {
        _syncControllers(0);
      } else {
        _ensureNeighbors();
      }
      final pendingPage = _pendingKeyboardPage;
      if (pendingPage != null) {
        if (pendingPage < _items.length && widget.active) {
          _pendingKeyboardPage = null;
          unawaited(
            _pager.animateToPage(
              pendingPage,
              duration: Motion.scroll,
              curve: Motion.curve,
            ),
          );
        } else if (_exhausted) {
          _pendingKeyboardPage = null;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[REELS] load failed: ${e.runtimeType}');
      if (!mounted) return;
      setState(() {
        _error = describeError(e, subject: 'reels').message;
        _loading = false;
        _pendingKeyboardPage = null;
      });
    }
  }

  bool _ownsController(int index, VideoPlayerController controller) =>
      mounted && identical(_controllers[index], controller);

  void _attachControllerListener(VideoPlayerController controller) {
    void listener() => _syncControllerState(controller);
    _controllerListeners[controller] = listener;
    controller.addListener(listener);
  }

  void _syncControllerState(VideoPlayerController controller) {
    if (!mounted) return;
    int? index;
    for (final entry in _controllers.entries) {
      if (identical(entry.value, controller)) {
        index = entry.key;
        break;
      }
    }
    if (index == null) return;
    final value = controller.value;
    final previous = _reelStates[index] ?? _ReelPlaybackState.idle;
    if (previous == _ReelPlaybackState.retrying && !value.isInitialized) {
      return;
    }
    final next = value.hasError
        ? _ReelPlaybackState.failed
        : !value.isInitialized
            ? _ReelPlaybackState.loading
            : value.isBuffering
                ? _ReelPlaybackState.buffering
                : value.isPlaying
                    ? _ReelPlaybackState.playing
                    : _ReelPlaybackState.paused;
    if (index == _current) {
      if (next == _ReelPlaybackState.playing &&
          !_analyticsWatchStarted.containsKey(index)) {
        final id = _items[index].id;
        final resumed = !_analyticsPlayedReels.add(id);
        _analyticsWatchStarted[index] = DateTime.now();
        if (resumed) {
          AnalyticsService.instance.trackVideoResume(id, source: 'reels');
        } else {
          AnalyticsService.instance.trackVideoPlay(id, source: 'reels');
        }
      } else if (next == _ReelPlaybackState.paused &&
          _analyticsWatchStarted.containsKey(index)) {
        _stopReelAnalytics(index);
      }
    }
    if (next == previous) return;
    _reelStates[index] = next;
    setState(() {});
  }

  void _stopReelAnalytics(int index) {
    if (index < 0 || index >= _items.length) return;
    final startedAt = _analyticsWatchStarted.remove(index);
    if (startedAt == null) return;
    final id = _items[index].id;
    AnalyticsService.instance.trackVideoPause(id, source: 'reels');
    final watched = DateTime.now().difference(startedAt);
    if (watched >= const Duration(seconds: 1)) {
      AnalyticsService.instance.trackVideoWatchDuration(
        id,
        watched,
        source: 'reels',
      );
    }
  }

  Future<void> _disposeReelController(VideoPlayerController controller) {
    // Serialize native AVPlayer teardown. Rapid swipes otherwise let old
    // players overlap their disposal with initialization of several new ones.
    final disposal = _disposeTail.then((_) async {
      // Never tear down AVPlayer while initialize() is still configuring it.
      // Wait for that operation first, then release the native decoder.
      final initialization = _initializations[controller];
      if (initialization != null) {
        try {
          await initialization.timeout(const Duration(seconds: 30));
        } catch (_) {}
      }
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.dispose().timeout(const Duration(seconds: 4));
      } catch (_) {}
    });
    _disposeTail = disposal;
    return disposal;
  }

  void _evictController(int index) {
    final controller = _controllers.remove(index);
    _reelStates.remove(index);
    if (controller != null) {
      final listener = _controllerListeners.remove(controller);
      if (listener != null) controller.removeListener(listener);
      unawaited(_disposeReelController(controller));
    }
  }

  VideoPlayerController _build(String url, int index, {String? fallback}) {
    if (_reelStates[index] != _ReelPlaybackState.retrying) {
      _reelStates[index] = _ReelPlaybackState.loading;
    }
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: _kMediaHeaders,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _attachControllerListener(controller);

    final initialization = () async {
      try {
        // Let evicted native players finish teardown before allocating another
        // decoder. This is especially important on the iPhone XS memory budget.
        await _disposeTail;
        if (!_ownsController(index, controller)) return;
        await controller.setLooping(true);
        await controller.initialize().timeout(const Duration(seconds: 28));
        if (!_ownsController(index, controller)) return;
        await controller.setVolume(
          index == _current && !_muted && widget.active ? 1 : 0,
        );
        if (index == _current && widget.active) await controller.play();
        _syncControllerState(controller);
        if (mounted) setState(() {});
      } catch (error) {
        if (!_ownsController(index, controller)) return;
        // Remove failed controllers even when no alternate URL exists, so a
        // later rebuild can retry rather than retaining a broken decoder.
        _controllers.remove(index);
        final listener = _controllerListeners.remove(controller);
        if (listener != null) controller.removeListener(listener);
        unawaited(_disposeReelController(controller));
        if (fallback != null) {
          _reelStates[index] = _ReelPlaybackState.retrying;
          _controllers[index] = _build(fallback, index);
        } else {
          _reelStates[index] = _ReelPlaybackState.failed;
        }
        if (mounted) setState(() {});
        if (kDebugMode) {
          debugPrint('[REELS] controller init failed: ${error.runtimeType}');
        }
      }
    }();
    _initializations[controller] = initialization;
    unawaited(
      initialization.whenComplete(() {
        if (identical(_initializations[controller], initialization)) {
          _initializations.remove(controller);
        }
      }),
    );
    return controller;
  }

  VideoPlayerController _controllerFor(int index) {
    return _controllers.putIfAbsent(index, () {
      final item = _items[index];
      return _build(item.videoUrl, index, fallback: item.fallbackUrl);
    });
  }

  void _retry(int index) {
    if (index < 0 || index >= _items.length) return;
    _evictController(index);
    _reelStates[index] = _ReelPlaybackState.retrying;
    _controllerFor(index);
    if (mounted) setState(() {});
  }

  void _ensureNeighbors() {
    _syncControllers(_current);
  }

  void _syncControllers(int index) {
    if (!widget.active) return;
    final keep = <int>{index};
    // A second Windows video decoder competes with the active texture for
    // hardware resources and causes visible frame drops. Load neighbors on
    // mobile, where preloading improves swipe transitions without that cost.
    if (defaultTargetPlatform != TargetPlatform.windows) {
      keep.add(index + 1);
    }
    keep.removeWhere((i) => i < 0 || i >= _items.length);
    for (final i in _controllers.keys.toList()) {
      if (!keep.contains(i)) _evictController(i);
    }

    // Keep at most two AVPlayer instances: the visible reel and one neighbor.
    // Initialize the next item after the current one has had a head start.
    if (keep.contains(index)) _controllerFor(index);
    for (final entry in _controllers.entries) {
      final controller = entry.value;
      if (!controller.value.isInitialized) continue;
      if (entry.key == index) {
        unawaited(controller.setVolume(_muted || !widget.active ? 0 : 1));
        if (widget.active) {
          unawaited(controller.play());
        } else {
          unawaited(controller.pause());
        }
      } else {
        unawaited(controller.pause());
        unawaited(controller.setVolume(0));
        unawaited(controller.setPlaybackSpeed(1));
      }
    }

    final next = index + 1;
    if (keep.contains(next)) {
      Future<void>.delayed(_kNeighborPreloadDelay, () {
        if (!mounted || _current != index || !_controllers.containsKey(index)) {
          return;
        }
        if (_controllers.length < 2) _controllerFor(next);
      });
    }
    if (mounted) setState(() {});
  }

  void _onPageChanged(int index) {
    if (!widget.active) return;
    final previous = _current;
    _stopReelAnalytics(previous);
    _current = index;
    _syncPending = true;

    // Keep the outgoing texture through the transition. PageView can still
    // expose part of that page after onPageChanged fires at the midpoint.
    // ScrollEnd sync releases it before another neighbor is preloaded.
    final keep = defaultTargetPlatform == TargetPlatform.windows
        ? <int>{index}
        : <int>{previous, index};
    for (final oldIndex in _controllers.keys.toList()) {
      if (!keep.contains(oldIndex)) _evictController(oldIndex);
    }

    final current = _controllerFor(index);
    if (current.value.isInitialized && widget.active) {
      unawaited(current.setVolume(_muted ? 0 : 1));
      unawaited(current.play());
    }
    for (final entry in _controllers.entries) {
      if (entry.key == index || !entry.value.value.isInitialized) continue;
      unawaited(entry.value.pause());
      unawaited(entry.value.setVolume(0));
      unawaited(entry.value.setPlaybackSpeed(1));
    }
    if (index >= _items.length - _kPreloadAhead) _loadMore();
    if (mounted) setState(() {});
  }

  void _movePage(int direction) {
    if (!_pager.hasClients || _items.isEmpty) return;
    final target = _current + direction;
    if (target < 0) return;
    if (target >= _items.length) {
      if (defaultTargetPlatform == TargetPlatform.windows && !_exhausted) {
        _pendingKeyboardPage = target;
      }
      if (!_loading && !_exhausted) unawaited(_loadMore());
      return;
    }
    unawaited(
      _pager.animateToPage(
        target,
        duration: Motion.scroll,
        curve: Motion.curve,
      ),
    );
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollEndNotification && n.depth == 0) {
      if (_syncPending) {
        _syncPending = false;
        _syncControllers(_current);
      }
      _trimOldReelsIfNeeded();
    }
    return false;
  }

  void _trimOldReelsIfNeeded() {
    if (!mounted ||
        _trimming ||
        _items.length <= _kMaxBufferedReels ||
        _current < _kReelTrimTrigger) {
      return;
    }

    final pending = <Future<void>>[];
    for (final controller in _controllers.values) {
      final initialization = _initializations[controller];
      if (initialization != null) pending.add(initialization);
    }
    if (pending.isNotEmpty) {
      _trimming = true;
      unawaited(
        Future.wait<void>(pending).whenComplete(() {
          _trimming = false;
          if (mounted) _trimOldReelsIfNeeded();
        }),
      );
      return;
    }

    final shift = _current - _kReelHistoryKeep;
    if (shift <= 0 || shift >= _items.length) return;

    final reindexed = <int, VideoPlayerController>{};
    for (final entry in _controllers.entries) {
      if (entry.key >= shift) {
        reindexed[entry.key - shift] = entry.value;
      } else {
        unawaited(_disposeReelController(entry.value));
      }
    }

    setState(() {
      _items.removeRange(0, shift);
      final shiftedStates = <int, _ReelPlaybackState>{
        for (final entry in _reelStates.entries)
          if (entry.key >= shift) entry.key - shift: entry.value,
      };
      _reelStates
        ..clear()
        ..addAll(shiftedStates);
      _controllers
        ..clear()
        ..addAll(reindexed);
      _current -= shift;
      _syncPending = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pager.hasClients) return;
      _pager.jumpToPage(_current);
    });
  }

  void _toggleLike(ReelItem item) {
    final liked = ReelFavorites.instance.toggle(item);
    Haptics.play(liked ? Haptic.medium : Haptic.light);
  }

  /// Double-tap: only ever adds to favorites (like Instagram). Returns true
  /// when the reel was newly added.
  bool _likeFromDoubleTap(ReelItem item) {
    final added = ReelFavorites.instance.like(item);
    if (added) Haptics.play(Haptic.medium);
    return added;
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    for (final c in _controllers.values) {
      if (c.value.isInitialized) {
        c.setVolume(_muted || !widget.active ? 0 : 1);
      }
    }
  }

  void _toggleClear() {
    Haptics.play(Haptic.selection);
    setState(() => _clear = !_clear);
    LocalStore.writeBool(_kClearKey, _clear);
  }

  void _toast(String message) => showToast(context, message);

  Video _videoOf(ReelItem item) => ReelFavorites.videoOf(item);

  bool _enqueue(ReelItem item, {bool silent = false}) {
    final url = item.downloadUrl ?? item.videoUrl;
    if (url.toLowerCase().contains('.m3u8')) {
      if (!silent) {
        _toast('This video is a stream and can\u2019t be downloaded.');
      }
      return false;
    }
    final store = DownloadStore.instance;
    final existing = store.item('reel_${item.id}');
    if (existing != null && existing.status == DownloadStatus.done) {
      if (!silent) _toast('Already in your downloads.');
      return false;
    }
    if (existing != null &&
        (existing.status == DownloadStatus.queued ||
            existing.status == DownloadStatus.downloading)) {
      if (!silent) _toast('Already downloading\u2026');
      return false;
    }
    final accepted = store.enqueueDirect(_videoOf(item), url);
    if (!accepted) {
      if (!silent) _toast('Download queue is full. Remove an old item first.');
      return false;
    }
    return true;
  }

  void _download(ReelItem item) {
    if (_enqueue(item)) _toast('Downloading\u2026');
  }

  Future<void> _showSaveMenu(ReelItem item) async {
    Haptics.play(Haptic.light);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheet).pop();
              _download(item);
            },
            child: const Text('Download to app'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheet).pop();
              _saveToPhotos(item);
            },
            child: const Text('Save to Photos'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheet).pop(),
          child: const Text('Cancel'),
        ),
      ),
    );
  }

  void _setSaving(String id, double? value) {
    if (!mounted) return;
    final next = Map<String, double>.of(_saving.value);
    if (value == null) {
      next.remove(id);
    } else {
      next[id] = value;
    }
    _saving.value = next;
  }

  Future<void> _saveToPhotos(ReelItem item) async {
    if (_saving.value.containsKey(item.id)) return;
    final url = item.downloadUrl ?? item.videoUrl;
    if (url.toLowerCase().contains('.m3u8')) {
      _toast('This video is a stream and can\u2019t be saved.');
      return;
    }
    _setSaving(item.id, -1);
    _toast('Saving to Photos\u2026');
    File? file;
    try {
      final dir = await getTemporaryDirectory();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('Invalid video URL.');
      }
      file = File('${dir.path}/reel_${_safeReelFileToken(item.id)}.mp4');
      final req = http.Request('GET', uri)..headers.addAll(_kMediaHeaders);
      final res = await _media.send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw HttpException('HTTP ${res.statusCode}');
      }
      const maxVideoBytes = 350 * 1024 * 1024;
      final total = res.contentLength ?? 0;
      if (total > maxVideoBytes) {
        await res.stream.drain<void>();
        throw const FormatException('Video is too large to save.');
      }
      var got = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in res.stream.timeout(
          const Duration(seconds: 35),
        )) {
          got += chunk.length;
          if (got > maxVideoBytes) {
            throw const FormatException('Video is too large to save.');
          }
          sink.add(chunk);
          if (total > 0) _setSaving(item.id, got / total);
        }
      } catch (_) {
        await sink.close();
        rethrow;
      }
      await sink.close();
      final result = await PhotoSaver.saveVideoToGallery(file.path);
      if (!mounted) return;
      if (result.denied) {
        _toast('Allow access to Photos in Settings to save videos.');
      } else if (result.saved > 0) {
        Haptics.play(Haptic.medium);
        _toast('Saved to Photos.');
      } else {
        _toast('Couldn\u2019t save the video.');
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[REELS] save failed: ${error.runtimeType}');
      if (mounted) _toast('Couldn\u2019t save the video.');
    } finally {
      _setSaving(item.id, null);
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = context.safe.top;
    final bottom = widget.bottomInset;
    return Focus(
      focusNode: _keyboardFocus,
      onKeyEvent: (node, event) {
        if (!widget.active ||
            defaultTargetPlatform != TargetPlatform.windows ||
            event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _movePage(1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _movePage(-1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_items.isNotEmpty)
              NotificationListener<ScrollNotification>(
                onNotification: _onScrollNotification,
                child: PageView.builder(
                  controller: _pager,
                  scrollDirection: Axis.vertical,
                  pageSnapping: true,
                  physics: const PageScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  padEnds: false,
                  clipBehavior: Clip.hardEdge,
                  itemCount: _items.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, i) {
                    final item = _items[i];
                    return RepaintBoundary(
                      child: _ReelView(
                        key: ValueKey(item.id),
                        item: item,
                        controller: _controllers[i],
                        playbackState:
                            _reelStates[i] ?? _ReelPlaybackState.idle,
                        isActive: widget.active && i == _current,
                        muted: _muted,
                        saving: _saving,
                        bottomInset: bottom,
                        clear: _clear,
                        onMute: _toggleMute,
                        onSaveMenu: () => _showSaveMenu(item),
                        onRetry: () => _retry(i),
                        onToggleLike: () => _toggleLike(item),
                        onDoubleTapLike: () => _likeFromDoubleTap(item),
                      ),
                    );
                  },
                ),
              )
            else if (_loading)
              const Center(
                child: CupertinoActivityIndicator(
                    radius: 14, color: Colors.white70),
              )
            else if (_error != null)
              _ErrorView(
                  message: _error!, onRetry: () => _loadMore(first: true))
            else
              Center(
                child: Text(
                  'No videos right now.',
                  style: AppText.body.copyWith(color: Colors.white70),
                ),
              ),
            // Soft top/bottom scrims keep the white UI readable on bright clips.
            IgnorePointer(
              child: AnimatedOpacity(
                duration: Motion.normal,
                opacity: _clear ? 0 : 1,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: top + 110,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x8C000000), Color(0x00000000)],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: bottom + 230,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Color(0xB3000000)],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null && _items.isNotEmpty)
              Positioned(
                bottom: bottom + 70,
                left: 16,
                right: 16,
                child: _ErrorView(message: _error!, onRetry: _loadMore),
              ),
            Positioned(
              top: top + 4,
              left: 8,
              right: 8,
              child: _ReelsTopBar(clear: _clear, onToggleClear: _toggleClear),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReelsTopBar extends StatelessWidget {
  const _ReelsTopBar({required this.clear, required this.onToggleClear});

  final bool clear;
  final VoidCallback onToggleClear;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 44),
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'For You',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                      shadows: [
                        Shadow(blurRadius: 10, color: Color(0x66000000))
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Pressable(
            semanticLabel: clear ? 'Show controls' : 'Hide controls',
            haptic: Haptic.selection,
            pressedScale: 0.85,
            onTap: onToggleClear,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                clear ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                color: Colors.white,
                size: 22,
                shadows: const [
                  Shadow(blurRadius: 12, color: Color(0x66000000))
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Keep skip gestures close to the edges so the middle has more room for likes.
const double _kSkipZone = 0.18;

class _ReelView extends StatefulWidget {
  const _ReelView({
    super.key,
    required this.item,
    required this.controller,
    required this.playbackState,
    required this.isActive,
    required this.muted,
    required this.saving,
    required this.bottomInset,
    required this.clear,
    required this.onMute,
    required this.onSaveMenu,
    required this.onRetry,
    required this.onToggleLike,
    required this.onDoubleTapLike,
  });

  final ReelItem item;
  final VideoPlayerController? controller;
  final _ReelPlaybackState playbackState;
  final bool isActive;
  final bool muted;
  final ValueListenable<Map<String, double>> saving;

  /// Space reserved for the iPhone home indicator beneath the action rail.
  final double bottomInset;
  final bool clear;
  final VoidCallback onMute;
  final VoidCallback onSaveMenu;
  final VoidCallback onRetry;
  final VoidCallback onToggleLike;
  final bool Function() onDoubleTapLike;

  @override
  State<_ReelView> createState() => _ReelViewState();
}

class _ReelViewState extends State<_ReelView>
    with SingleTickerProviderStateMixin {
  bool _fast = false;
  bool _longPressTriggered = false;
  bool _pointerMoved = false;
  bool _secondTapCandidate = false;
  bool _scrubbing = false;
  bool _playFeedbackVisible = false;
  bool _playFeedbackPaused = false;
  int? _activePointer;
  Offset? _pointerStart;
  DateTime? _lastTapTime;
  Timer? _longPressTimer;
  Timer? _singleTapTimer;
  Timer? _skipTimer;
  Timer? _playFeedbackTimer;

  int _skipDirection = 0;
  int _skipSeconds = 0;
  int _skipPulse = 0;
  bool _skipVisible = false;

  late final AnimationController _heart = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );
  Offset _heartAt = Offset.zero;
  double _heartTilt = 0;

  VideoPlayerController? get _c => widget.controller;
  bool get _ready => _c != null && _c!.value.isInitialized;

  @override
  void didUpdateWidget(covariant _ReelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) _resetGestures();
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _singleTapTimer?.cancel();
    _skipTimer?.cancel();
    _playFeedbackTimer?.cancel();
    _heart.dispose();
    super.dispose();
  }

  void _resetGestures() {
    _longPressTimer?.cancel();
    _singleTapTimer?.cancel();
    _activePointer = null;
    _pointerStart = null;
    _lastTapTime = null;
    _longPressTriggered = false;
    _secondTapCandidate = false;
    if (_fast) _setFast(false);
  }

  void _togglePlay() {
    final c = _c;
    if (!_ready || c == null) return;
    Haptics.play(Haptic.selection);
    if (c.value.isPlaying) {
      unawaited(c.pause());
      _playFeedbackPaused = true;
    } else {
      unawaited(c.play());
      _playFeedbackPaused = false;
    }
    setState(() => _playFeedbackVisible = true);
    _playFeedbackTimer?.cancel();
    _playFeedbackTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _playFeedbackVisible = false);
    });
  }

  Future<void> _skip(int direction) async {
    final c = _c;
    if (!_ready || c == null || !widget.isActive) return;
    final duration = c.value.duration;
    if (duration <= Duration.zero) return;
    final targetMs = (c.value.position.inMilliseconds + direction * 10000)
        .clamp(0, duration.inMilliseconds)
        .toInt();
    try {
      await c.seekTo(Duration(milliseconds: targetMs));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    Haptics.play(Haptic.selection);
    setState(() {
      final chained = _skipVisible && _skipDirection == direction;
      _skipSeconds = chained ? _skipSeconds + 10 : 10;
      _skipDirection = direction;
      _skipVisible = true;
      _skipPulse++;
    });
    _skipTimer?.cancel();
    _skipTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _skipVisible = false);
    });
  }

  void _likeAt(Offset position) {
    widget.onDoubleTapLike();
    _heartAt = position;
    _heartTilt = ((position.dx.toInt() % 3) - 1) * 0.16;
    _heart.forward(from: 0);
  }

  void _handleDoubleTap(Offset position) {
    final width = MediaQuery.sizeOf(context).width;
    if (position.dx <= width * _kSkipZone) {
      unawaited(_skip(-1));
    } else if (position.dx >= width * (1 - _kSkipZone)) {
      unawaited(_skip(1));
    } else {
      _likeAt(position);
    }
  }

  void _setFast(bool on) {
    final c = _c;
    if (!_ready || c == null || _fast == on) return;
    if (on && !c.value.isPlaying) return;
    unawaited(c.setPlaybackSpeed(on ? 2 : 1).catchError((_) {}));
    if (on) Haptics.play(Haptic.medium);
    if (mounted) setState(() => _fast = on);
  }

  // Tap = play/pause, double tap = like (middle) or skip (edges),
  // press-and-hold = temporary 2x.
  void _onPointerDown(PointerDownEvent event) {
    if (!widget.isActive || _activePointer != null) return;

    final now = DateTime.now();
    final previousTap = _lastTapTime;
    _secondTapCandidate = previousTap != null &&
        now.difference(previousTap) <= _kReelDoubleTapWindow;

    if (_secondTapCandidate) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapTime = null;
    } else if (_singleTapTimer?.isActive ?? false) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _togglePlay();
    }

    _activePointer = event.pointer;
    _pointerStart = event.localPosition;
    _pointerMoved = false;
    _longPressTriggered = false;

    _longPressTimer?.cancel();
    _longPressTimer = Timer(_kReelLongPressDelay, () {
      if (!mounted || _activePointer != event.pointer || _pointerMoved) return;
      _longPressTriggered = true;
      _secondTapCandidate = false;
      _lastTapTime = null;
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _setFast(true);
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _activePointer || _pointerStart == null) return;
    if (!_pointerMoved &&
        (event.localPosition - _pointerStart!).distance > _kReelMoveSlop) {
      _pointerMoved = true;
      if (!_longPressTriggered) _longPressTimer?.cancel();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    _longPressTimer?.cancel();

    final moved = _pointerMoved;
    final held = _longPressTriggered;
    final secondTap = _secondTapCandidate;

    _activePointer = null;
    _pointerStart = null;
    _pointerMoved = false;
    _secondTapCandidate = false;
    _longPressTriggered = false;

    if (moved) {
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _lastTapTime = null;
      if (_fast) _setFast(false);
      return;
    }

    if (held) {
      _lastTapTime = null;
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      if (_fast) _setFast(false);
      return;
    }

    if (secondTap) {
      _lastTapTime = null;
      _singleTapTimer?.cancel();
      _singleTapTimer = null;
      _handleDoubleTap(event.localPosition);
      return;
    }

    _lastTapTime = DateTime.now();
    _singleTapTimer?.cancel();
    _singleTapTimer = Timer(_kReelDoubleTapWindow, () {
      _singleTapTimer = null;
      _lastTapTime = null;
      if (mounted) _togglePlay();
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointer) return;
    _resetGestures();
  }

  Widget _video(BuildContext context, VideoPlayerController c) {
    final size = c.value.size;
    if (size.isEmpty) return const SizedBox.shrink();
    return SizedBox.expand(
      child: ClipRect(
        child: FittedBox(
          // Preserve the source aspect ratio. The page underneath is black,
          // so portrait/landscape letterboxing looks intentional rather than
          // stretching or cropping the clip to fill the phone.
          fit: BoxFit.contain,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(c),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final c = _c;
    final ready = _ready;
    final bottom = widget.bottomInset;
    final hideUi = widget.clear || _scrubbing;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The video is fitted with BoxFit.contain. Keep the uncovered area
        // genuinely black (not a stretched thumbnail or translucent overlay).
        const ColoredBox(color: Colors.black),
        if (item.thumbUrl != null)
          Positioned.fill(
            child: AnimatedOpacity(
              opacity: ready &&
                      widget.playbackState != _ReelPlaybackState.buffering &&
                      widget.playbackState != _ReelPlaybackState.failed
                  ? 0
                  : 1,
              duration: Motion.fade,
              child: Image.network(
                item.thumbUrl!,
                fit: BoxFit.cover,
                cacheWidth: (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))
                    .round()
                    .clamp(128, 1080)
                    .toInt(),
                headers: _kMediaHeaders,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x16000000), Color(0x46000000)],
              ),
            ),
          ),
        ),

        Semantics(
          button: true,
          label: 'Video player',
          hint: 'Tap to pause or play. Double-tap the middle to like. '
              'Double-tap the left or right edge to rewind or skip 10 seconds. '
              'Press and hold for 2x speed.',
          onTap: _togglePlay,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (ready && c != null)
                  RepaintBoundary(child: _video(context, c)),
                if (ready &&
                    item.thumbUrl != null &&
                    (widget.playbackState == _ReelPlaybackState.buffering ||
                        widget.playbackState == _ReelPlaybackState.failed))
                  Positioned.fill(
                    child: Image.network(
                      item.thumbUrl!,
                      fit: BoxFit.cover,
                      cacheWidth: (MediaQuery.sizeOf(context).width *
                              MediaQuery.devicePixelRatioOf(context))
                          .round()
                          .clamp(128, 1080)
                          .toInt(),
                      headers: _kMediaHeaders,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (context, error, stackTrace) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                if (ready &&
                    (widget.playbackState == _ReelPlaybackState.buffering ||
                        widget.playbackState == _ReelPlaybackState.failed))
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x26000000), Color(0x59000000)],
                        ),
                      ),
                    ),
                  ),
                if (widget.playbackState == _ReelPlaybackState.failed ||
                    (c != null && c.value.hasError))
                  _ReelErrorPanel(onRetry: widget.onRetry)
                else if (!ready)
                  const Center(
                    child: CupertinoActivityIndicator(
                      radius: 12,
                      color: Colors.white,
                    ),
                  ),
                if (ready &&
                    c != null &&
                    widget.isActive &&
                    widget.playbackState != _ReelPlaybackState.failed)
                  _StallSpinner(key: ObjectKey(c), controller: c),
                if (ready && c != null)
                  IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        duration: Motion.quick,
                        opacity: _playFeedbackVisible ? 1 : 0,
                        child: AnimatedScale(
                          duration: Motion.quick,
                          curve: Curves.easeOut,
                          scale: _playFeedbackVisible ? 1 : 0.86,
                          child: Container(
                            width: 58,
                            height: 58,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0x59000000),
                            ),
                            child: Icon(
                              _playFeedbackPaused
                                  ? CupertinoIcons.pause_fill
                                  : CupertinoIcons.play_fill,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Heart burst for double-tap likes.
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _heart,
              builder: (_, __) {
                final t = _heart.value;
                if (t == 0) return const SizedBox.shrink();
                final double scale;
                if (t < 0.28) {
                  scale = Curves.easeOutBack.transform(t / 0.28) * 1.15;
                } else if (t < 0.45) {
                  scale = 1.15 - 0.15 * ((t - 0.28) / 0.17);
                } else if (t < 0.72) {
                  scale = 1.0;
                } else {
                  scale = 1.0 + 0.35 * ((t - 0.72) / 0.28);
                }
                final opacity = t < 0.72 ? 1.0 : 1.0 - (t - 0.72) / 0.28;
                return Stack(
                  children: [
                    Positioned(
                      left: _heartAt.dx - 55,
                      top: _heartAt.dy - 75,
                      child: Opacity(
                        opacity: opacity.clamp(0.0, 1.0).toDouble(),
                        child: Transform.rotate(
                          angle: _heartTilt,
                          child: Transform.scale(
                            scale: scale,
                            child: const Icon(
                              Icons.favorite_rounded,
                              size: 110,
                              color: AppColors.accent,
                              shadows: [
                                Shadow(
                                  blurRadius: 28,
                                  color: Color(0x80000000),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),

        _SkipFeedback(
          visible: _skipVisible,
          direction: _skipDirection,
          seconds: _skipSeconds,
          pulse: _skipPulse,
        ),

        Positioned(
          left: 16,
          right: 84,
          bottom: bottom + 52,
          child: _UiFade(hidden: hideUi, child: _InfoBlock(item: item)),
        ),

        Positioned(
          right: 6,
          bottom: bottom + 52,
          child: _UiFade(
            hidden: hideUi,
            child: _ActionRail(
              item: item,
              muted: widget.muted,
              saving: widget.saving,
              onToggleLike: widget.onToggleLike,
              onMute: widget.onMute,
              onSaveMenu: widget.onSaveMenu,
            ),
          ),
        ),

        Positioned(
          top: context.safe.top + 58,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                duration: Motion.quick,
                opacity: _fast ? 1 : 0,
                child: AnimatedScale(
                  duration: Motion.normal,
                  curve: Curves.easeOutBack,
                  scale: _fast ? 1 : 0.85,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x8C000000),
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.fast_forward_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        SizedBox(width: 5),
                        Text(
                          '2x',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        if (ready && c != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottom + 2,
            child: _UiFade(
              hidden: widget.clear,
              child: _ReelProgressBar(
                key: ObjectKey(c),
                controller: c,
                onScrub: (value) {
                  if (_scrubbing != value && mounted) {
                    setState(() => _scrubbing = value);
                  }
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact skip feedback stays close to the tapped edge. It deliberately
/// avoids the full-height half-screen disc so double-tap likes have room.
class _SkipFeedback extends StatelessWidget {
  const _SkipFeedback({
    required this.visible,
    required this.direction,
    required this.seconds,
    required this.pulse,
  });

  final bool visible;
  final int direction;
  final int seconds;
  final int pulse;

  @override
  Widget build(BuildContext context) {
    final forward = direction >= 0;
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          opacity: visible ? 1 : 0,
          child: Align(
            alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(
                left: forward ? 0 : 18,
                right: forward ? 18 : 0,
              ),
              child: TweenAnimationBuilder<double>(
                key: ValueKey<int>(pulse),
                tween: Tween<double>(begin: 0.88, end: 1),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                builder: (_, scale, child) => Transform.scale(
                  scale: scale,
                  child: child,
                ),
                child: Container(
                  width: 78,
                  height: 70,
                  decoration: BoxDecoration(
                    color: const Color(0xB81A1A1D),
                    borderRadius: BorderRadius.circular(21),
                    border: Border.all(
                      color: const Color(0x33FFFFFF),
                      width: 0.8,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 14,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        forward
                            ? Icons.forward_10_rounded
                            : Icons.replay_10_rounded,
                        color: Colors.white,
                        size: 29,
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '${forward ? '+' : '−'}${seconds}s',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({required this.item});

  final ReelItem item;

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(blurRadius: 10, color: Color(0x99000000))];
    final title = item.title.isEmpty ? 'Untitled' : item.title;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.author.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 34,
                height: 34,
                padding: const EdgeInsets.all(1.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.4),
                ),
                child: ClipOval(
                  child: ColoredBox(
                    color: const Color(0xFF30333B),
                    child: item.avatarUrl == null
                        ? const Icon(
                            CupertinoIcons.person_fill,
                            size: 18,
                            color: Colors.white70,
                          )
                        : Image.network(
                            item.avatarUrl!,
                            fit: BoxFit.cover,
                            cacheWidth: 108,
                            headers: _kMediaHeaders,
                            errorBuilder: (_, __, ___) => const Icon(
                              CupertinoIcons.person_fill,
                              size: 18,
                              color: Colors.white70,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  '@${item.author}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    shadows: shadow,
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: 10),
        ExpandableText(
          title,
          collapsedLines: 2,
          maxExpandedHeight: MediaQuery.sizeOf(context).height * 0.3,
          style: AppText.body.copyWith(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
            height: 1.32,
            shadows: shadow,
          ),
        ),
        if (item.tags.isNotEmpty) ...[
          const SizedBox(height: 6),
          IgnorePointer(
            child: Wrap(
              spacing: 10,
              runSpacing: 2,
              children: [
                for (final tag in item.tags.take(3))
                  Text(
                    '#$tag',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: Colors.white.withValues(alpha: 0.86),
                      fontWeight: FontWeight.w500,
                      shadows: shadow,
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        IgnorePointer(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.play_fill,
                size: 11,
                color: Colors.white70,
              ),
              const SizedBox(width: 4),
              Text(
                _compact(item.views),
                style: AppText.caption.copyWith(
                  color: Colors.white70,
                  shadows: shadow,
                ),
              ),
              if (item.durationSec > 0) ...[
                const SizedBox(width: 12),
                const Icon(CupertinoIcons.clock,
                    size: 12, color: Colors.white70),
                const SizedBox(width: 4),
                Text(
                  _clock(Duration(seconds: item.durationSec)),
                  style: AppText.caption.copyWith(
                    color: Colors.white70,
                    shadows: shadow,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.item,
    required this.muted,
    required this.saving,
    required this.onToggleLike,
    required this.onMute,
    required this.onSaveMenu,
  });

  final ReelItem item;
  final bool muted;
  final ValueListenable<Map<String, double>> saving;
  final VoidCallback onToggleLike;
  final VoidCallback onMute;
  final VoidCallback onSaveMenu;

  @override
  Widget build(BuildContext context) {
    final downloadId = 'reel_${item.id}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            FavoritesStore.instance,
            RemoteConfigService.instance,
          ]),
          builder: (_, __) {
            final liked = ReelFavorites.instance.isLiked(item.id);
            final enabled =
                RemoteConfigService.instance.isFeatureEnabled('favorites');
            final count = item.likes;
            return _RailButton(
              icon: liked ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
              iconColor: liked ? AppColors.accent : Colors.white,
              size: 33,
              label: _compact(count),
              pop: liked,
              haptic: Haptic.none,
              onTap: enabled ? onToggleLike : null,
            );
          },
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<Map<String, double>>(
          valueListenable: saving,
          builder: (_, map, __) {
            final saved = map[item.id];
            if (saved != null) {
              return _RailButton(
                icon: CupertinoIcons.arrow_down_to_line,
                label: 'Saving',
                progress: saved,
                onTap: onSaveMenu,
              );
            }
            return ListenableBuilder(
              listenable: DownloadStore.instance,
              builder: (_, __) {
                final entry = DownloadStore.instance.item(downloadId);
                if (entry == null) {
                  return _RailButton(
                    icon: CupertinoIcons.arrow_down_to_line,
                    label: 'Save',
                    onTap: onSaveMenu,
                  );
                }
                if (entry.status == DownloadStatus.done) {
                  return _RailButton(
                    icon: CupertinoIcons.check_mark_circled,
                    iconColor: AppColors.accent,
                    label: 'Saved',
                    onTap: onSaveMenu,
                  );
                }
                if (entry.status == DownloadStatus.failed ||
                    entry.status == DownloadStatus.paused) {
                  return _RailButton(
                    icon: CupertinoIcons.refresh,
                    label: 'Retry',
                    onTap: onSaveMenu,
                  );
                }
                return ValueListenableBuilder<int>(
                  valueListenable: entry.bytes,
                  builder: (_, __, ___) {
                    final p = entry.progress;
                    return _RailButton(
                      icon: CupertinoIcons.arrow_down_to_line,
                      label: p == null ? 'Queued' : '${(p * 100).round()}%',
                      progress: p ?? -1,
                      onTap: onSaveMenu,
                    );
                  },
                );
              },
            );
          },
        ),
        const SizedBox(height: 12),
        _RailButton(
          icon: muted
              ? CupertinoIcons.speaker_slash_fill
              : CupertinoIcons.speaker_2_fill,
          label: muted ? 'Muted' : 'Sound',
          onTap: onMute,
        ),
      ],
    );
  }
}

class _UiFade extends StatelessWidget {
  const _UiFade({required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        duration: Motion.normal,
        curve: Motion.curve,
        opacity: hidden ? 0 : 1,
        child: child,
      ),
    );
  }
}

class _StallSpinner extends StatefulWidget {
  const _StallSpinner({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  State<_StallSpinner> createState() => _StallSpinnerState();
}

class _StallSpinnerState extends State<_StallSpinner> {
  Timer? _timer;
  Duration _lastPos = Duration.zero;
  DateTime _lastMove = DateTime.now();
  bool _show = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onValue);
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onValue);
    _timer?.cancel();
    super.dispose();
  }

  void _onValue() {
    final pos = widget.controller.value.position;
    if (pos != _lastPos) {
      _lastPos = pos;
      _lastMove = DateTime.now();
      if (_show && mounted) setState(() => _show = false);
    }
  }

  void _tick() {
    if (!mounted) return;
    final v = widget.controller.value;
    if (!v.isBuffering) {
      if (_show) setState(() => _show = false);
      return;
    }
    final stalled = v.isInitialized &&
        v.isPlaying &&
        v.isBuffering &&
        DateTime.now().difference(_lastMove) >
            const Duration(milliseconds: 700);
    if (stalled != _show) setState(() => _show = stalled);
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: Motion.normal,
        opacity: _show ? 1 : 0,
        child: const Center(
          child: CupertinoActivityIndicator(radius: 14, color: Colors.white),
        ),
      ),
    );
  }
}

/// Instagram-style action: a bare glyph with a soft shadow and a label.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor = Colors.white,
    this.size = 29,
    this.progress,
    this.pop,
    this.haptic = Haptic.light,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color iconColor;
  final double size;
  final double? progress;
  final bool? pop;
  final Haptic haptic;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      icon,
      color: onTap == null ? Colors.white54 : iconColor,
      size: size,
      shadows: const [Shadow(blurRadius: 14, color: Color(0x80000000))],
    );
    return Pressable(
      semanticLabel: label,
      onTap: onTap,
      haptic: haptic,
      pressedScale: 0.86,
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (progress != null)
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        value: progress! < 0 ? null : progress,
                        color: Colors.white,
                        backgroundColor: const Color(0x40FFFFFF),
                      ),
                    ),
                  pop == null ? glyph : _PopIcon(trigger: pop!, child: glyph),
                ],
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                height: 1.2,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 10, color: Color(0x99000000))],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plays a small "pop" whenever [trigger] flips (not on first build).
class _PopIcon extends StatefulWidget {
  const _PopIcon({required this.trigger, required this.child});

  final bool trigger;
  final Widget child;

  @override
  State<_PopIcon> createState() => _PopIconState();
}

class _PopIconState extends State<_PopIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  static final Animatable<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween<double>(begin: 1, end: 1.38).chain(
        CurveTween(curve: Curves.easeOut),
      ),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween<double>(begin: 1.38, end: 0.92).chain(
        CurveTween(curve: Curves.easeInOut),
      ),
      weight: 30,
    ),
    TweenSequenceItem(
      tween: Tween<double>(begin: 0.92, end: 1).chain(
        CurveTween(curve: Curves.easeOut),
      ),
      weight: 35,
    ),
  ]);

  @override
  void didUpdateWidget(covariant _PopIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) _ctl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _ctl.drive(_scale), child: widget.child);
  }
}

/// iOS-style scrubber with always-visible elapsed and total time labels.
class _ReelProgressBar extends StatefulWidget {
  const _ReelProgressBar({
    super.key,
    required this.controller,
    required this.onScrub,
  });

  final VideoPlayerController controller;
  final ValueChanged<bool> onScrub;

  @override
  State<_ReelProgressBar> createState() => _ReelProgressBarState();
}

class _ReelProgressBarState extends State<_ReelProgressBar> {
  bool _dragging = false;
  bool _wasPlaying = false;
  bool _showTimes = false;
  double _frac = 0;
  Timer? _timeTimer;

  VideoPlayerController get _c => widget.controller;

  void _showTimesBriefly() {
    _timeTimer?.cancel();
    if (!_showTimes) setState(() => _showTimes = true);
    _timeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && !_dragging) setState(() => _showTimes = false);
    });
  }

  @override
  void dispose() {
    _timeTimer?.cancel();
    super.dispose();
  }

  double _fracAt(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0).toDouble();

  void _start(double dx, double width) {
    _wasPlaying = _c.value.isPlaying;
    unawaited(_c.pause());
    Haptics.play(Haptic.selection);
    setState(() {
      _dragging = true;
      _frac = _fracAt(dx, width);
      _showTimes = true;
    });
    widget.onScrub(true);
  }

  void _update(double dx, double width) {
    setState(() => _frac = _fracAt(dx, width));
  }

  Future<void> _seekToFraction(double fraction, {bool resume = false}) async {
    final ms = _c.value.duration.inMilliseconds;
    if (ms <= 0) return;
    try {
      await _c.seekTo(
        Duration(milliseconds: (ms * fraction.clamp(0.0, 1.0)).round()),
      );
      if (resume && mounted) await _c.play();
    } catch (_) {}
  }

  void _end() {
    if (!_dragging) return;
    final fraction = _frac;
    final resume = _wasPlaying;
    setState(() => _dragging = false);
    widget.onScrub(false);
    _showTimesBriefly();
    unawaited(_seekToFraction(fraction, resume: resume));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => _start(d.localPosition.dx, width),
          onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, width),
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          onTapUp: (d) {
            final fraction = _fracAt(d.localPosition.dx, width);
            setState(() => _frac = fraction);
            _showTimesBriefly();
            unawaited(_seekToFraction(fraction));
          },
          child: SizedBox(
            height: 44,
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: _c,
              builder: (_, v, __) {
                final total = v.duration.inMilliseconds;
                final played = total <= 0
                    ? 0.0
                    : (v.position.inMilliseconds / total)
                        .clamp(0.0, 1.0)
                        .toDouble();
                final buffered = total <= 0 || v.buffered.isEmpty
                    ? 0.0
                    : (v.buffered.last.end.inMilliseconds / total)
                        .clamp(0.0, 1.0)
                        .toDouble();
                final shown = _dragging ? _frac : played;
                final position = _dragging
                    ? Duration(milliseconds: (total * _frac).round())
                    : v.position;
                final barHeight = _dragging ? 7.0 : 4.0;
                final thumb = _dragging ? 15.0 : 0.0;
                final thumbLeft = (width * shown - thumb / 2)
                    .clamp(0.0, width - thumb)
                    .toDouble();
                const timeStyle = TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.15,
                  fontFeatures: [FontFeature.tabularFigures()],
                  shadows: [Shadow(blurRadius: 8, color: Color(0xAA000000))],
                );

                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_showTimes || _dragging)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 1,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_clock(position), style: timeStyle),
                            Text(_clock(v.duration), style: timeStyle),
                          ],
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 7,
                      child: AnimatedContainer(
                        duration: Motion.quick,
                        curve: Motion.curve,
                        height: barHeight,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          color: const Color(0x66FFFFFF),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: buffered,
                                child: const ColoredBox(
                                  color: Color(0x99FFFFFF),
                                ),
                              ),
                              FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: shown.clamp(0.0, 1.0).toDouble(),
                                child: const ColoredBox(
                                  color: AppColors.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_dragging)
                      Positioned(
                        left: thumbLeft,
                        bottom: 1.5,
                        child: Container(
                          width: thumb,
                          height: thumb,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.65),
                                blurRadius: 12,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _ReelErrorPanel extends StatelessWidget {
  const _ReelErrorPanel({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final windowsDesktop = defaultTargetPlatform == TargetPlatform.windows;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.large),
            child: windowsDesktop
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B1D25),
                      border: Border.all(
                        color: const Color(0xFF454957),
                      ),
                      borderRadius: BorderRadius.circular(Radii.large),
                    ),
                    child: _reelErrorContent(),
                  )
                : BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xD91B1D25),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                        borderRadius: BorderRadius.circular(Radii.large),
                      ),
                      child: _reelErrorContent(),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _reelErrorContent() {
    return Padding(
      padding: const EdgeInsets.all(Gaps.md),
      child: Row(
        children: [
          const Icon(
            CupertinoIcons.exclamationmark_circle,
            color: Colors.white70,
            size: 22,
          ),
          const SizedBox(width: Gaps.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Unable to load video',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Check your connection and try again.',
                  style: TextStyle(
                    color: Color(0xFFD1D3D9),
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: Gaps.sm),
                AppButton(
                  label: 'Retry',
                  icon: CupertinoIcons.refresh,
                  style: AppButtonStyle.secondary,
                  onDark: true,
                  onPressed: onRetry,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gaps.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.wifi_exclamationmark, size: 26),
              const SizedBox(height: Gaps.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AppText.body,
              ),
              const SizedBox(height: Gaps.md),
              AppButton(
                label: 'Try again',
                icon: CupertinoIcons.refresh,
                style: AppButtonStyle.secondary,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
