import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart'
    show
        CupertinoIcons,
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        CupertinoActivityIndicator,
        showCupertinoModalPopup;
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'ads/age_gate.dart';
import 'app_theme.dart';
import 'content_source.dart';
import 'analytics_service.dart';
import 'download_store.dart';
import 'error_text.dart';
import 'favorites_store.dart';
import 'local_store.dart';
import 'mini_player.dart';
import 'native_bridge.dart';
import 'models.dart';
import 'photo_saver.dart';
import 'preview_manager.dart';
import 'reel_favorites.dart';
import 'reel_seen_store.dart';
import 'reels_repository.dart';
import 'xxx_follow_trans_reels.dart';
import 'xxx_follow_creator_page.dart';
import 'services/remote_config_service.dart';
import 'touch.dart';
import 'widgets/app_button.dart';
import 'widgets/dialogs.dart';
import 'widgets/expandable_text.dart';

const Map<String, String> _kMediaHeaders = kReelMediaHeaders;

Map<String, String> _headersForReel(ReelItem item) {
  final referer = item.mediaReferer;
  if (referer == null || referer.isEmpty) return _kMediaHeaders;
  final origin = Uri.tryParse(referer)?.origin;
  return <String, String>{
    ..._kMediaHeaders,
    'Referer': referer,
    if (origin != null) 'Origin': origin,
  };
}

const int _kFirstBatch = 12;
const int _kNextBatch = 12;
const int _kPreloadAhead = 2;
const int _kMaxBufferedReels = 96;
const int _kReelHistoryKeep = 12;
const int _kReelTrimTrigger = 48;
const int _kMaxRefetchTries = 4;
const String _kClearKey = 'reels_clear_mode_v1';
const Duration _kReelDoubleTapWindow = Duration(milliseconds: 260);
const Duration _kReelLongPressDelay = Duration(milliseconds: 140);
const double _kReelMoveSlop = 14;

class _FastReelsPagePhysics extends PageScrollPhysics {
  const _FastReelsPagePhysics({super.parent});

  @override
  SpringDescription get spring => const SpringDescription(
        mass: 0.38,
        stiffness: 700,
        damping: 28,
      );

  @override
  _FastReelsPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _FastReelsPagePhysics(parent: buildParent(ancestor));
}

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

String _compact(num n) => reelCompact(n);

String _clock(Duration d) => reelClock(d);

class ReelsPage extends StatefulWidget {
  const ReelsPage({
    super.key,
    required this.active,
    required this.bottomInset,
    required this.source,
    this.initialItems,
    this.initialIndex = 0,
    this.initialItemsOnly = false,
    this.loadMoreInitialItems,
    this.hasMoreInitialItems,
    this.onExitToPrevious,
  });

  final bool active;

  final double bottomInset;
  final ContentSource source;
  final List<ReelItem>? initialItems;
  final int initialIndex;
  final bool initialItemsOnly;
  final Future<List<ReelItem>> Function()? loadMoreInitialItems;
  final bool Function()? hasMoreInitialItems;
  final VoidCallback? onExitToPrevious;

  @override
  State<ReelsPage> createState() => _ReelsPageState();
}

