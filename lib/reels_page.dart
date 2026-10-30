import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

const List<String> _kSites = ['tik.porn'];
const String _kUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7_1 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 '
    'Mobile/15E148 Safari/604.1';

String _mediaSite = 'tik.porn';

const int _kFirstBatch = 20; // الدفعة الأولى
const int _kNextBatch = 20; // كل دفعة بعدها
const int _kPreloadAhead = 4; // يطلب دفعة جديدة لما يبقى 4 ريلز للنهاية
const int _kMaxRefetchTries = 4; // إذا الدفعة كلها مكررة

class ReelItem {
  const ReelItem({
    required this.id,
    required this.videoUrl,
    this.title = '',
    this.thumbUrl,
    this.author = '',
    this.likes = '',
    this.views = 0,
    this.fallbackUrl,
  });

  final String id;
  final String videoUrl; // mp4_url
  final String? fallbackUrl; // hls_url
  final String title;
  final String? thumbUrl;
  final String author;
  final String likes;
  final int views;
}

String? _str(dynamic v) => v is String && v.isNotEmpty ? v : null;

String _titleOf(Map video) {
  final parsed = video['video_text']?['user_display_video_title']?['default']
      ?['parsed_text'];
  if (_str(parsed) != null) return parsed as String;
  return _str(video['action_name']) ?? '';
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
      title: _titleOf(raw),
      thumbUrl: _str(raw['poster_url']) ?? _str(raw['thumbnail_url']),
      author: _str(raw['user_name']) ?? '',
      likes: '${raw['like_count'] ?? ''}',
      views: raw['view_count'] is num ? (raw['view_count'] as num).toInt() : 0,
    ));
  }
  return out;
}

class ReelsRepository {
  final Set<String> _seen = <String>{};
  final http.Client _client = http.Client();

  String _site = _kSites.first;

  Future<List<ReelItem>> _fetchFrom(String site, int amount) async {
    final res = await _client
        .post(
          Uri.parse('https://apiv2.$site/getnextvideos'),
          headers: {
            'User-Agent': _kUserAgent,
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Content-Type': 'application/json',
            'Origin': 'https://$site',
            'Referer': 'https://$site/',
            'Sec-Fetch-Dest': 'empty',
            'Sec-Fetch-Mode': 'cors',
            'Sec-Fetch-Site': 'same-site',
          },
          body: jsonEncode({
            'amount': amount,
            'filter': [],
            'sfw_mode': 0,
            'forcerand': false,
            'first_chunk': false,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      final body = utf8.decode(res.bodyBytes, allowMalformed: true);
      final snippet = body.length > 120 ? body.substring(0, 120) : body;
      throw Exception('HTTP ${res.statusCode} [$site] $snippet');
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is Map && json['code'] != null && json['code'] != 200) {
      throw Exception('API ${json['code']}: ${json['message']}');
    }
    return parseReels(json);
  }

  Future<List<ReelItem>> _fetch(int amount) async {
    Object? lastError;
    final order = [_site, ..._kSites.where((e) => e != _site)];
    for (final site in order) {
      try {
        final items = await _fetchFrom(site, amount);
        _site = site;
        _mediaSite = site;
        return items;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? Exception('Request failed');
  }

  /// يرجع دفعة جديدة بدون أي ريل انعرض قبل. إذا طلع كله مكرر يعيد الطلب.
  Future<List<ReelItem>> nextBatch(int amount) async {
    for (var attempt = 0; attempt < _kMaxRefetchTries; attempt++) {
      final fetched = await _fetch(amount);
      final fresh = <ReelItem>[];
      for (final item in fetched) {
        if (_seen.add(item.id) && _seen.add('url:${item.videoUrl}')) {
          fresh.add(item);
        }
      }
      if (fresh.isNotEmpty) return fresh;
    }
    return const [];
  }

  void dispose() => _client.close();
}

class ReelsPage extends StatefulWidget {
  const ReelsPage({super.key});

  @override
  State<ReelsPage> createState() => _ReelsPageState();
}

class _ReelsPageState extends State<ReelsPage> {
  final ReelsRepository _repo = ReelsRepository();
  final PageController _pager = PageController();
  final List<ReelItem> _items = <ReelItem>[];
  final Map<int, VideoPlayerController> _controllers = {};

  bool _loading = false;
  bool _exhausted = false;
  String? _error;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadMore(first: true);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final c in _controllers.values) {
      c.dispose();
    }
    _pager.dispose();
    _repo.dispose();
    super.dispose();
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
      httpHeaders: {
        'User-Agent': _kUserAgent,
        'Referer': 'https://$_mediaSite/',
        'Origin': 'https://$_mediaSite',
        'Accept': '*/*',
      },
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    c.setLooping(true);
    c.initialize().then((_) {
      if (!mounted) return;
      if (index == _current) c.play();
      setState(() {});
    }).catchError((_) {
      if (!mounted) return;
      // لو الـ mp4 فشل جرّب الـ HLS
      if (fallback != null && _controllers[index] == c) {
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
              itemBuilder: (context, i) => _ReelView(
                item: _items[i],
                controller: _controllers[i],
              ),
            )
          else if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            _ErrorView(message: _error!, onRetry: () => _loadMore(first: true))
          else
            const Center(
              child: Text('ما كو فيديوهات',
                  style: TextStyle(color: Colors.white70)),
            ),
          if (_loading && _items.isNotEmpty)
            const Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (_error != null && _items.isNotEmpty)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: _ErrorView(message: _error!, onRetry: _loadMore),
            ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReelView extends StatelessWidget {
  const _ReelView({required this.item, required this.controller});

  final ReelItem item;
  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c != null && c.value.isInitialized;
    return GestureDetector(
      onTap: () {
        if (!ready) return;
        c.value.isPlaying ? c.pause() : c.play();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (item.thumbUrl != null && !ready)
            Image.network(
              item.thumbUrl!,
              fit: BoxFit.cover,
              headers: {
                'User-Agent': _kUserAgent,
                'Referer': 'https://$_mediaSite/',
              },
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          if (ready)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: c.value.size.width,
                height: c.value.size.height,
                child: VideoPlayer(c),
              ),
            )
          else if (c != null && c.value.hasError)
            const Center(
              child: Icon(Icons.error_outline, color: Colors.white54, size: 40),
            )
          else
            const Center(child: CircularProgressIndicator()),
          Positioned(
            left: 16,
            right: 16,
            bottom: 40,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.author.isNotEmpty)
                  Text(
                    '@${item.author}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                    ),
                  ),
                if (item.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                      ),
                    ),
                  ),
                if (item.likes.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '♥ ${item.likes}   ▶ ${item.views}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          if (ready)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(
                c,
                allowScrubbing: true,
                padding: EdgeInsets.zero,
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
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            FilledButton(onPressed: onRetry, child: const Text('إعادة المحاولة')),
          ],
        ),
      ),
    );
  }
}
