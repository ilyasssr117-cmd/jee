import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cupertino_http/cupertino_http.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        CupertinoActivityIndicator,
        showCupertinoModalPopup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import 'app_theme.dart';
import 'download_store.dart';
import 'favorites_store.dart';
import 'local_store.dart';
import 'mini_player.dart';
import 'models.dart';
import 'photo_saver.dart';
import 'preview_manager.dart';
import 'touch.dart';
import 'widgets/app_button.dart';
import 'widgets/dialogs.dart';

const String _kUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 '
    'Mobile/15E148 Safari/604.1';

// كان قبل `https://$_mediaSite/` وهو يطلع https://https://... وغلط
const String _kMediaOrigin = 'https://apiv2.tik.porn/getnextvideos';
const Map<String, String> _kMediaHeaders = {
  'User-Agent': _kUserAgent,
  'Referer': '$_kMediaOrigin/',
  'Origin': _kMediaOrigin,
  'Accept': '*/*',
};

const int _kFirstBatch = 20;
const int _kNextBatch = 20;
const int _kPreloadAhead = 4;
const int _kMaxRefetchTries = 4;
const String _kClearKey = 'reels_clear_mode_v1';
const Duration _kSeekStep = Duration(seconds: 10);

class ReelItem {
  const ReelItem({
    required this.id,
    required this.videoUrl,
    this.title = '',
    this.thumbUrl,
    this.avatarUrl,
    this.author = '',
    this.likes = '',
    this.views = 0,
    this.durationSec = 0,
    this.tags = const <String>[],
    this.fallbackUrl,
    this.downloadUrl,
  });

  final String id;
  final String videoUrl; // mp4_url
  final String? fallbackUrl; // hls_url
  final String? downloadUrl; // download_url (جودة أعلى)
  final String title;
  final String? thumbUrl;
  final String? avatarUrl;
  final String author;
  final String likes;
  final int views;
  final int durationSec;
  final List<String> tags;
}

String? _str(dynamic v) => v is String && v.isNotEmpty ? v : null;

String _titleOf(Map video) {
  final parsed = video['video_text']?['user_display_video_title']?['default']
      ?['parsed_text'];
  if (_str(parsed) != null) return parsed as String;
  return _str(video['action_name']) ?? '';
}

List<String> _tagsOf(Map video) {
  final raw = video['tags'];
  if (raw is! List) return const [];
  return [
    for (final t in raw)
      if (t is Map && _str(t['name']) != null) t['name'] as String,
  ];
}

List<ReelItem> parseReels(dynamic body) {
  if (body is! Map || body['data'] is! List) return const [];
  final out = <ReelItem>[];
  for (final raw in body['data'] as List) {
    if (raw is! Map) continue;
    final mp4 = _str(raw['mp4_url']);
    final hls = _str(raw['hls_url']);
    final url = mp4 ?? hls;
    if (url == null) continue;
    out.add(ReelItem(
      id: '${raw['video_id'] ?? url}',
      videoUrl: url,
      fallbackUrl: mp4 != null ? hls : null,
      downloadUrl: _str(raw['download_url']),
      title: _titleOf(raw),
      thumbUrl: _str(raw['poster_url']) ?? _str(raw['thumbnail_url']),
      avatarUrl: _str(raw['user_avatar']),
      author: _str(raw['user_name']) ?? '',
      likes: '${raw['like_count'] ?? ''}',
      views: raw['view_count'] is num ? (raw['view_count'] as num).toInt() : 0,
      durationSec: raw['duration'] is num ? (raw['duration'] as num).toInt() : 0,
      tags: _tagsOf(raw),
    ));
  }
  return out;
}

/// على iOS/macOS نستخدم URLSession الأصلي (بصمة اتصال مثل Safari)
/// لأن السيرفر يرفض بصمة dart:io بـ 403.
http.Client _makeClient() {
  try {
    if (Platform.isIOS || Platform.isMacOS) {
      return CupertinoClient.defaultSessionConfiguration();
    }
  } catch (_) {}
  return http.Client();
}

