import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'error_text.dart';
import 'media_headers.dart';
import 'reel_favorites.dart';
import 'xxx_follow_trans_reels.dart';

const String _creatorSite = 'https://www.xxxfollow.com/';

typedef CreatorReelsLoadMore = Future<List<ReelItem>> Function();
typedef CreatorPlayReels = Future<void> Function(
  List<ReelItem> items,
  int initialIndex,
  CreatorReelsLoadMore loadMore,
);

class XxxFollowCreatorPage extends StatefulWidget {
  const XxxFollowCreatorPage({
    super.key,
    required this.username,
    required this.loadAccount,
    required this.loadMorePosts,
    required this.hasMorePages,
    required this.onPlayReels,
  });

  final String username;
  final Future<XxxFollowAccountSnapshot> Function() loadAccount;
  final Future<List<Map<String, dynamic>>> Function(
    XxxFollowAccountSnapshot account,
  ) loadMorePosts;
  final bool Function() hasMorePages;
  final CreatorPlayReels onPlayReels;

  @override
  State<XxxFollowCreatorPage> createState() => _XxxFollowCreatorPageState();
}

class _XxxFollowCreatorPageState extends State<XxxFollowCreatorPage> {
  XxxFollowAccountSnapshot? _account;
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _moreSearched = false;
  Future<void>? _loadMoreRequest;
  final ScrollController _scroll = ScrollController();
  final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  final Set<String> _postIds = <String>{};
  final Set<String> _reelIds = <String>{};
  final Set<String> _reelUrls = <String>{};
  final List<ReelItem> _reels = <ReelItem>[];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_loadAccount());
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loading || _loadingMore || _moreSearched) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 720) {
      unawaited(_loadMore());
    }
  }

  void _scheduleFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _loadingMore || _moreSearched) return;
      if (_scroll.position.maxScrollExtent < 420) unawaited(_loadMore());
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final account = await widget.loadAccount().timeout(
        const Duration(seconds: 18),
      );
      if (!mounted) return;
      _account = account;
      _mergeRows(account.firstAuthorPosts);
      _moreSearched = !widget.hasMorePages();
      setState(() => _loading = false);
      _scheduleFillViewport();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error, subject: 'creator profile').message;
        _loading = false;
      });
    }
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, value) => MapEntry('$key', value));
    }
    return <String, dynamic>{};
  }

  String _postId(Map<String, dynamic> row) {
    final post = _asMap(row['post']);
    return '${post['id'] ?? ''}'.trim();
  }

  void _mergeRows(List<Map<String, dynamic>> incoming) {
    for (final row in incoming) {
      final id = _postId(row);
      if (id.isEmpty || !_postIds.add(id)) continue;
      _rows.add(row);
    }
    final parsed = XxxFollowTransParser.toReelsFromRows(
      _rows,
      baseUri: Uri.parse(_creatorSite),
      creator: _account?.profile,
    );
    for (final reel in parsed) {
      if (_reelIds.add(reel.id) && _reelUrls.add(reel.videoUrl)) {
        _reels.add(reel);
      }
    }
  }

  Future<void> _loadMore() {
    final pending = _loadMoreRequest;
    if (pending != null) return pending;
    final account = _account;
    if (account == null || _moreSearched) return Future<void>.value();
    late final Future<void> request;
    request = _performLoadMore(account).whenComplete(() {
      if (identical(_loadMoreRequest, request)) _loadMoreRequest = null;
    });
    _loadMoreRequest = request;
    return request;
  }

  Future<void> _performLoadMore(XxxFollowAccountSnapshot account) async {
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final posts = await widget.loadMorePosts(account).timeout(
        const Duration(seconds: 70),
      );
      if (!mounted) return;
      final oldCount = _reels.length;
      _mergeRows(posts);
      final addedVideos = _reels.length > oldCount;
      setState(() {
        _loadingMore = false;
        _moreSearched = !widget.hasMorePages();
      });
      if (addedVideos) _scheduleFillViewport();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = describeError(error, subject: 'creator videos').message;
      });
    }
  }

  String _compact(int? value) {
    if (value == null) return '—';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return '$value';
  }

  String _joined(String raw) {
    if (raw.isEmpty) return '';
    final value = raw.length >= 10 ? raw.substring(0, 10) : raw;
    return value;
  }

  Future<List<ReelItem>> _loadMoreForReels() async {
    if (_account == null || _moreSearched) return const <ReelItem>[];
    final oldCount = _reels.length;
    // Share the same in-flight request with the profile's scroll listener.
    // This prevents a quick swipe from mistaking an already-running page for
    // an empty/end-of-feed response.
    await _loadMore();
    if (!mounted || _reels.length <= oldCount) return const <ReelItem>[];
    return List<ReelItem>.unmodifiable(_reels.skip(oldCount));
  }

  Future<void> _openInReels(int index) async {
    if (index < 0 || index >= _reels.length || _reels.isEmpty) return;
    await widget.onPlayReels(
      List<ReelItem>.unmodifiable(_reels),
      index,
      _loadMoreForReels,
    );
  }

  String _duration(int seconds) {
    if (seconds <= 0) return '';
    final minutes = seconds ~/ 60;
    final remaining = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remaining';
  }

  Widget _avatar(XxxFollowCreatorProfile profile, double size) {
    final initials = profile.displayName.trim().isEmpty
        ? '?'
        : profile.displayName.trim()[0].toUpperCase();
    final url = profile.avatarUrl;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF242833),
        border: Border.all(color: const Color(0xFF5D6680), width: 1.5),
      ),
      child: ClipOval(
        child: url == null
            ? ColoredBox(
                color: const Color(0xFF343A48),
                child: Center(
                  child: Text(
                    initials,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: size * .35,
                    ),
                  ),
                ),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                headers: imageHeadersFor('$_creatorSite${profile.username}'),
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: const Color(0xFF343A48),
                  child: Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: size * .35,
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _cover(XxxFollowCreatorProfile profile) {
    final url = profile.coverPictureUrl;
    return SizedBox(
      height: 156,
      width: double.infinity,
      child: url == null
          ? const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF343B50), Color(0xFF151821), Color(0xFF090A0E)],
                ),
              ),
            )
          : Image.network(
              url,
              fit: BoxFit.cover,
              headers: imageHeadersFor('$_creatorSite${profile.username}'),
              errorBuilder: (_, __, ___) => const ColoredBox(
                color: Color(0xFF202431),
              ),
            ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ],
        ),
      );

  Widget _profileHeader(XxxFollowCreatorProfile profile) {
    final name = profile.displayName.isEmpty ? profile.username : profile.displayName;
    final totalLikes = _reels.fold<int>(0, (total, reel) => total + reel.likes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            _cover(profile),
            Positioned(
              left: 18,
              bottom: -43,
              child: _avatar(profile, 92),
            ),
            if (profile.isStreaming)
              Positioned(
                right: 14,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE53955),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 52),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              Text(
                '@${profile.username}',
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
              if ((profile.bio ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  profile.bio!,
                  style: TextStyle(color: Colors.white.withValues(alpha: .86), height: 1.4),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  _stat('Videos', _compact(profile.postsCount ?? _reels.length)),
                  _stat('Followers', _compact(profile.followersCount)),
                  _stat('Following', _compact(profile.followingCount)),
                  _stat('Views', _compact(profile.viewsCount)),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (profile.gender.isNotEmpty)
                    _metaChip(profile.gender.toUpperCase(), CupertinoIcons.person_2),
                  if (profile.createdAt.isNotEmpty)
                    _metaChip('Joined ${_joined(profile.createdAt)}', CupertinoIcons.calendar),
                  if (profile.isStreaming)
                    _metaChip('Streaming now', CupertinoIcons.dot_radiowaves_left_right),
                ],
              ),
              const SizedBox(height: 18),
              Divider(color: Colors.white.withValues(alpha: .12), height: 1),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(CupertinoIcons.play_rectangle_fill, color: Colors.white, size: 17),
                  const SizedBox(width: 8),
                  const Text(
                    'Videos',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  Text(
                    '${_reels.length}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (profile.likesCount != null)
                Text(
                  '${_compact(profile.likesCount)} likes',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                )
              else if (totalLikes > 0)
                Text(
                  '${_compact(totalLikes)} likes',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metaChip(String label, IconData icon) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: .09)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white60, size: 13),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      );

  Widget _videoTile(ReelItem item, int index) {
    final thumb = item.thumbUrl;
    return InkWell(
      onTap: () => unawaited(_openInReels(index)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumb == null)
            const ColoredBox(color: Color(0xFF242936))
          else
            Image.network(
              thumb,
              fit: BoxFit.cover,
              headers: imageHeadersFor(item.mediaReferer ?? _creatorSite),
              errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF242936)),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0x99000000)],
                stops: [.55, 1],
              ),
            ),
          ),
          const Center(
            child: Icon(CupertinoIcons.play_fill, color: Colors.white, size: 27),
          ),
          Positioned(
            left: 6,
            right: 6,
            bottom: 6,
            child: Row(
              children: [
                const Icon(CupertinoIcons.heart_fill, color: Colors.white, size: 11),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _compact(item.likes),
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                ),
                if (item.durationSec > 0)
                  Text(
                    _duration(item.durationSec),
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _account?.profile;
    return Stack(
      fit: StackFit.expand,
      children: [
        Scaffold(
      backgroundColor: const Color(0xFF090A0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF090A0E),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          profile == null ? '@${widget.username}' : '@${profile.username}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator(color: Colors.white, radius: 14))
          : _error != null && _account == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(CupertinoIcons.exclamationmark_triangle, color: Colors.white60, size: 30),
                        const SizedBox(height: 12),
                        Text(
                          'Could not load @${widget.username}.\n$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, height: 1.4),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(onPressed: _loadAccount, child: const Text('Try again')),
                      ],
                    ),
                  ),
                )
              : CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(child: _profileHeader(profile!)),
                    if (_error != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                          ),
                        ),
                      ),
                    if (_reels.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        sliver: SliverGrid(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _videoTile(_reels[index], index),
                            childCount: _reels.length,
                          ),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 2,
                            mainAxisSpacing: 2,
                            childAspectRatio: .64,
                          ),
                        ),
                      )
                    else
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Center(
                            child: Text('No videos yet.', style: TextStyle(color: Colors.white60)),
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
                        child: _loadingMore
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CupertinoActivityIndicator(color: Colors.white70),
                                ),
                              )
                            : _moreSearched
                                ? const SizedBox.shrink()
                                : OutlinedButton.icon(
                                    onPressed: _loadMore,
                                    icon: Icon(
                                      _error != null
                                          ? CupertinoIcons.refresh
                                          : CupertinoIcons.cloud_download,
                                    ),
                                    label: Text(
                                      _error != null
                                          ? 'Try again'
                                          : 'Load more videos from this creator',
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.white,
                                      side: BorderSide(color: Colors.white.withValues(alpha: .24)),
                                      padding: const EdgeInsets.symmetric(vertical: 13),
                                    ),
                                  ),
                      ),
                    ),
                  ],
                ),
        ),
        Positioned(
          top: 0,
          bottom: 0,
          right: 0,
          width: 22,
          child: _CreatorRightEdgeBackGesture(
            onBack: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }
}

class _CreatorRightEdgeBackGesture extends StatefulWidget {
  const _CreatorRightEdgeBackGesture({required this.onBack});

  final VoidCallback onBack;

  @override
  State<_CreatorRightEdgeBackGesture> createState() =>
      _CreatorRightEdgeBackGestureState();
}

class _CreatorRightEdgeBackGestureState
    extends State<_CreatorRightEdgeBackGesture> {
  double _distance = 0;
  bool _didPop = false;

  void _trigger() {
    if (_didPop) return;
    _didPop = true;
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) {
          _distance = 0;
          _didPop = false;
        },
        onHorizontalDragUpdate: (details) {
          _distance += details.delta.dx;
          // Start at the RIGHT edge and pull LEFT to go back.
          if (_distance <= -24) _trigger();
        },
        onHorizontalDragEnd: (details) {
          if (!_didPop &&
              _distance <= -8 &&
              (details.primaryVelocity ?? 0) < -260) {
            _trigger();
          }
        },
        child: const SizedBox.expand(),
      );
}