class _ReelsPageState extends State<ReelsPage> with WidgetsBindingObserver {
  late ReelsRepository _repo;
  final http.Client _media = makeReelsHttpClient();
  late final PageController _pager;
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'Reels keyboard');
  final _ReelRemote _remote = _ReelRemote();
  Timer? _okHold;
  bool _okHoldFired = false;
  DateTime _lastRemoteStep = DateTime.fromMillisecondsSinceEpoch(0);
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
  bool _initialLoadCompleted = false;
  int _initialLoadRetries = 0;
  late ReelSeenStore _seenStore;
  DateTime? _inactiveSince;
  bool _hasBeenActive = false;
  bool _refreshingSeenOnReturn = false;
  final LinkedHashSet<String> _loadedReelIds = LinkedHashSet<String>();
  final LinkedHashSet<String> _markedSeenThisSession =
      LinkedHashSet<String>();
  bool _resumeOnForeground = false;
  bool _reelScrollInProgress = false;
  bool _trimming = false;
  bool _exhausted = false;
  bool _muted = false;
  bool _clear = false;
  String? _error;
  int _current = 0;
  int? _pendingKeyboardPage;
  int? _pendingLoadPage;

  bool get _adShowing => false;

  @override
  void initState() {
    super.initState();
    _hasBeenActive = widget.active;
    _seenStore = ReelSeenStore(widget.source);
    _repo = ReelsRepository(
      source: widget.source,
      findPreviouslySeenIds: _seenStore.findSeenIds,
    );
    final supplied = widget.initialItems;
    if (supplied != null) {
      _initialLoadCompleted = true;
      final seenIds = <String>{};
      final seenUrls = <String>{};
      for (final item in supplied) {
        if (seenIds.add(item.id) && seenUrls.add(item.videoUrl)) {
          _items.add(item);
        }
      }
      _exhausted = widget.initialItemsOnly && widget.loadMoreInitialItems == null;
    }
    _current = _items.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _items.length - 1).toInt();
    _pager = PageController(
      viewportFraction: 1.0,
      initialPage: _current,
    );
    WidgetsBinding.instance.addObserver(this);
    _clear = LocalStore.readBool(_kClearKey, fallback: false);
    if (widget.active) {
      _reelScrollInProgress = false;
      _focusForKeyboard();
      _claimPlayback();
      if (_items.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.active) _syncControllers(_current);
        });
      } else if (!widget.initialItemsOnly) {
        unawaited(_loadMore(first: true));
      }
    }
  }

  void _claimPlayback() {
    unawaited(PreviewManager.instance.stopAndWait());
    unawaited(MiniPlayer.instance.close());
  }

  @override
  void didUpdateWidget(covariant ReelsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _resetForSourceChange();
    }
    if (oldWidget.active == widget.active) return;
    if (widget.active) {
      unawaited(NativeBridge.instance.acquireKeepScreenOn(this));
    } else {
      unawaited(NativeBridge.instance.releaseKeepScreenOn(this));
    }
    if (widget.active) {
      final away = _inactiveSince == null
          ? Duration.zero
          : DateTime.now().difference(_inactiveSince!);
      _inactiveSince = null;
      final returningToFeed = _hasBeenActive && away > const Duration(seconds: 25);
      _hasBeenActive = true;
      _reelScrollInProgress = false;
      _focusForKeyboard();
      _claimPlayback();
      if (_items.isEmpty && !_loading) {
        _exhausted = false;
        _initialLoadCompleted = false;
        _initialLoadRetries = 0;
        unawaited(_loadMore(first: true));
      } else if (_items.isNotEmpty &&
          returningToFeed &&
          !widget.initialItemsOnly) {
        unawaited(_resumeAtNextUnseenReel());
      } else if (_items.isNotEmpty) {
        _syncControllers(_current);
      }
    } else {
      _reelScrollInProgress = false;
      _inactiveSince ??= DateTime.now();
      _rememberCurrentReel();
      _pauseForLeaving();
    }
  }

  void _resetForSourceChange() {
    _stopReelAnalytics(_current);
    for (final controller in _controllers.values.toList()) {
      final listener = _controllerListeners.remove(controller);
      if (listener != null) controller.removeListener(listener);
      unawaited(_disposeReelController(controller));
    }
    _controllers.clear();
    _reelStates.clear();
    _analyticsWatchStarted.clear();
    _analyticsPlayedReels.clear();
    _repo.dispose();
    _seenStore = ReelSeenStore(widget.source);
    _loadedReelIds.clear();
    _markedSeenThisSession.clear();
    _repo = ReelsRepository(
      source: widget.source,
      findPreviouslySeenIds: _seenStore.findSeenIds,
    );
    _items.clear();
    _current = 0;
    _exhausted = false;
    _error = null;
    _loading = false;
    _initialLoadCompleted = false;
    _initialLoadRetries = 0;
    _pendingKeyboardPage = null;
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pager.hasClients) _pager.jumpToPage(0);
      });
    }
    if (widget.active) unawaited(_loadMore(first: true));
  }

  void _focusForKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _keyboardFocus.requestFocus();
    });
  }

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
    if (widget.active) {
      unawaited(NativeBridge.instance.releaseKeepScreenOn(this));
    }
    _rememberCurrentReel();
    unawaited(LocalStore.flush());
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _controllers.values) {
      final listener = _controllerListeners.remove(controller);
      if (listener != null) controller.removeListener(listener);
      unawaited(_disposeReelController(controller));
    }
    _controllers.clear();
    _pager.dispose();
    _okHold?.cancel();
    _remote.dispose();
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
          widget.active &&
          !_adShowing) {
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
      _rememberCurrentReel();
      unawaited(LocalStore.flush());
      if (c != null && c.value.isInitialized && c.value.isPlaying) {
        _resumeOnForeground = true;
        unawaited(c.pause());
      }
      for (final index in _controllers.keys.toList()) {
        if (index != _current) _evictController(index);
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    for (final index in _controllers.keys.toList()) {
      if (index != _current) _evictController(index);
    }
  }

  Future<void> _loadMore({bool first = false}) async {
    if (!widget.active ||
        _loading ||
        _exhausted ||
        (widget.initialItemsOnly && widget.loadMoreInitialItems == null)) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final requestRepository = _repo;
    try {
      List<ReelItem> batch;
      if (widget.initialItemsOnly && widget.loadMoreInitialItems != null) {
        batch = await widget.loadMoreInitialItems!();
      } else {
        if (widget.source == ContentSource.trans) {
          final ageConfirmed = await confirmAge(context);
          if (!mounted) return;
          if (!ageConfirmed) {
            setState(() {
              _error = 'Confirm that you are 18 or older to watch these videos.';
              _loading = false;
              _initialLoadCompleted = true;
              _pendingKeyboardPage = null;
            });
            return;
          }
        }
        batch = await requestRepository.nextBatch(
          first ? _kFirstBatch : _kNextBatch,
        );
      }
      if (!mounted || !identical(requestRepository, _repo)) return;
      final retryableEmptyTrans = batch.isEmpty &&
          widget.source == ContentSource.trans &&
          requestRepository.hasMoreTransPages &&
          _initialLoadRetries < 2;
      if (retryableEmptyTrans) {
        _initialLoadRetries++;
        setState(() {
          _loading = false;
          _exhausted = false;
          _error = null;
        });
        _scheduleInitialTransRetry();
        return;
      }
      if (batch.isEmpty &&
          widget.source == ContentSource.trans &&
          requestRepository.hasMoreTransPages) {
        setState(() {
          _loading = false;
          _initialLoadCompleted = true;
          _exhausted = false;
          _error = 'You’re all caught up. Try again later.';
          _pendingKeyboardPage = null;
        });
        return;
      }
      setState(() {
        final existingIds = _items.map((item) => item.id).toSet();
        final existingUrls = _items.map((item) => item.videoUrl).toSet();
        for (final item in batch) {
          if (existingIds.add(item.id) &&
              existingUrls.add(item.videoUrl) &&
              _loadedReelIds.add(item.id)) {
            _items.add(item);
            while (_loadedReelIds.length > 192) {
              _loadedReelIds.remove(_loadedReelIds.first);
            }
          }
        }
        final moreInitialItems = widget.initialItemsOnly &&
            widget.hasMoreInitialItems?.call() == true;
        final moreTransItems = widget.source == ContentSource.trans &&
            requestRepository.hasMoreTransPages;
        if (widget.initialItemsOnly) {
          if (!moreInitialItems) _exhausted = true;
        } else if (widget.source == ContentSource.trans) {
          _exhausted = !moreTransItems;
        } else if (batch.isEmpty) {
          _exhausted = true;
        }
        _loading = false;
        _initialLoadCompleted = true;
        if (batch.isNotEmpty) _initialLoadRetries = 0;
      });
      if (_items.isEmpty || !widget.active) return;
      final pendingLoadPage = _pendingLoadPage;
      if (pendingLoadPage != null) {
        _pendingLoadPage = null;
        if (pendingLoadPage < _items.length) {
          _stopReelAnalytics(_current);
          _current = pendingLoadPage;
          _syncControllers(_current, preserveDuringTransition: _current - 1);
          _rememberCurrentReel();
        } else if (_exhausted && _pager.hasClients) {
          _pager.jumpToPage(_current);
        }
      }
      if (first) {
        _syncControllers(0);
        _rememberCurrentReel();
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
      if (!mounted || !identical(requestRepository, _repo)) return;
      if (kDebugMode) debugPrint('[REELS] load failed: $e');
      if (widget.source == ContentSource.trans &&
          _items.isEmpty &&
          _initialLoadRetries < 2) {
        _initialLoadRetries++;
        setState(() {
          _loading = false;
          _exhausted = false;
          _error = null;
        });
        _scheduleInitialTransRetry();
        return;
      }
      setState(() {
        _initialLoadCompleted = true;
        _error = describeError(e, subject: 'reels').message;
        _loading = false;
        _pendingKeyboardPage = null;
      });
    }
  }

  void _scheduleInitialTransRetry() {
    final delay = Duration(
      milliseconds: 250 + (100 * _initialLoadRetries).clamp(0, 1200).toInt(),
    );
    unawaited(Future<void>.delayed(delay).then((_) {
      if (!mounted || !widget.active || _loading || _exhausted) return;
      _exhausted = false;
      unawaited(_loadMore(first: _items.isEmpty));
    }));
  }

  Future<void> _resumeAtNextUnseenReel() async {
    if (_refreshingSeenOnReturn ||
        !mounted ||
        !widget.active ||
        widget.initialItemsOnly ||
        _items.isEmpty) {
      return;
    }
    _refreshingSeenOnReturn = true;
    try {
      final seenKeys = await _seenStore.findSeenIds(
        _items.expand((item) => [
              item.id,
              ReelSeenStore.urlKey(item.videoUrl),
            ]).where((key) => key.isNotEmpty),
      );
      final seenIds = <String>{
        for (final item in _items)
          if (seenKeys.contains(item.id) ||
              seenKeys.contains(ReelSeenStore.urlKey(item.videoUrl)))
            item.id,
      };
      if (!mounted || !widget.active || seenIds.isEmpty) {
        if (mounted && widget.active) _syncControllers(_current);
        return;
      }

      final remaining = _items
          .where((item) => !seenIds.contains(item.id))
          .toList(growable: false);
      if (remaining.length == _items.length) {
        _syncControllers(_current);
        return;
      }

      _stopReelAnalytics(_current);
      for (final controller in _controllers.values.toList()) {
        final listener = _controllerListeners.remove(controller);
        if (listener != null) controller.removeListener(listener);
        unawaited(_disposeReelController(controller));
      }
      _controllers.clear();
      _reelStates.clear();
      _analyticsWatchStarted.clear();

      setState(() {
        _items
          ..clear()
          ..addAll(remaining);
        _loadedReelIds
          ..clear()
          ..addAll(remaining.map((item) => item.id));
        _current = 0;
        _pendingLoadPage = null;
        _pendingKeyboardPage = null;
        _reelScrollInProgress = false;
        if (remaining.isEmpty) {
          _exhausted = false;
        }
      });

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !widget.active) return;
      if (_items.isNotEmpty) {
        if (_pager.hasClients) _pager.jumpToPage(0);
        _syncControllers(0);
      } else if (!_loading) {
        unawaited(_loadMore(first: true));
      }
    } catch (error) {
      if (kDebugMode) {
      }
      if (mounted && widget.active && _items.isNotEmpty) {
        _syncControllers(_current);
      }
    } finally {
      _refreshingSeenOnReturn = false;
    }
  }

  void _rememberCurrentReel() {
    if (_current < 0 || _current >= _items.length) return;
    final id = _items[_current].id.trim();
    final url = _items[_current].videoUrl;
    if (id.isEmpty || !_markedSeenThisSession.add(id)) return;
    while (_markedSeenThisSession.length > 128) {
      _markedSeenThisSession.remove(_markedSeenThisSession.first);
    }
    unawaited(_seenStore.markSeen(id, url: url).catchError((Object error) {
      if (kDebugMode) debugPrint('[REELS] history write failed: ${error.runtimeType}');
    }));
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
    final disposal = _disposeTail.then((_) async {
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

  VideoPlayerController _build(
    String url,
    int index, {
    String? fallback,
    Map<String, String>? headers,
  }) {
    if (_reelStates[index] != _ReelPlaybackState.retrying) {
      _reelStates[index] = _ReelPlaybackState.loading;
    }
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers ?? _kMediaHeaders,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    _attachControllerListener(controller);

    final initialization = () async {
      try {
        await _disposeTail;
        if (!_ownsController(index, controller)) return;
        await controller.setLooping(true);
        await controller.initialize().timeout(const Duration(seconds: 28));
        if (!_ownsController(index, controller)) return;
        await controller.setVolume(
          index == _current && !_muted && widget.active && !_adShowing
              ? 1
              : 0,
        );
        if (index == _current && widget.active && !_adShowing) {
          await controller.play();
        }
        _syncControllerState(controller);
        if (mounted) setState(() {});
      } catch (error) {
        if (!_ownsController(index, controller)) return;
        _controllers.remove(index);
        final listener = _controllerListeners.remove(controller);
        if (listener != null) controller.removeListener(listener);
        unawaited(_disposeReelController(controller));
        if (fallback != null) {
          _reelStates[index] = _ReelPlaybackState.retrying;
          _controllers[index] = _build(fallback, index, headers: headers);
        } else {
          _reelStates[index] = _ReelPlaybackState.failed;
        }
        if (mounted) setState(() {});
        if (kDebugMode) {
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
      return _build(
        item.videoUrl,
        index,
        fallback: item.fallbackUrl,
        headers: _headersForReel(item),
      );
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

  void _syncControllers(int index, {int? preserveDuringTransition}) {
    if (!widget.active) return;
    final keep = <int>{index};
    if (preserveDuringTransition != null &&
        preserveDuringTransition >= 0 &&
        preserveDuringTransition < _items.length) {
      keep.add(preserveDuringTransition);
    }
    final maxControllers = defaultTargetPlatform == TargetPlatform.windows
        ? 2
        : 3;
    if (defaultTargetPlatform != TargetPlatform.windows) {
      keep.add(index + 1);
    }
    keep.removeWhere((i) => i < 0 || i >= _items.length);
    for (final i in _controllers.keys.toList()) {
      if (!keep.contains(i)) _evictController(i);
    }

    if (keep.contains(index)) _controllerFor(index);
    for (final entry in _controllers.entries) {
      final controller = entry.value;
      if (!controller.value.isInitialized) continue;
      if (entry.key == index) {
        unawaited(
          controller.setVolume(
            _muted || !widget.active || _adShowing ? 0 : 1,
          ),
        );
        if (widget.active && !_adShowing) {
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
    if (keep.contains(next) && _controllers.length < maxControllers) {
      _controllerFor(next);
    }
    if (mounted) setState(() {});
  }

  void _onReelPageChanged(int page) {
    if (!widget.active || page < 0) return;
    if (page >= _items.length) {
      _pendingLoadPage = page;
      if (!_loading && !_exhausted) unawaited(_loadMore());
      return;
    }
    if (page == _current) return;

    final previous = _current;
    _stopReelAnalytics(previous);
    _current = page;
    _reelScrollInProgress = true;
    _rememberCurrentReel();
    _syncControllers(page, preserveDuringTransition: previous);

    if (_current >= _items.length - _kPreloadAhead &&
        !_loading && !_exhausted &&
        (!widget.initialItemsOnly || widget.loadMoreInitialItems != null)) {
      unawaited(_loadMore());
    }
  }

  void _activateSettledPage() {
    if (!widget.active || !_pager.hasClients || _items.isEmpty) return;
    final settled = (_pager.page ?? _current.toDouble())
        .round()
        .clamp(0, _items.length - 1)
        .toInt();
    if (settled != _current) {
      _stopReelAnalytics(_current);
      _current = settled;
    }
    _reelScrollInProgress = false;
    _rememberCurrentReel();
    _syncControllers(_current);
  }

  void _movePage(int direction) {
    if (!_pager.hasClients || _items.isEmpty) return;
    final target = _current + direction;
    if (target < 0) return;
    if (target >= _items.length) {
      if (!_exhausted) {
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
    if (n.depth != 0 || !widget.active) return false;
    if (n is ScrollStartNotification) {
      if (!_reelScrollInProgress) {
        _reelScrollInProgress = true;
        if (mounted) setState(() {});
      }
    } else if (n is ScrollEndNotification) {
      _activateSettledPage();
      if (_current >= _items.length - _kPreloadAhead &&
          !_loading && !_exhausted &&
          (!widget.initialItemsOnly || widget.loadMoreInitialItems != null)) {
        unawaited(_loadMore());
      }
      _trimOldReelsIfNeeded();
    }
    return false;
  }

  void _trimOldReelsIfNeeded() {
    if (widget.initialItemsOnly) return;
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
      _reelScrollInProgress = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pager.hasClients) return;
      _pager.jumpToPage(_current);
    });
  }

  void _showComments(ReelItem item) {
    final postId = item.postId;
    if (widget.source != ContentSource.trans || postId == null || postId.isEmpty) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .62),
      elevation: 0,
      builder: (_) => _XxxFollowCommentsSheet(
        loadPage: (offset) => _repo.getXxxFollowPostComments(
          postId, offset: offset,
        ),
      ),
    );
  }

  void _openCreatorAccount(String username) {
    if (widget.source != ContentSource.trans || username.trim().isEmpty) return;
    _pauseForLeaving();
    final route = Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context,
        builder: (_) => XxxFollowCreatorPage(
          username: username,
          loadAccount: () => _repo.getXxxFollowAccount(username),
          loadMorePosts: (account) => _repo.getMoreXxxFollowCreatorPosts(
            account,
            maxPages: 1,
          ),
          hasMorePages: () => _repo.hasMoreXxxFollowCreatorPages(username),
          onPlayReels: (items, initialIndex, loadMore) async {
            _pauseForLeaving();
            await Navigator.of(context).push<void>(
              adaptivePageRoute<void>(
                context,
                builder: (_) => ReelsPage(
                  active: true,
                  bottomInset: 0,
                  source: ContentSource.trans,
                  initialItems: items,
                  initialIndex: initialIndex,
                  initialItemsOnly: true,
                  loadMoreInitialItems: loadMore,
                  hasMoreInitialItems: () => _repo.hasMoreXxxFollowCreatorPages(username),
                  onExitToPrevious: () => Navigator.of(context).maybePop(),
                ),
              ),
            );
            if (mounted && widget.active) _syncControllers(_current);
          },
        ),
      ),
    );
    unawaited(
      route.then<void>((_) {
        if (mounted && widget.active) _syncControllers(_current);
      }),
    );
  }

  void _toggleLike(ReelItem item) {
    final liked = ReelFavorites.instance.toggle(item);
    Haptics.play(liked ? Haptic.medium : Haptic.light);
  }

  bool _likeFromDoubleTap(ReelItem item) {
    final added = ReelFavorites.instance.like(item);
    if (added) Haptics.play(Haptic.medium);
    return added;
  }

  Future<void> _shareReel(ReelItem item) async {
    // Downloaded copy exists -> share the actual file through the
    // native bridge; otherwise share the stream URL as text. The
    // toast reports only what really happened.
    final path = DownloadStore.instance.localPath('reel_${item.id}');
    final ok = path != null
        ? await NativeBridge.instance.shareFile(path)
        : await NativeBridge.instance.shareText(item.videoUrl);
    if (!ok && mounted) _toast('Sharing is not available right now');
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
      final req = http.Request('GET', uri)
        ..headers.addAll(_headersForReel(item));
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

  KeyEventResult _onRemoteKey(FocusNode node, KeyEvent event) {
    if (!widget.active || event is KeyUpEvent && !_isOk(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (isDown) _remote.send('toggle');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaRewind) {
      _remoteStep(() => _remote.send(
          key == LogicalKeyboardKey.mediaFastForward ? 'forward' : 'back'),
          isDown);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.channelUp) {
      _remoteStep(() => _movePage(1), isDown);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.channelDown) {
      _remoteStep(() => _movePage(-1), isDown);
      return KeyEventResult.handled;
    }

    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;

    if (_isOk(key)) {
      if (event is KeyDownEvent) {
        _okHoldFired = false;
        _okHold?.cancel();
        _okHold = Timer(const Duration(milliseconds: 520), () {
          _okHoldFired = true;
          _remote.send('rail');
        });
      } else if (event is KeyUpEvent) {
        _okHold?.cancel();
        if (!_okHoldFired) _remote.send('toggle');
        _okHoldFired = false;
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _remoteStep(() => _movePage(1), isDown);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _remoteStep(() => _movePage(-1), isDown);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _remoteStep(() => _remote.send('forward'), isDown);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _remoteStep(() => _remote.send('back'), isDown);
      return KeyEventResult.handled;
    }
    if (isDown &&
        (key == LogicalKeyboardKey.contextMenu ||
            key == LogicalKeyboardKey.info ||
            key == LogicalKeyboardKey.gameButtonX)) {
      _remote.send('comments');
      return KeyEventResult.handled;
    }
    if (isDown &&
        (key == LogicalKeyboardKey.colorF2Yellow ||
            key == LogicalKeyboardKey.gameButtonY)) {
      _remote.send('like');
      return KeyEventResult.handled;
    }
    if (isDown && key == LogicalKeyboardKey.colorF1Green) {
      _remote.send('save');
      return KeyEventResult.handled;
    }
    if (isDown && key == LogicalKeyboardKey.colorF3Blue) {
      _remote.send('mute');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static bool _isOk(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.space;

  void _remoteStep(VoidCallback action, bool isDown) {
    final now = DateTime.now();
    if (!isDown &&
        now.difference(_lastRemoteStep) < const Duration(milliseconds: 350)) {
      return;
    }
    _lastRemoteStep = now;
    action();
  }

  @override
  Widget build(BuildContext context) {
    final top = context.safe.top;
    final bottom = widget.bottomInset;
    return Focus(
      focusNode: _keyboardFocus,
      onKeyEvent: _onRemoteKey,
      child: DefaultTextStyle.merge(
        style: const TextStyle(decoration: TextDecoration.none),
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
                  allowImplicitScrolling: true,
                  dragStartBehavior: DragStartBehavior.down,
                  onPageChanged: _onReelPageChanged,
                  physics: defaultTargetPlatform == TargetPlatform.iOS
                      ? const _FastReelsPagePhysics(
                          parent: BouncingScrollPhysics(),
                        )
                      : const _FastReelsPagePhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                  padEnds: false,
                  clipBehavior: Clip.hardEdge,
                  itemCount: _items.length + (_exhausted ? 0 : 1),
                  itemBuilder: (context, i) {
                    if (i >= _items.length) {
                      return ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: _loading
                              ? const CupertinoActivityIndicator(
                                  radius: 14, color: Colors.white70)
                              : _error != null
                                  ? _ErrorView(
                                      message: _error!,
                                      onRetry: () => _loadMore(),
                                    )
                                  : const CupertinoActivityIndicator(
                                      radius: 14, color: Colors.white70),
                        ),
                      );
                    }
                    final item = _items[i];
                    return RepaintBoundary(
                      child: _ReelView(
                        key: ValueKey(item.id),
                        item: item,
                        controller: _controllers[i],
                        playbackState:
                            _reelStates[i] ?? _ReelPlaybackState.idle,
                        isActive: widget.active &&
                            i == _current &&
                            !_adShowing,
                        muted: _muted,
                        saving: _saving,
                        bottomInset: bottom,
                        clear: _clear,
                        onMute: _toggleMute,
                        onSaveMenu: () => _showSaveMenu(item),
                        onShare: () => _shareReel(item),
                        onRetry: () => _retry(i),
                        onToggleLike: () => _toggleLike(item),
                        onDoubleTapLike: () => _likeFromDoubleTap(item),
                        remote: _remote,
                        onRailExit: _keyboardFocus.requestFocus,
                        onComments: widget.source == ContentSource.trans &&
                                item.postId != null && item.postId!.isNotEmpty
                            ? () => _showComments(item)
                            : null,
                        onOpenAuthor: !widget.initialItemsOnly &&
                                widget.source == ContentSource.trans &&
                                item.author.isNotEmpty
                            ? () => _openCreatorAccount(item.author)
                            : null,
                      ),
                    );
                  },
                ),
              )
            else if (_loading || !_initialLoadCompleted)
              Center(
                child: widget.active
                    ? const CupertinoActivityIndicator(
                        radius: 14,
                        color: Colors.white70,
                      )
                    : const SizedBox.shrink(),
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
              child: _ReelsTopBar(
                clear: _clear,
                onToggleClear: _toggleClear,
                // Fix 19: an explicit, remote-reachable Refresh —
                // Reels has no pull-to-refresh (vertical paging owns
                // the gesture), so the action lives in the top bar.
                onRefresh: _resetForSourceChange,
              ),
            ),
            if (widget.onExitToPrevious != null)
              widget.initialItemsOnly
                  ? Positioned.fill(
                      child: _RightEdgeExitGesture(
                        anywhere: true,
                        bottomExclusion: bottom + 120,
                        onExit: widget.onExitToPrevious!,
                      ),
                    )
                  : Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: 36,
                      child: _RightEdgeExitGesture(
                        onExit: widget.onExitToPrevious!,
                      ),
                    ),
          ],
        ),
        ),
      ),
    );
  }
}

class _ReelsTopBar extends StatelessWidget {
  const _ReelsTopBar({
    required this.clear,
    required this.onToggleClear,
    required this.onRefresh,
  });

  final bool clear;
  final VoidCallback onToggleClear;
  final VoidCallback onRefresh;

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
            semanticLabel: 'Refresh feed',
            haptic: Haptic.selection,
            pressedScale: 0.85,
            onTap: onRefresh,
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                CupertinoIcons.refresh,
                color: Colors.white,
                size: 21,
                shadows: [Shadow(blurRadius: 12, color: Color(0x66000000))],
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

const double _kSkipZone = 0.18;

class _ReelRemote extends ChangeNotifier {
  String command = '';

  void send(String value) {
    command = value;
    notifyListeners();
  }
}

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
    required this.onShare,
    required this.onRetry,
    required this.onToggleLike,
    required this.onDoubleTapLike,
    required this.remote,
    required this.onRailExit,
    this.onOpenAuthor,
    this.onComments,
  });

  final _ReelRemote remote;
  final VoidCallback onRailExit;
  final ReelItem item;
  final VideoPlayerController? controller;
  final _ReelPlaybackState playbackState;
  final bool isActive;
  final bool muted;
  final ValueListenable<Map<String, double>> saving;

  final double bottomInset;
  final bool clear;
  final VoidCallback onMute;
  final VoidCallback onSaveMenu;
  final VoidCallback onShare;
  final VoidCallback onRetry;
  final VoidCallback onToggleLike;
  final bool Function() onDoubleTapLike;
  final VoidCallback? onOpenAuthor;
  final VoidCallback? onComments;

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

  final FocusScopeNode _railScope = FocusScopeNode(debugLabel: 'Reel actions');

  @override
  void initState() {
    super.initState();
    widget.remote.addListener(_onRemote);
  }

  void _onRemote() {
    if (!mounted || !widget.isActive) return;
    switch (widget.remote.command) {
      case 'toggle':
        _togglePlay();
      case 'back':
        unawaited(_skip(-1));
      case 'forward':
        unawaited(_skip(1));
      case 'like':
        widget.onToggleLike();
      case 'comments':
        widget.onComments?.call();
      case 'mute':
        widget.onMute();
      case 'save':
        widget.onSaveMenu();
      case 'author':
        widget.onOpenAuthor?.call();
      case 'rail':
        _railScope.requestFocus();
    }
  }

  KeyEventResult _onRailKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.browserBack) {
      if (event is KeyDownEvent) widget.onRailExit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(covariant _ReelView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.remote != widget.remote) {
      oldWidget.remote.removeListener(_onRemote);
      widget.remote.addListener(_onRemote);
    }
    if (oldWidget.isActive && !widget.isActive) _resetGestures();
  }

  @override
  void dispose() {
    widget.remote.removeListener(_onRemote);
    _railScope.dispose();
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
              child: Image(
                // Disk-cached (fix 09): reel posters are re-shown on
                // every page revisit and must not re-download.
                image: CachedNetworkImageProvider(
                  item.thumbUrl!,
                  headers: _headersForReel(item),
                  maxWidth: (MediaQuery.sizeOf(context).width *
                          MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(128, 1080)
                      .toInt(),
                ),
                fit: BoxFit.cover,
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
                    child: Image(
                      image: CachedNetworkImageProvider(
                        item.thumbUrl!,
                        headers: _headersForReel(item),
                        maxWidth: (MediaQuery.sizeOf(context).width *
                                MediaQuery.devicePixelRatioOf(context))
                            .round()
                            .clamp(128, 1080)
                            .toInt(),
                      ),
                      fit: BoxFit.cover,
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
          child: _UiFade(
            hidden: hideUi,
            child: _InfoBlock(
              item: item,
              onOpenAuthor: widget.onOpenAuthor,
            ),
          ),
        ),

        Positioned(
          right: 6,
          bottom: bottom + 52,
          child: _UiFade(
            hidden: hideUi,
            child: FocusScope(
              node: _railScope,
              onKeyEvent: _onRailKey,
              child: _ActionRail(
              item: item,
              muted: widget.muted,
              saving: widget.saving,
              onToggleLike: widget.onToggleLike,
              onMute: widget.onMute,
              onSaveMenu: widget.onSaveMenu,
              onShare: widget.onShare,
              onComments: widget.onComments,
            ),
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
  const _InfoBlock({required this.item, this.onOpenAuthor});

  final ReelItem item;
  final VoidCallback? onOpenAuthor;

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(blurRadius: 10, color: Color(0x99000000))];
    final title = item.title.isEmpty ? 'Untitled' : item.title;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.author.isNotEmpty)
          Focusable(
            onTap: onOpenAuthor,
            focusRadius: 20,
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpenAuthor,
            child: Row(
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
                          : Image(
                              image: CachedNetworkImageProvider(
                                item.avatarUrl!,
                                headers: _headersForReel(item),
                                maxWidth: 108,
                              ),
                              fit: BoxFit.cover,
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
                if (onOpenAuthor != null) ...[
                  const SizedBox(width: 5),
                  const Icon(CupertinoIcons.info_circle, size: 14, color: Colors.white70),
                ],
              ],
            ),
          ),
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
    required this.onShare,
    this.onComments,
  });

  final ReelItem item;
  final bool muted;
  final ValueListenable<Map<String, double>> saving;
  final VoidCallback onToggleLike;
  final VoidCallback onMute;
  final VoidCallback onSaveMenu;
  final VoidCallback onShare;
  final VoidCallback? onComments;

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
        if (onComments != null) ...[
          const SizedBox(height: 12),
          _RailButton(
            icon: CupertinoIcons.chat_bubble,
            label: _compact(item.commentCount),
            semanticLabel: 'Comments',
            onTap: onComments,
          ),
        ],
        const SizedBox(height: 12),
        _RailButton(
          icon: CupertinoIcons.share,
          label: 'Share',
          semanticLabel: 'Share',
          onTap: onShare,
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
    this.semanticLabel,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color iconColor;
  final double size;
  final double? progress;
  final bool? pop;
  final Haptic haptic;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      icon,
      color: onTap == null ? Colors.white54 : iconColor,
      size: size,
      shadows: const [Shadow(blurRadius: 14, color: Color(0x80000000))],
    );
    return Pressable(
      semanticLabel: semanticLabel ?? label,
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
                  // Scrim disc: guarantees icon legibility over any
                  // video frame, bright or dark.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x59000000),
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(width: 46, height: 46),
                  ),
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

  int? _pointer;
  bool _seekBusy = false;
  DateTime _lastLiveSeek = DateTime.fromMillisecondsSinceEpoch(0);

  void _liveSeek(double fraction) {
    if (_seekBusy) return;
    final now = DateTime.now();
    if (now.difference(_lastLiveSeek) < const Duration(milliseconds: 80)) {
      return;
    }
    final ms = _c.value.duration.inMilliseconds;
    if (ms <= 0) return;
    _lastLiveSeek = now;
    _seekBusy = true;
    unawaited(
      _c
          .seekTo(Duration(milliseconds: (ms * fraction).round()))
          .catchError((_) {})
          .whenComplete(() => _seekBusy = false),
    );
  }

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
    final fraction = _fracAt(dx, width);
    setState(() => _frac = fraction);
    _liveSeek(fraction);
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
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (_pointer != null) return;
            _pointer = e.pointer;
            _start(e.localPosition.dx, width);
            _liveSeek(_frac);
          },
          onPointerMove: (e) {
            if (e.pointer != _pointer) return;
            _update(e.localPosition.dx, width);
          },
          onPointerUp: (e) {
            if (e.pointer != _pointer) return;
            _pointer = null;
            _update(e.localPosition.dx, width);
            _end();
          },
          onPointerCancel: (e) {
            if (e.pointer != _pointer) return;
            _pointer = null;
            _end();
          },
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (_) {},
          onHorizontalDragUpdate: (_) {},
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
                  fontSize: 12,
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


class _RightEdgeExitGesture extends StatefulWidget {
  const _RightEdgeExitGesture({
    required this.onExit,
    this.anywhere = false,
    this.bottomExclusion = 0,
  });

  final VoidCallback onExit;

  final bool anywhere;

  final double bottomExclusion;

  @override
  State<_RightEdgeExitGesture> createState() => _RightEdgeExitGestureState();
}

class _RightEdgeExitGestureState extends State<_RightEdgeExitGesture> {
  Offset _start = Offset.zero;
  bool _tracking = false;
  bool _triggered = false;
  int _pointers = 0;

  void _trigger() {
    if (_triggered) return;
    _triggered = true;
    Haptics.play(Haptic.selection);
    widget.onExit();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointers++;
        final nearLeftEdge = e.position.dx < 28;
        final inBottomControls =
            e.position.dy > size.height - widget.bottomExclusion;
        _tracking = _pointers == 1 &&
            !(widget.anywhere && (nearLeftEdge || inBottomControls));
        _start = e.position;
        _triggered = false;
      },
      onPointerMove: (e) {
        if (!_tracking || _triggered) return;
        final dx = e.position.dx - _start.dx;
        final dy = e.position.dy - _start.dy;
        final horizontal = dx.abs() > dy.abs() * 1.8;
        if (widget.anywhere) {
          if (dx.abs() >= 70 && horizontal) {
            _tracking = false;
            _trigger();
          }
        } else if (dx <= -40 && horizontal) {
          _tracking = false;
          _trigger();
        }
      },
      onPointerUp: (_) {
        _pointers = (_pointers - 1).clamp(0, 10);
        _tracking = false;
      },
      onPointerCancel: (_) {
        _pointers = (_pointers - 1).clamp(0, 10);
        _tracking = false;
      },
      child: const SizedBox.expand(),
    );
  }
}