class ReelsRepository {
  final Set<String> _seen = <String>{};
  final http.Client _client = _makeClient();

  static final Uri _api = Uri.https('apiv2.tik.porn', '/getnextvideos');
  static const Map<String, String> _headers = {
    'User-Agent': _kUserAgent,
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  Future<List<ReelItem>> _post(int amount) async {
    final req = http.Request('POST', _api)
      ..headers.addAll(_headers)
      ..bodyBytes = utf8.encode(jsonEncode({
        'amount': amount,
        'filter': [],
        'sfw_mode': 0,
        'forcerand': false,
        'first_chunk': false,
      }));
    final res = await http.Response.fromStream(
      await _client.send(req).timeout(const Duration(seconds: 20)),
    );
    return _decode(res);
  }

  Future<List<ReelItem>> _getOnce() async {
    final res = await _client.get(_api, headers: const {
      'User-Agent': _kUserAgent,
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 20));
    return _decode(res);
  }

  List<ReelItem> _decode(http.Response res) {
    if (res.statusCode != 200) {
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final snippet = body.length > 100 ? body.substring(0, 100) : body;
      throw Exception('HTTP ${res.statusCode} $snippet');
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is Map && json['code'] != null && json['code'] != 200) {
      throw Exception('API ${json['code']}: ${json['message']}');
    }
    return parseReels(json);
  }

  Future<List<ReelItem>> _fetch(int amount) async {
    try {
      return await _post(amount);
    } catch (e) {
      // احتياط: إذا فشل الـ POST نجرب GET (يرجع فيديو واحد لكل طلب)
      final out = <ReelItem>[];
      for (var i = 0; i < (amount > 5 ? 5 : amount); i++) {
        try {
          out.addAll(await _getOnce());
        } catch (_) {
          if (out.isEmpty && i == 0) rethrow;
        }
      }
      if (out.isEmpty) rethrow;
      return out;
    }
  }

  /// يرجع فيديوهات جديدة فقط (بدون تكرار) لحد ما يوصل للعدد المطلوب.
  Future<List<ReelItem>> nextBatch(int amount) async {
    final fresh = <ReelItem>[];
    var emptyRounds = 0;
    var rounds = 0;
    while (fresh.length < amount &&
        rounds < 12 &&
        emptyRounds < _kMaxRefetchTries) {
      rounds++;
      final fetched = await _fetch(amount - fresh.length);
      var added = 0;
      for (final item in fetched) {
        if (_seen.add(item.id) && _seen.add('url:${item.videoUrl}')) {
          fresh.add(item);
          added++;
        }
      }
      emptyRounds = added == 0 ? emptyRounds + 1 : 0;
    }
    return fresh;
  }

  void dispose() => _client.close();
}

String _compact(num n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '${n.toInt()}';
}

String _clock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

class ReelsPage extends StatefulWidget {
  const ReelsPage({super.key});

  @override
  State<ReelsPage> createState() => _ReelsPageState();
}

class _ReelsPageState extends State<ReelsPage> with WidgetsBindingObserver {
  final ReelsRepository _repo = ReelsRepository();
  final http.Client _media = _makeClient();
  final PageController _pager = PageController();
  final List<ReelItem> _items = <ReelItem>[];
  final Map<int, VideoPlayerController> _controllers = {};

  /// تقدم الحفظ في الصور لكل ريل (-1 = غير محدد).
  final ValueNotifier<Map<String, double>> _saving =
      ValueNotifier<Map<String, double>>(const {});

  bool _loading = false;
  bool _exhausted = false;
  bool _muted = false;
  bool _clear = false; // Clear mode: يخفي كل الواجهة
  String? _error;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clear = LocalStore.readBool(_kClearKey, fallback: false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // نوقف أي معاينة أو مشغل صغير شغال عشان ما يتداخل الصوت
    unawaited(PreviewManager.instance.stopAndWait());
    unawaited(MiniPlayer.instance.close());
    _loadMore(first: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _pager.dispose();
    _repo.dispose();
    _media.close();
    _saving.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controllers[_current];
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.resumed) {
      c.play();
    } else {
      c.pause();
    }
  }

  Future<void> _loadMore({bool first = false}) async {
    if (_loading || _exhausted) return;
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
      if (first && _items.isNotEmpty) _syncControllers(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  VideoPlayerController _build(String url, int index, {String? fallback}) {
    final c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: _kMediaHeaders,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    c.setLooping(true);
    c.initialize().then((_) {
      // ممكن يكون انحذف أثناء التحميل
      if (!mounted || _controllers[index] != c) return;
      c.setVolume(_muted ? 0 : 1);
      if (index == _current) c.play();
      setState(() {});
    }).catchError((_) {
      if (!mounted || _controllers[index] != c) return;
      // لو الـ mp4 فشل جرّب الـ HLS
      if (fallback != null) {
        c.dispose();
        _controllers[index] = _build(fallback, index);
      }
      setState(() {});
    });
    return c;
  }

  VideoPlayerController _controllerFor(int index) {
    return _controllers.putIfAbsent(index, () {
      final item = _items[index];
      return _build(item.videoUrl, index, fallback: item.fallbackUrl);
    });
  }

  void _retry(int index) {
    if (index < 0 || index >= _items.length) return;
    _controllers.remove(index)?.dispose();
    _controllerFor(index);
    setState(() {});
  }

  /// يحافظ على الحالي + اللي قبله + اللي بعده فقط، والباقي يتحرر.
  void _syncControllers(int index) {
    final keep = <int>{index - 1, index, index + 1}
        .where((i) => i >= 0 && i < _items.length)
        .toSet();
    for (final i in _controllers.keys.toList()) {
      if (!keep.contains(i)) {
        _controllers.remove(i)?.dispose();
      }
    }
    for (final i in keep) {
      _controllerFor(i);
    }
    for (final entry in _controllers.entries) {
      final c = entry.value;
      if (!c.value.isInitialized) continue;
      if (entry.key == index) {
        c.play();
      } else {
        c.pause();
        c.setPlaybackSpeed(1);
        c.seekTo(Duration.zero);
      }
    }
    if (mounted) setState(() {});
  }

  void _onPageChanged(int index) {
    _current = index;
    _syncControllers(index);
    if (index >= _items.length - _kPreloadAhead) _loadMore();
  }

  void _next() {
    if (_current >= _items.length - 1) return;
    _pager.nextPage(duration: Motion.scroll, curve: Motion.curve);
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    for (final c in _controllers.values) {
      if (c.value.isInitialized) c.setVolume(_muted ? 0 : 1);
    }
  }

  void _toggleClear() {
    Haptics.play(Haptic.selection);
    setState(() => _clear = !_clear);
    LocalStore.writeBool(_kClearKey, _clear);
  }

  void _toast(String message) => showToast(context, message, aboveBar: false);

  // ───────────── التحميل داخل التطبيق ─────────────

  Video _videoOf(ReelItem item) => Video(
        id: 'reel_${item.id}',
        title: item.title.isEmpty ? 'Reel by @${item.author}' : item.title,
        thumbnailUrl: item.thumbUrl,
        duration: _clock(Duration(seconds: item.durationSec)),
        views: _compact(item.views),
        likes: item.likes,
        category: 'Reels',
      );

  /// يرجع true إذا بدأ تحميل جديد.
  bool _enqueue(ReelItem item, {bool silent = false}) {
    final url = item.downloadUrl ?? item.videoUrl;
    if (url.toLowerCase().contains('.m3u8')) {
      if (!silent) _toast('This video is a stream and can\u2019t be downloaded.');
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
    store.enqueueDirect(_videoOf(item), url);
    return true;
  }

  void _download(ReelItem item) {
    if (_enqueue(item)) _toast('Downloading\u2026');
  }

  // ───────────── المفضلة ─────────────

  void _toggleFavorite(ReelItem item) {
    final favorites = FavoritesStore.instance;
    final id = 'reel_${item.id}';
    if (favorites.isFavorite(id)) {
      favorites.remove(id);
      _toast('Removed from favorites.');
      return;
    }
    favorites.add(_videoOf(item));
    Haptics.play(Haptic.medium);
    // روابط الريلز مؤقتة، فنحمّل نسخة عشان تشتغل من المفضلة بعدين
    _enqueue(item, silent: true);
    _toast('Added to favorites.');
  }

  // ───────────── قائمة الحفظ ─────────────

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

  // ───────────── الحفظ في الصور ─────────────

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
      file = File('${dir.path}/reel_${item.id}.mp4');
      final req = http.Request('GET', Uri.parse(url))
        ..headers.addAll(_kMediaHeaders);
      final res = await _media.send(req).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      var got = 0;
      final sink = file.openWrite();
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) _setSaving(item.id, got / total);
        }
      } finally {
        await sink.close();
      }
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
    } catch (_) {
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_items.isNotEmpty)
            PageView.builder(
              controller: _pager,
              scrollDirection: Axis.vertical,
              itemCount: _items.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, i) {
                final item = _items[i];
                return _ReelView(
                  key: ValueKey(item.id),
                  item: item,
                  controller: _controllers[i],
                  muted: _muted,
                  saving: _saving,
                  isLast: i == _items.length - 1 && _exhausted,
                  onNext: _next,
                  onMute: _toggleMute,
                  clear: _clear,
                  onFavorite: () => _toggleFavorite(item),
                  onSaveMenu: () => _showSaveMenu(item),
                  onRetry: () => _retry(i),
                );
              },
            )
          else if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            _ErrorView(message: _error!, onRetry: () => _loadMore(first: true))
          else
            Center(
              child: Text(
                'No videos right now.',
                style: AppText.body.copyWith(color: Colors.white70),
              ),
            ),
          if (_error != null && _items.isNotEmpty)
            Positioned(
              bottom: context.safe.bottom + 48,
              left: 16,
              right: 16,
              child: _ErrorView(message: _error!, onRetry: _loadMore),
            ),
          Positioned(
            top: context.safe.top + 4,
            left: 8,
            right: 8,
            child: Row(
              children: [
                AnimatedOpacity(
                  duration: Motion.normal,
                  opacity: _clear ? 0.55 : 1,
                  child: RoundIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    iconSize: 18,
                    tapSize: kMinTapSize,
                    label: 'Back',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
                Expanded(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      duration: Motion.normal,
                      opacity: _clear ? 0 : 1,
                      child: Center(
                        child: Text(
                          'REELS',
                          style: AppText.overline.copyWith(
                            color: Colors.white,
                            shadows: const [
                              Shadow(blurRadius: 8, color: Color(0xCC000000)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  duration: Motion.normal,
                  opacity: _clear ? 0.55 : 1,
                  child: RoundIconButton(
                    icon: _clear
                        ? Icons.visibility_off_rounded
                        : Icons.visibility_rounded,
                    iconSize: 18,
                    tapSize: kMinTapSize,
                    label: _clear ? 'Show controls' : 'Clear mode',
                    onTap: _toggleClear,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReelView extends StatefulWidget {
  const _ReelView({
    super.key,
    required this.item,
    required this.controller,
    required this.muted,
    required this.saving,
    required this.isLast,
    required this.onNext,
    required this.onMute,
    required this.clear,
    required this.onFavorite,
    required this.onSaveMenu,
    required this.onRetry,
  });

  final ReelItem item;
  final VideoPlayerController? controller;
  final bool muted;
  final ValueListenable<Map<String, double>> saving;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback onMute;
  final bool clear;
  final VoidCallback onFavorite;
  final VoidCallback onSaveMenu;
  final VoidCallback onRetry;

  @override
  State<_ReelView> createState() => _ReelViewState();
}

class _ReelViewState extends State<_ReelView> {
  bool _fast = false; // x2 بضغطة مطولة
  Offset _tapAt = Offset.zero;
  int _seekTotal = 0; // مجموع القفزات المتتالية بالثواني
  Timer? _seekTimer;

  VideoPlayerController? get _c => widget.controller;
  bool get _ready => _c != null && _c!.value.isInitialized;

  @override
  void dispose() {
    _seekTimer?.cancel();
    super.dispose();
  }

  void _togglePlay() {
    final c = _c;
    if (!_ready || c == null) return;
    Haptics.play(Haptic.selection);
    c.value.isPlaying ? c.pause() : c.play();
  }

  void _setFast(bool on) {
    final c = _c;
    if (!_ready || c == null || _fast == on) return;
    if (on && !c.value.isPlaying) return;
    c.setPlaybackSpeed(on ? 2 : 1);
    if (on) Haptics.play(Haptic.medium);
    setState(() => _fast = on);
  }

  /// دبل تاب يمين = +10 ثواني، يسار = -10 ثواني
  void _doubleTapSeek() {
    final c = _c;
    if (!_ready || c == null) return;
    final width = context.size?.width ?? 1;
    final x = _tapAt.dx / width;
    if (x > 0.4 && x < 0.6) {
      _togglePlay();
      return;
    }
    final forward = x >= 0.6;
    final dur = c.value.duration;
    var target = c.value.position + (forward ? _kSeekStep : -_kSeekStep);
    if (target < Duration.zero) target = Duration.zero;
    if (target > dur) target = dur;
    c.seekTo(target);
    Haptics.play(Haptic.light);
    setState(() {
      _seekTotal = (_seekTotal.sign == (forward ? 1 : -1) ? _seekTotal : 0) +
          (forward ? 10 : -10);
    });
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekTotal = 0);
    });
  }

  Widget _video(BuildContext context, VideoPlayerController c) {
    final size = c.value.size;
    if (size.isEmpty) return const SizedBox.shrink();
    final screen = MediaQuery.sizeOf(context);
    final videoRatio = size.width / size.height;
    final screenRatio = screen.width / screen.height;
    // الفيديو يظهر كامل بمقياسه الأصلي (16:9 يبقى أفقي، 9:16 يبقى طولي).
    // نملأ الشاشة بس لو النسبتين تقريباً نفس الشي.
    final nearlySame = (videoRatio / screenRatio - 1).abs() < 0.06;
    return Center(
      child: nearlySame
          ? SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: VideoPlayer(c),
                ),
              ),
            )
          : AspectRatio(aspectRatio: videoRatio, child: VideoPlayer(c)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final c = _c;
    final ready = _ready;
    final bottomPad = context.safe.bottom;

    return Stack(
      fit: StackFit.expand,
      children: [
        // خلفية: البوستر مغبّش يعبي الفراغ حول الفيديو
        if (item.thumbUrl != null)
          RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: Image.network(
                item.thumbUrl!,
                fit: BoxFit.cover,
                headers: _kMediaHeaders,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        const ColoredBox(color: Color(0x99000000)),

        // الفيديو + الإيماءات
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _togglePlay,
          onDoubleTapDown: (d) => _tapAt = d.localPosition,
          onDoubleTap: _doubleTapSeek,
          onLongPressStart: (_) => _setFast(true),
          onLongPressEnd: (_) => _setFast(false),
          onLongPressCancel: () => _setFast(false),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (ready && c != null)
                _video(context, c)
              else if (c != null && c.value.hasError)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline_rounded,
                          color: Colors.white54, size: 40),
                      const SizedBox(height: Gaps.md),
                      AppButton(
                        label: 'Try again',
                        icon: Icons.refresh_rounded,
                        style: AppButtonStyle.secondary,
                        onDark: true,
                        onPressed: widget.onRetry,
                      ),
                    ],
                  ),
                )
              else
                const Center(child: CupertinoActivityIndicator(color: Colors.white)),
              if (ready && c != null) _StallSpinner(controller: c),
              // أيقونة الإيقاف
              if (ready && c != null)
                IgnorePointer(
                  child: Center(
                    child: ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: c,
                      builder: (_, v, __) => AnimatedOpacity(
                        duration: Motion.normal,
                        opacity: v.isPlaying ? 0 : 1,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0x73000000),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 44),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),

        // تدرج للقراءة
        _UiFade(
          hidden: widget.clear,
          child: const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.18, 0.55, 1],
                colors: [
                  Color(0x99000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xCC000000),
                ],
              ),
            ),
          ),
          ),
        ),

        // العنوان + معلومات الريل
        Positioned(
          left: 16,
          right: 84,
          bottom: bottomPad + 44,
          child: _UiFade(
            hidden: widget.clear,
            child: IgnorePointer(child: _InfoBlock(item: item)),
          ),
        ),

        // أزرار الجانب
        Positioned(
          right: 10,
          bottom: bottomPad + 40,
          child: _UiFade(
            hidden: widget.clear,
            child: _ActionRail(
              item: item,
              muted: widget.muted,
              saving: widget.saving,
              isLast: widget.isLast,
              onNext: widget.onNext,
              onMute: widget.onMute,
              onFavorite: widget.onFavorite,
              onSaveMenu: widget.onSaveMenu,
            ),
          ),
        ),

        // مؤشر x2
        Positioned(
          top: context.safe.top + 12,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                duration: Motion.quick,
                opacity: _fast ? 1 : 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(Radii.pill),
                    border: Border.all(color: const Color(0x26FFFFFF)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.fast_forward_rounded,
                          color: Colors.white, size: 18),
                      const SizedBox(width: 6),
                      Text('2x',
                          style: AppText.label.copyWith(color: Colors.white)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // مؤشر القفز ±10
        IgnorePointer(
          child: AnimatedOpacity(
            duration: Motion.quick,
            opacity: _seekTotal == 0 ? 0 : 1,
            child: Align(
              alignment:
                  _seekTotal >= 0 ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _seekTotal >= 0
                          ? Icons.forward_10_rounded
                          : Icons.replay_10_rounded,
                      color: Colors.white,
                      size: 44,
                    ),
                    Text(
                      '${_seekTotal >= 0 ? '+' : '\u2212'}${_seekTotal.abs()}s',
                      style: AppText.label.copyWith(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        // شريط التقدم من تحت
        if (ready && c != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomPad + 6,
            child: _UiFade(
              hidden: widget.clear,
              child: _ReelProgressBar(controller: c),
            ),
          ),
      ],
    );
  }
}

class _InfoBlock extends StatelessWidget {
  const _InfoBlock({required this.item});

  final ReelItem item;

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(blurRadius: 8, color: Color(0xCC000000))];
    final title = item.title.isEmpty ? 'Untitled' : item.title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.author.isNotEmpty)
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceHigh,
                  border: Border.all(color: const Color(0x40FFFFFF)),
                ),
                child: item.avatarUrl == null
                    ? const Icon(Icons.person_rounded,
                        size: 18, color: Colors.white70)
                    : Image.network(
                        item.avatarUrl!,
                        fit: BoxFit.cover,
                        headers: _kMediaHeaders,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.person_rounded,
                            size: 18,
                            color: Colors.white70),
                      ),
              ),
              const SizedBox(width: Gaps.sm),
              Flexible(
                child: Text(
                  '@${item.author}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    shadows: shadow,
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: Gaps.sm),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppText.title.copyWith(color: Colors.white, shadows: shadow),
        ),
        if (item.tags.isNotEmpty) ...[
          const SizedBox(height: Gaps.sm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in item.tags.take(3))
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x33FFFFFF),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(
                    '#$t',
                    style: AppText.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: Gaps.sm),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.favorite_rounded, size: 14, color: Colors.white70),
            const SizedBox(width: 4),
            Text(
              item.likes.isEmpty ? '0' : item.likes,
              style: AppText.caption.copyWith(color: Colors.white70),
            ),
            const SizedBox(width: Gaps.md),
            const Icon(Icons.play_arrow_rounded, size: 16, color: Colors.white70),
            const SizedBox(width: 2),
            Text(
              _compact(item.views),
              style: AppText.caption.copyWith(color: Colors.white70),
            ),
            if (item.durationSec > 0) ...[
              const SizedBox(width: Gaps.md),
              const Icon(Icons.schedule_rounded, size: 14, color: Colors.white70),
              const SizedBox(width: 4),
              Text(
                _clock(Duration(seconds: item.durationSec)),
                style: AppText.caption.copyWith(color: Colors.white70),
              ),
            ],
          ],
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
    required this.isLast,
    required this.onNext,
    required this.onMute,
    required this.onFavorite,
    required this.onSaveMenu,
  });

  final ReelItem item;
  final bool muted;
  final ValueListenable<Map<String, double>> saving;
  final bool isLast;
  final VoidCallback onNext;
  final VoidCallback onMute;
  final VoidCallback onFavorite;
  final VoidCallback onSaveMenu;

  @override
  Widget build(BuildContext context) {
    final downloadId = 'reel_${item.id}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // المفضلة
        ListenableBuilder(
          listenable: FavoritesStore.instance,
          builder: (_, __) {
            final fav = FavoritesStore.instance.isFavorite(downloadId);
            return _RailButton(
              icon: fav ? Icons.star_rounded : Icons.star_outline_rounded,
              iconColor: fav ? AppColors.star : Colors.white,
              label: fav ? 'Favorited' : 'Favorite',
              onTap: onFavorite,
            );
          },
        ),
        const SizedBox(height: Gaps.lg),
        // تحميل / حفظ في الصور (قائمة)
        ValueListenableBuilder<Map<String, double>>(
          valueListenable: saving,
          builder: (_, map, __) {
            final saved = map[item.id];
            if (saved != null) {
              return _RailButton(
                icon: Icons.download_rounded,
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
                    icon: Icons.download_rounded,
                    label: 'Save',
                    onTap: onSaveMenu,
                  );
                }
                if (entry.status == DownloadStatus.done) {
                  return _RailButton(
                    icon: Icons.download_done_rounded,
                    label: 'Saved',
                    active: true,
                    onTap: onSaveMenu,
                  );
                }
                if (entry.status == DownloadStatus.failed ||
                    entry.status == DownloadStatus.paused) {
                  return _RailButton(
                    icon: Icons.refresh_rounded,
                    label: 'Retry',
                    onTap: onSaveMenu,
                  );
                }
                return ValueListenableBuilder<int>(
                  valueListenable: entry.bytes,
                  builder: (_, __, ___) {
                    final p = entry.progress;
                    return _RailButton(
                      icon: Icons.download_rounded,
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
        const SizedBox(height: Gaps.lg),
        _RailButton(
          icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          label: muted ? 'Muted' : 'Sound',
          onTap: onMute,
        ),
        const SizedBox(height: Gaps.lg),
        // سكيب للريل اللي بعده
        _RailButton(
          icon: Icons.keyboard_arrow_down_rounded,
          label: 'Skip',
          onTap: isLast ? () {} : onNext,
        ),
      ],
    );
  }
}

/// يخفي/يظهر عناصر الواجهة بنعومة (Clear mode).
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

/// دوّارة التحميل: تطلع بس إذا الفيديو وقف فعلاً (تقطيع)، مو وهو شغال.
class _StallSpinner extends StatefulWidget {
  const _StallSpinner({required this.controller});

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
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
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
    final stalled = v.isInitialized &&
        v.isPlaying &&
        v.isBuffering &&
        DateTime.now().difference(_lastMove) > const Duration(milliseconds: 700);
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
    this.progress,
    this.active = false,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;

  /// null = بدون حلقة، -1 = حلقة غير محددة، 0..1 = نسبة
  final double? progress;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final busy = progress != null;
    return Pressable(
      semanticLabel: label,
      onTap: onTap,
      pressedScale: 0.88,
      child: SizedBox(
        width: 58,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? AppColors.accentStrong : const Color(0x8C000000),
                border: Border.all(color: const Color(0x26FFFFFF)),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (busy)
                    SizedBox(
                      width: 46,
                      height: 46,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        value: progress! < 0 ? null : progress,
                        color: AppColors.accent,
                        backgroundColor: const Color(0x33FFFFFF),
                      ),
                    ),
                  Icon(icon, color: iconColor, size: 22),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: Colors.white,
                fontSize: 11,
                shadows: const [Shadow(blurRadius: 6, color: Color(0xCC000000))],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// شريط تقدم من تحت: يتحرك مع الفيديو، يكبر ويظهر الوقت وقت السحب.
class _ReelProgressBar extends StatefulWidget {
  const _ReelProgressBar({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_ReelProgressBar> createState() => _ReelProgressBarState();
}

class _ReelProgressBarState extends State<_ReelProgressBar> {
  bool _dragging = false;
  bool _wasPlaying = false;
  double _frac = 0;

  VideoPlayerController get _c => widget.controller;

  double _fracAt(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0).toDouble();

  void _start(double dx, double width) {
    _wasPlaying = _c.value.isPlaying;
    _c.pause();
    Haptics.play(Haptic.selection);
    setState(() {
      _dragging = true;
      _frac = _fracAt(dx, width);
    });
    _seek();
  }

  void _update(double dx, double width) {
    setState(() => _frac = _fracAt(dx, width));
    _seek();
  }

  void _seek() {
    final ms = _c.value.duration.inMilliseconds;
    _c.seekTo(Duration(milliseconds: (ms * _frac).round()));
  }

  void _end() {
    if (_wasPlaying) _c.play();
    setState(() => _dragging = false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) => _start(d.localPosition.dx, width),
        onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, width),
        onHorizontalDragEnd: (_) => _end(),
        onHorizontalDragCancel: _end,
        onTapUp: (d) {
          _frac = _fracAt(d.localPosition.dx, width);
          _seek();
        },
        child: SizedBox(
          height: 34,
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _c,
            builder: (_, v, __) {
              final total = v.duration.inMilliseconds;
              final played = total <= 0
                  ? 0.0
                  : (v.position.inMilliseconds / total).clamp(0.0, 1.0);
              final buffered = total <= 0 || v.buffered.isEmpty
                  ? 0.0
                  : (v.buffered.last.end.inMilliseconds / total)
                      .clamp(0.0, 1.0);
              final shown = _dragging ? _frac : played.toDouble();
              final barH = _dragging ? 7.0 : 3.0;
              return Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.bottomLeft,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: AnimatedContainer(
                      duration: Motion.quick,
                      height: barH,
                      margin: EdgeInsets.symmetric(
                          horizontal: _dragging ? 12 : 0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Color(0x33FFFFFF)),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: buffered.toDouble(),
                              child: const ColoredBox(color: Color(0x4DFFFFFF)),
                            ),
                            FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: shown,
                              child:
                                  const ColoredBox(color: AppColors.accent),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_dragging)
                    Positioned(
                      bottom: 36,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xB3000000),
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                          child: Text(
                            '${_clock(Duration(milliseconds: (total * _frac).round()))}'
                            ' / ${_clock(v.duration)}',
                            style:
                                AppText.label.copyWith(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    });
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(Gaps.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(Radii.card),
          border: Border.all(color: AppColors.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.body,
            ),
            const SizedBox(height: Gaps.md),
            AppButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