class _XxxFollowCommentsSheet extends StatefulWidget {
  const _XxxFollowCommentsSheet({required this.loadPage});

  final Future<XxxFollowCommentsPage> Function(int offset) loadPage;

  @override
  State<_XxxFollowCommentsSheet> createState() =>
      _XxxFollowCommentsSheetState();
}

class _XxxFollowCommentsSheetState extends State<_XxxFollowCommentsSheet>
    with SingleTickerProviderStateMixin {
  final List<XxxFollowComment> _comments = <XxxFollowComment>[];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _total = 0;
  int _nextOffset = 0;
  final ScrollController _listController = ScrollController();
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  double _dy = 0;
  double _velocity = 0;
  Duration? _lastMoveTime;
  bool _tracking = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _listController.addListener(_autoLoadMore);
    unawaited(_load());
  }

  void _autoLoadMore() {
    if (!_hasMore || _loading || _loadingMore || _error != null) return;
    if (!_listController.hasClients) return;
    if (_listController.position.extentAfter < 360) {
      unawaited(_load(more: true));
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    _listController.dispose();
    super.dispose();
  }

  bool get _listAtTop =>
      !_listController.hasClients || _listController.offset <= 0.5;

  void _animateTo(double target, {VoidCallback? then}) {
    final from = _dy;
    _settle
      ..stop()
      ..reset();
    final tween = Tween<double>(begin: from, end: target);
    void tick() {
      if (!mounted) return;
      setState(() => _dy = tween.transform(Curves.easeOutCubic.transform(_settle.value)));
    }

    _settle.addListener(tick);
    _settle.forward().whenComplete(() {
      _settle.removeListener(tick);
      then?.call();
    });
  }

  void _dismiss() {
    if (_closing || !mounted) return;
    _closing = true;
    final height = MediaQuery.sizeOf(context).height;
    _animateTo(height, then: () {
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_closing) return;
    _settle.stop();
    _tracking = true;
    _velocity = 0;
    _lastMoveTime = event.timeStamp;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_tracking || _closing) return;
    final dy = event.delta.dy;
    final dt = _lastMoveTime == null
        ? 0
        : (event.timeStamp - _lastMoveTime!).inMicroseconds;
    _lastMoveTime = event.timeStamp;
    if (dt > 0) _velocity = dy / (dt / 1e6);
    if ((dy > 0 && _listAtTop) || _dy > 0) {
      setState(() => _dy = (_dy + dy).clamp(0.0, double.infinity));
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (!_tracking || _closing) return;
    _tracking = false;
    if (_dy <= 0) return;
    final height = MediaQuery.sizeOf(context).height;
    if (_dy > height * 0.18 || _velocity > 900) {
      _dismiss();
    } else {
      _animateTo(0);
    }
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || _loadingMore || (more && !_hasMore)) return;
    final requestedOffset = _nextOffset;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    try {
      final page = await widget.loadPage(requestedOffset);
      if (!mounted) return;
      setState(() {
        final ids = _comments.map((comment) => comment.id).toSet();
        for (final comment in page.comments) {
          if (ids.add(comment.id)) _comments.add(comment);
        }
        _nextOffset = page.nextOffset > requestedOffset
            ? page.nextOffset
            : requestedOffset;
        _total = page.total > 0 ? page.total : _comments.length;
        final reachedKnownEnd = page.total > 0 && _nextOffset >= page.total;
        _hasMore = page.hasMore &&
            page.comments.isNotEmpty &&
            _nextOffset > requestedOffset &&
            !reachedKnownEnd;
        _loading = false;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error, subject: 'comments').message;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  String _date(String raw) {
    final date = DateTime.tryParse(raw);
    if (date == null) return '';
    final local = date.toLocal();
    final difference = DateTime.now().difference(local);
    if (difference.isNegative || difference.inMinutes < 1) return 'now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return '${local.day}/${local.month}/${local.year}';
  }

  Widget _avatar(XxxFollowComment comment) {
    final url = comment.avatarUrl;
    if (url == null) {
      return const CircleAvatar(
        radius: 19,
        backgroundColor: Color(0xFF292D36),
        child: Icon(CupertinoIcons.person_fill, size: 17, color: Colors.white70),
      );
    }
    return CircleAvatar(
      radius: 19,
      backgroundColor: const Color(0xFF292D36),
      backgroundImage: NetworkImage(url),
      onBackgroundImageError: (_, __) {},
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: CupertinoActivityIndicator(color: Colors.white70),
      );
    }
    if (_error != null && _comments.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 22),
        child: Column(
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            TextButton(
              onPressed: () => _load(more: true),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    return const SizedBox(height: 22);
  }

  Widget _buildCommentsContent() {
    final scrollController = _listController;
    final physics = _dy > 0
        ? const NeverScrollableScrollPhysics()
        : const ClampingScrollPhysics();
    if (_loading) {
      return ListView(
        controller: scrollController,
        physics: physics,
        children: const [
          SizedBox(height: 120),
          Center(
            child: CupertinoActivityIndicator(
              color: Colors.white70,
              radius: 13,
            ),
          ),
        ],
      );
    }

    if (_error != null && _comments.isEmpty) {
      return ListView(
        controller: scrollController,
        physics: physics,
        padding: const EdgeInsets.fromLTRB(24, 70, 24, 24),
        children: [
          const Icon(CupertinoIcons.wifi_slash, color: Colors.white38, size: 30),
          const SizedBox(height: 12),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
          const SizedBox(height: 10),
          Center(
            child: FilledButton.tonal(
              onPressed: () => _load(),
              child: const Text('Try again'),
            ),
          ),
        ],
      );
    }

    if (_comments.isEmpty) {
      return ListView(
        controller: scrollController,
        physics: physics,
        children: const [
          SizedBox(height: 100),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.chat_bubble, color: Colors.white30, size: 34),
                SizedBox(height: 12),
                Text('No comments yet', style: TextStyle(color: Colors.white70, fontSize: 14)),
                SizedBox(height: 4),
                Text('Be the first to leave a comment.', style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      controller: scrollController,
      physics: physics,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      itemCount: _comments.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemBuilder: (context, index) {
        if (index == _comments.length) return _footer();
        final comment = _comments[index];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _avatar(comment),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          comment.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (_date(comment.createdAt).isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          _date(comment.createdAt),
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    comment.text,
                    style: const TextStyle(
                      color: Color(0xFFE7E8EC),
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  if (comment.replyCount > 0) ...[
                    const SizedBox(height: 7),
                    Text(
                      '${comment.replyCount} replies',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                children: [
                  const Icon(CupertinoIcons.heart, size: 17, color: Colors.white38),
                  const SizedBox(height: 4),
                  Text(
                    reelCompact(comment.likes),
                    style: const TextStyle(color: Colors.white38, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = media.viewInsets.bottom;
    final shownCount = _total > 0 ? _total : _comments.length;
    final sheetHeight = (media.size.height - media.padding.top) * .78;
    return Focus(
      autofocus: true,
      onKeyEvent: _onRemoteKey,
      child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: Transform.translate(
        offset: Offset(0, _dy),
        child: Container(
          height: sheetHeight,
          clipBehavior: Clip.antiAlias,
          decoration: const BoxDecoration(
            color: Color(0xFF111318),
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottom),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 0, 3),
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 8, 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Comments',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.2,
                          ),
                        ),
                      ),
                      if (shownCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .09),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            reelCompact(shownCount),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Close comments',
                        onPressed: _dismiss,
                        icon: const Icon(CupertinoIcons.xmark, size: 18),
                        color: Colors.white70,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white10, height: 1),
                Expanded(child: _buildCommentsContent()),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  KeyEventResult _onRemoteKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _closing) return KeyEventResult.ignored;
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    final key = event.logicalKey;
    double? delta;
    if (key == LogicalKeyboardKey.arrowDown) delta = 170;
    if (key == LogicalKeyboardKey.arrowUp) delta = -170;
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.channelDown) {
      delta = 520;
    }
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.channelUp) {
      delta = -520;
    }
    if (delta != null) {
      if (_listController.hasClients) {
        final position = _listController.position;
        final target =
            (position.pixels + delta).clamp(0.0, position.maxScrollExtent);
        unawaited(_listController.animateTo(
          target,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        ));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (event is KeyDownEvent) node.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

