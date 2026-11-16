import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'content_source.dart';
import 'app_theme.dart';
import 'download_store.dart';
import 'error_text.dart';
import 'local_store.dart';
import 'offline_listing_cache.dart';
import 'models.dart';
import 'playback_launcher.dart';
import 'playback_progress.dart';
import 'reel_favorites.dart';
import 'reels_page.dart';
import 'request_cache.dart';
import 'touch.dart';
import 'preview_manager.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/continue_row.dart';
import 'widgets/dialogs.dart';
import 'widgets/home_hero.dart';
import 'widgets/library_view.dart';
import 'widgets/search_overlay.dart';
import 'widgets/settings_view.dart';
import 'widgets/content_source_picker.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';
import 'services/remote_config_service.dart';

class _FastSectionPagePhysics extends PageScrollPhysics {
  const _FastSectionPagePhysics({super.parent});

  @override
  double get minFlingDistance => 8;

  @override
  double get minFlingVelocity => 180;

  @override
  SpringDescription get spring => const SpringDescription(
        mass: 0.32,
        stiffness: 900,
        damping: 34,
      );

  @override
  _FastSectionPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _FastSectionPagePhysics(parent: buildParent(ancestor));
}

enum _Section { home, reels, library, settings }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  static const List<_Section> _sectionOrder = <_Section>[
    _Section.home,
    _Section.reels,
    _Section.library,
    _Section.settings,
  ];

  List<_Section> get _availableSections => _sectionOrder
      .where((section) =>
          section != _Section.reels ||
          RemoteConfigService.instance.isFeatureEnabled('reels'))
      .toList();

  static const int _pageSize = 12;

  static const int _maxEmptyPages = 3;

  static const String _hintsKey = 'hints_v1';

  final ScrollController _scroll = ScrollController();

  final List<Video> _videos = <Video>[];
  Video? _featured;
  List<Video> _gridVideos = const <Video>[];

  int _page = 0;
  int _generation = 0;
  int _emptyPages = 0;
  bool _sourceChoiceReady = false;
  bool _loading = false;
  bool _hasMore = false;
  bool _playingFeatured = false;
  final ValueNotifier<bool> _search = ValueNotifier<bool>(false);
  bool get _searchOpen => _search.value;
  _Section _section = _Section.home;
  Widget? _reelsPage;
  Widget? _libraryPage;
  Widget? _settingsPage;
  FriendlyError? _error;

  late final PageController _sectionPager = PageController(initialPage: 0, keepPage: false);
  bool _sectionDragInProgress = false;

  String _homeCacheKey(int page) =>
      'home|${videoRepository.source.name}|$page';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    RemoteConfigService.instance.addListener(_onRemoteConfigChanged);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_promptForContentSource());
    });
  }

  Future<void> _promptForContentSource() async {
    if (!mounted || _sourceChoiceReady) return;
    final selected = await showContentSourcePicker(
      context,
      initialSource: AppSettings.instance.contentSource,
      requiredChoice: true,
    );
    if (!mounted) return;
    final source = selected ?? AppSettings.instance.contentSource;
    if (source != videoRepository.source) {
      _changeContentSource(source);
    } else {
      setState(() => _sourceChoiceReady = true);
      unawaited(_loadPage(reset: true));
    }
  }

  Timer? _offlineTimer;
  ({LibrarySegment segment, int token})? _libraryRequest;
  int _requestToken = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_probeConnection());
  }

  void _watchConnection() {
    _offlineTimer?.cancel();
    _offlineTimer = Timer(const Duration(seconds: 15), _probeConnection);
  }

  Future<void> _probeConnection() async {
    if (!mounted || _loading || _videos.isNotEmpty) return;
    if (_error?.offline != true) return;
    final source = videoRepository.source;
    final key = _homeCacheKey(0);
    try {
      final result = await listingCache.fetch(
        key,
        () => videoRepository.getVideos(
          page: 0,
          pageSize: _pageSize,
        ),
      );
      OfflineListingCache.write(key, result);
      if (!mounted ||
          source != videoRepository.source ||
          _videos.isNotEmpty) {
        return;
      }
      unawaited(_loadPage(reset: true));
    } catch (_) {
      if (mounted) _watchConnection();
    }
  }

  void _showDownloads() {
    if (!RemoteConfigService.instance.isFeatureEnabled('downloads')) return;
    _libraryRequest = (
      segment: LibrarySegment.downloads,
      token: ++_requestToken,
    );
    _transitionToSection(_Section.library);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RemoteConfigService.instance.removeListener(_onRemoteConfigChanged);
    _offlineTimer?.cancel();
    _sectionPager.dispose();
    _search.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onRemoteConfigChanged() {
    if (!mounted) return;
    final remote = RemoteConfigService.instance;
    if (_section == _Section.reels && !remote.isFeatureEnabled('reels')) {
      _section = _Section.home;
    }
    if (_searchOpen && !remote.isFeatureEnabled('search')) {
      _search.value = false;
    }
    _sectionDragInProgress = false;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sectionPager.hasClients) return;
      final sections = _availableSections;
      final index = sections.indexOf(_section);
      if (index >= 0) _sectionPager.jumpToPage(index);
    });
  }

  bool _heroVisible = true;
  double _heroLimit = 200;

  void _onScroll() {
    _maybeLoadMore();
    final visible = !_scroll.hasClients || _scroll.offset < _heroLimit;
    if (visible != _heroVisible) setState(() => _heroVisible = visible);
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loading || !_hasMore) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 800) _loadPage();
  }

  void _scheduleFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading || !_hasMore || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent < 100) _loadPage();
    });
  }

  void _recomputeDerived() {
    _featured = _videos.isNotEmpty ? _videos.first : null;
    _gridVideos = _videos.length > 1
        ? List<Video>.unmodifiable(_videos.skip(1))
        : const <Video>[];
  }

  void _applyPage(List<Video> result, int requestedPage) {
    final seenIds = _videos.map((video) => video.id).toSet();
    final fresh = <Video>[];
    for (final video in result) {
      if (seenIds.add(video.id)) fresh.add(video);
    }
    _videos.addAll(fresh);
    _recomputeDerived();
    _page = requestedPage + 1;
    _emptyPages = fresh.isEmpty ? _emptyPages + 1 : 0;
    _hasMore = result.isNotEmpty && _emptyPages < _maxEmptyPages;
    _loading = false;
  }

  Future<void> _loadPage({bool reset = false}) async {
    if (_loading && !reset) return;
    final requestGeneration = reset ? ++_generation : _generation;
    final requestedPage = reset ? 0 : _page;
    if (!_sourceChoiceReady) return;
    // Home always uses the selected site's normal catalogue scraper.
    // XXXFollow is intentionally isolated to the dedicated Trans Reels feed.
    final key = _homeCacheKey(requestedPage);
    final cached = listingCache.peek(key);
    if (cached != null) {
      setState(() {
        _error = null;
        if (reset) {
          _videos.clear();
          _page = 0;
          _emptyPages = 0;
        }
        _applyPage(cached, requestedPage);
      });
      if (_hasMore) _scheduleFillViewport();
      return;
    }

    final offline = OfflineListingCache.read(key);
    if (offline != null) {
      setState(() {
        _error = null;
        if (reset) {
          _videos.clear();
          _recomputeDerived();
          _page = 0;
          _emptyPages = 0;
          _hasMore = true;
        }
        _applyPage(offline, requestedPage);
        // Keep the small loading state while a fresh network copy is fetched.
        _loading = true;
      });
      unawaited(
        _revalidateOfflinePage(
          key: key,
          page: requestedPage,
          generation: requestGeneration,
        ),
      );
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _videos.clear();
        _recomputeDerived();
        _page = 0;
        _emptyPages = 0;
        _hasMore = true;
      }
    });

    try {
      final result = await listingCache.fetch(
        key,
        () => videoRepository.getVideos(
          page: requestedPage,
          pageSize: _pageSize,
        ),
      );
      if (!mounted || requestGeneration != _generation) return;
      OfflineListingCache.write(key, result);

      setState(() => _applyPage(result, requestedPage));
      if (_hasMore) _scheduleFillViewport();
      _maybeShowPreviewHint();
    } catch (error) {
      if (!mounted || requestGeneration != _generation) return;
      setState(() {
        _loading = false;
        _hasMore = false;
        _error = describeError(error);
      });
      if (_error?.offline == true && _videos.isEmpty) _watchConnection();
    }
  }

  Future<void> _revalidateOfflinePage({
    required String key,
    required int page,
    required int generation,
  }) async {
    try {
      final result = await listingCache.fetch(
        key,
        () => videoRepository.getVideos(
          page: page,
          pageSize: _pageSize,
        ),
        force: true,
      );
      OfflineListingCache.write(key, result);
    } catch (_) {
      // Keep the last successful page visible when the connection is weak.
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
        if (_hasMore) _scheduleFillViewport();
      }
    }
  }

  Future<void> _refresh() async {
    Haptics.play(Haptic.light);
    final generation = ++_generation;
    try {
      final key = _homeCacheKey(0);
      final result = await listingCache.fetch(
        key,
        () => videoRepository.getVideos(
          page: 0,
          pageSize: _pageSize,
        ),
        force: true,
      );
      if (!mounted || generation != _generation) return;
      OfflineListingCache.write(key, result);
      final seen = <String>{};
      final fresh = <Video>[
        for (final video in result)
          if (seen.add(video.id)) video,
      ];
      setState(() {
        _videos
          ..clear()
          ..addAll(fresh);
        _recomputeDerived();
        _page = 1;
        _emptyPages = 0;
        _hasMore = result.isNotEmpty;
        _loading = false;
        _error = null;
      });
      if (_hasMore) _scheduleFillViewport();
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _loading = false);
      _toast('Couldn\u2019t refresh. Check your connection.');
    }
  }

  void _maybeShowPreviewHint() {
    if (_videos.isEmpty) return;
    final shown = LocalStore.readList(_hintsKey);
    if (shown.contains('preview')) return;
    LocalStore.writeList(_hintsKey, <String>[...shown, 'preview']);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toast('Tip: press and hold a video to preview it');
    });
  }

  void _scrollToTop() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    _scroll.animateTo(0, duration: Motion.scroll, curve: Motion.curve);
  }

  void _toast(String message) => showToast(context, message);

  void _handleBack() {
    if (_searchOpen) {
      _closeSearch();
    } else if (_section != _Section.home) {
      PreviewManager.instance.stopNow(fade: false);
      _transitionToSection(_Section.home);
    }
  }

  void _openSearch() {
    if (!RemoteConfigService.instance.isFeatureEnabled('search')) return;
    if (_searchOpen) return;
    PreviewManager.instance.stopNow(fade: false);
    _search.value = true;
    setState(() {});
  }

  void _closeSearch() {
    if (!_searchOpen) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _search.value = false;
    setState(() {});
  }

  /// Saved Reels reopen in a vertical Reels queue so favorites from all
  /// content genres can be browsed without switching to the standard player.
  Future<void> _openSavedReel(Video video) async {
    final playableSource = ReelFavorites.instance.sourceFor(video.id);
    final items = ReelFavorites.instance.allItems;
    final selectedIndex = items.indexWhere(
      (item) => ReelFavorites.videoId(item.id) == video.id,
    );
    if (playableSource == null || selectedIndex < 0) {
      // Keep legacy downloaded-only reels playable through the standard player.
      if (DownloadStore.instance.localPath(video.id) != null) {
        final error = await launchPlayer(
          context,
          video.copyWith(streamUrl: playableSource?.url ?? ''),
          source: playableSource,
        );
        if (!mounted) return;
        if (error != null) _toast(error);
        return;
      }
      _toast('This reel can’t be opened anymore.');
      return;
    }

    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context,
        builder: (_) => ReelsPage(
          active: true,
          bottomInset: 0,
          source: videoRepository.source,
          initialItems: items,
          initialIndex: selectedIndex,
          initialItemsOnly: true,
          onExitToPrevious: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openDetails(Video video, List<Video> queue) async {
    if (video.id.startsWith('reel_')) {
      await _openSavedReel(video);
      return;
    }
    await Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context,
        builder: (_) => VideoDetailsPage(video: video, queue: queue),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  void _commitSectionPage([int? requestedIndex]) {
    if (!mounted) return;
    final sections = _availableSections;
    if (sections.isEmpty) return;
    final page = requestedIndex ??
        (_sectionPager.hasClients
            ? (_sectionPager.page ?? 0).round()
            : sections.indexOf(_section));
    final safeIndex = page.clamp(0, sections.length - 1).toInt();
    final destination = sections[safeIndex];
    final changed = destination != _section;
    if (_sectionDragInProgress || changed) {
      setState(() {
        _section = destination;
        _sectionDragInProgress = false;
      });
      if (changed) {
        PreviewManager.instance.stopNow(fade: false);
        Haptics.play(Haptic.selection);
      }
    }
  }

  bool _onSectionScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      if (!_sectionDragInProgress) {
        setState(() => _sectionDragInProgress = true);
      }
    } else if (notification is ScrollEndNotification) {
      _commitSectionPage();
    }
    return false;
  }

  void _transitionToSection(_Section destination) {
    final sections = _availableSections;
    final targetIndex = sections.indexOf(destination);
    if (targetIndex < 0) return;
    final currentPage = _sectionPager.hasClients
        ? (_sectionPager.page ?? sections.indexOf(_section)).round()
        : sections.indexOf(_section);
    if (currentPage == targetIndex && _section == destination &&
        !_sectionDragInProgress) {
      return;
    }

    PreviewManager.instance.stopNow(fade: false);
    if (!_sectionDragInProgress) {
      setState(() => _sectionDragInProgress = true);
    }
    if (!_sectionPager.hasClients) {
      setState(() {
        _section = destination;
        _sectionDragInProgress = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sectionPager.hasClients) {
          _sectionPager.jumpToPage(targetIndex);
        }
      });
      return;
    }
    unawaited(
      _sectionPager
          .animateToPage(
            targetIndex,
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
          )
          .then((_) {
        if (!mounted || !_sectionPager.hasClients) return;
        final settled = (_sectionPager.page ?? -1).round();
        if (settled == targetIndex) _commitSectionPage(targetIndex);
      }).catchError((Object _) {
        // A newer tab selection can safely interrupt an in-flight page change.
      }),
    );
  }

  void _onTabSelect(AppTab tab) {
    PreviewManager.instance.stopNow(fade: false);
    switch (tab) {
      case AppTab.home:
        if (_searchOpen) _closeSearch();
        if (_section == _Section.home && !_sectionDragInProgress) {
          _scrollToTop();
        } else {
          _transitionToSection(_Section.home);
        }
      case AppTab.search:
        _openSearch();
      case AppTab.reels:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.reels || _sectionDragInProgress) {
          _transitionToSection(_Section.reels);
        }
      case AppTab.library:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.library || _sectionDragInProgress) {
          _transitionToSection(_Section.library);
        }
      case AppTab.settings:
        if (_searchOpen) _closeSearch();
        if (_section != _Section.settings || _sectionDragInProgress) {
          _transitionToSection(_Section.settings);
        }
    }
  }

  KeyEventResult _onDesktopNavigationKey(FocusNode node, KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.windows ||
        event is! KeyDownEvent ||
        _searchOpen) {
      return KeyEventResult.ignored;
    }

    // Let text inputs keep their normal caret movement. Arrow keys outside a
    // text field provide predictable tab navigation throughout the desktop UI.
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }

    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => -1,
      LogicalKeyboardKey.arrowRight => 1,
      _ => 0,
    };
    if (delta == 0) return KeyEventResult.ignored;
    final sections = _availableSections;
    final current = sections.indexOf(_section);
    final next = (current + delta).clamp(0, sections.length - 1);
    if (next == current) return KeyEventResult.handled;
    _transitionToSection(sections[next]);
    return KeyEventResult.handled;
  }

  Future<void> _resume(Video video) async {
    final error = await launchPlayer(
      context,
      video,
      startAt: PlaybackProgress.instance.resumePosition(video.id),
    );
    if (!mounted) return;
    setState(() {});
    if (error != null) _toast(error);
  }

  Future<void> _playFeatured() async {
    final video = _featured;
    if (video == null || _playingFeatured) return;
    setState(() => _playingFeatured = true);
    final error = await launchPlayer(
      context,
      video,
      startAt: PlaybackProgress.instance.resumePosition(video.id),
      queue: List<Video>.of(_videos),
    );
    if (!mounted) return;
    setState(() => _playingFeatured = false);
    if (error != null) _toast(error);
  }

  void _changeContentSource(ContentSource source) {
    if (source == videoRepository.source) return;
    Haptics.play(Haptic.selection);
    PreviewManager.instance.stopNow(fade: false);
    videoRepository.setSource(source);
    AppSettings.instance.setContentSource(source);
    clearRequestCaches();
    _libraryPage = null;
    setState(() {
      _sourceChoiceReady = true;
      _videos.clear();
      _recomputeDerived();
      _page = 0;
      _emptyPages = 0;
      _loading = false;
      _hasMore = true;
      _error = null;
    });
    _scrollToTop();
    unawaited(_loadPage(reset: true));
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    // The body extends behind the translucent tab bar; keep a scroll inset so
    // the last card can still be brought fully above the glass surface.
    final windowsDesktop = defaultTargetPlatform == TargetPlatform.windows;
    final bottomInset = windowsDesktop
        ? 24.0
        : appBottomBarHeight(context) + context.safe.bottom;
    final featured = _featured;
    final firstLoad = _videos.isEmpty && (_loading || !_sourceChoiceReady);
    final resume = featured == null
        ? null
        : PlaybackProgress.instance.resumePosition(featured.id);
    final screen = MediaQuery.sizeOf(context);
    _heroLimit = math.min(screen.height * 0.48, 450.0).toDouble() +
        context.safe.top +
        Gaps.sm -
        30;
    final darkMode = AppColors.palette.brightness == Brightness.dark;

    final reelsActive = _section == _Section.reels;
    final libraryActive = _section == _Section.library;
    final settingsActive = _section == _Section.settings;
    final settingsVisible = settingsActive || _settingsPage != null;
    // Keep the Reels page available as the real PageView child, not a temporary
    // empty placeholder. It stays inactive until the user settles on the tab.
    _reelsPage = ReelsPage(
      key: const ValueKey<String>('reels'),
      active: reelsActive && !_searchOpen && !_sectionDragInProgress,
      bottomInset: context.safe.bottom + 4,
      source: videoRepository.source,
      onExitToPrevious: () => _transitionToSection(_Section.home),
    );
    if (libraryActive || _libraryPage == null) {
      // Prebuild Library once, so the first swipe does not land on a blank
      // frame while its tab subtree is created. Keep its state alive after.
      _libraryPage = LibraryView(
        key: const ValueKey<String>('library'),
        bottomInset: bottomInset,
        onOpen: _openDetails,
        onBrowse: () => _transitionToSection(_Section.home),
        segmentRequest: _libraryRequest,
      );
    }
    if (settingsVisible || _settingsPage == null) {
      // Build Settings before the first swipe reaches it. PageView keeps the
      // adjacent section alive, avoiding a blank frame on the first visit.
      _settingsPage = SettingsView(
        key: const ValueKey<String>('settings'),
        bottomInset: bottomInset,
        onContentSourceChanged: _changeContentSource,
      );
    }

    final sectionContents = <_Section, Widget>{
      _Section.home: _buildHome(
        margin,
        bottomInset,
        featured,
        firstLoad,
        resume,
      ),
      _Section.reels: _reelsPage ?? const SizedBox.shrink(),
      _Section.library: _libraryPage ?? const SizedBox.shrink(),
      _Section.settings: _settingsPage ?? const SizedBox.shrink(),
    };

    final sections = _availableSections;
    final sectionPhysics = defaultTargetPlatform == TargetPlatform.iOS
        ? const _FastSectionPagePhysics(parent: BouncingScrollPhysics())
        : const _FastSectionPagePhysics(parent: ClampingScrollPhysics());
    final content = RepaintBoundary(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onSectionScrollNotification,
        child: PageView.builder(
          key: const PageStorageKey<String>('main-sections-page-view'),
          controller: _sectionPager,
          scrollDirection: Axis.horizontal,
          pageSnapping: true,
          allowImplicitScrolling: true,
          physics: sectionPhysics,
          itemCount: sections.length,
          findChildIndexCallback: (key) {
            if (key is ValueKey<_Section>) {
              final index = sections.indexOf(key.value);
              return index < 0 ? null : index;
            }
            return null;
          },
          itemBuilder: (context, index) {
            final section = sections[index];
            return _SectionHost(
              key: ValueKey<_Section>(section),
              active: section == _section && !_sectionDragInProgress,
              child: RepaintBoundary(child: sectionContents[section]!),
            );
          },
        ),
      ),
    );

    return ValueListenableBuilder<bool>(
      valueListenable: _search,
      builder: (context, searchOpen, _) {
        final lightIcons = darkMode ||
            (_section == _Section.reels && !searchOpen) ||
            (_section == _Section.home && !searchOpen && _heroVisible);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: lightIcons
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: PopScope(
            canPop: !searchOpen && _section == _Section.home,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _handleBack();
            },
            child: Scaffold(
              backgroundColor: AppColors.background,
              extendBody: true,
              resizeToAvoidBottomInset: false,
              body: Focus(
                autofocus: true,
                onKeyEvent: _onDesktopNavigationKey,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (windowsDesktop)
                      Row(
                        children: [
                          _WindowsNavigationRail(
                            selected: searchOpen
                                ? AppTab.search
                                : switch (_section) {
                                    _Section.home => AppTab.home,
                                    _Section.reels => AppTab.reels,
                                    _Section.library => AppTab.library,
                                    _Section.settings => AppTab.settings,
                                  },
                            onSelect: _onTabSelect,
                            isTabEnabled: _isTabEnabled,
                          ),
                          Expanded(child: IgnorePointer(ignoring: searchOpen, child: content)),
                        ],
                      )
                    else
                      IgnorePointer(ignoring: searchOpen, child: content),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: searchOpen
                          ? SearchOverlay(
                              key: const ValueKey<String>('search'),
                              bottomInset: bottomInset,
                              onClose: _closeSearch,
                              onOpen: _openDetails,
                            )
                          : const SizedBox.shrink(
                              key: ValueKey<String>('no-search'),
                            ),
                    ),
                  ],
                ),
              ),
              // Keep the navigation dock in a stable layout slot and animate
              // opacity only. Collapsing its height or translating it vertically
              // makes it appear to rise from the bottom when leaving Reels.
              bottomNavigationBar: windowsDesktop
                  ? null
                  : IgnorePointer(
                      ignoring: !searchOpen && _section == _Section.reels,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeInOutCubic,
                        opacity:
                            searchOpen || _section != _Section.reels ? 1 : 0,
                        child: _RidingTabBar(
                          selected: searchOpen
                              ? AppTab.search
                              : switch (_section) {
                                  _Section.home => AppTab.home,
                                  _Section.reels => AppTab.reels,
                                  _Section.library => AppTab.library,
                                  _Section.settings => AppTab.settings,
                                },
                          onSelect: _onTabSelect,
                          isTabEnabled: _isTabEnabled,
                        ),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHome(
    double margin,
    double bottomInset,
    Video? featured,
    bool firstLoad,
    Duration? resume,
  ) {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      edgeOffset: context.safe.top + Gaps.sm,
      displacement: 44,
      child: CustomScrollView(
        key: const PageStorageKey<String>('home-scroll'),
        controller: _scroll,
        physics: nativeScrollPhysics(context, alwaysScrollable: true),
        scrollCacheExtent: ScrollCacheExtent.pixels(
          MediaQuery.sizeOf(context).height * 0.7,
        ),
        slivers: [
          SliverToBoxAdapter(
            child: _HeroStretch(
              controller: _scroll,
              child: HomeHero(
                video: featured,
                loading: firstLoad,
                playLabel: resume != null ? 'Resume' : 'Play',
                playBusy: _playingFeatured,
                onPlay: _playFeatured,
                onDetails: () {
                  if (featured != null) {
                    _openDetails(featured, List<Video>.of(_videos));
                  }
                },
              ),
            ),
          ),
          SliverToBoxAdapter(child: ContinueRow(onPlay: _resume)),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(margin, Gaps.md, margin, Gaps.md),
              child: Text(
                'Latest videos',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.headline,
              ),
            ),
          ),
          ..._contentSlivers(margin),
          SliverToBoxAdapter(child: SizedBox(height: Gaps.xl + bottomInset)),
        ],
      ),
    );
  }

  bool _isTabEnabled(AppTab tab) {
    final remote = RemoteConfigService.instance;
    return switch (tab) {
      AppTab.search => remote.isFeatureEnabled('search'),
      AppTab.reels => remote.isFeatureEnabled('reels'),
      _ => true,
    };
  }

  List<Widget> _contentSlivers(double margin) {
    final gridPadding = EdgeInsets.symmetric(horizontal: margin);

    if (_videos.isEmpty && (_loading || !_sourceChoiceReady)) {
      // The source picker and first network request happen after the first
      // frame. Keep a skeleton visible instead of flashing 'No videos found'.
      return [SliverSkeletonGrid(padding: gridPadding)];
    }

    final error = _error;
    if (_videos.isEmpty && error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            icon: error.icon,
            title: error.title,
            message: error.message,
            actionLabel: 'Retry',
            onAction: () => _loadPage(reset: true),
            secondaryLabel: error.offline &&
                    DownloadStore.instance.items.any(
                      (item) => item.status == DownloadStatus.done,
                    )
                ? 'Open downloads'
                : null,
            onSecondary: _showDownloads,
          ),
        ),
      ];
    }

    if (_videos.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusView(
            icon: Icons.video_library_outlined,
            title: 'No videos found',
            message: 'There is nothing to show on this source right now.',
            actionLabel: 'Refresh',
            onAction: () => _loadPage(reset: true),
          ),
        ),
      ];
    }

    return [
      if (_gridVideos.isNotEmpty)
        SliverVideoGrid(
          videos: _gridVideos,
          padding: gridPadding,
          onOpen: (video) => _openDetails(video, List<Video>.of(_videos)),
        ),
      if (_loading)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: Gaps.lg),
            child: Spinner(),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: Gaps.lg),
            child: Center(
              child: AppButton(
                label: 'Couldn\u2019t load more \u2013 Retry',
                icon: Icons.refresh_rounded,
                style: AppButtonStyle.secondary,
                onPressed: _loadPage,
              ),
            ),
          ),
        ),
    ];
  }
}

/// Grows the Featured card slightly while the page is pulled past the top, so
/// the card keeps its rounded hierarchy and fills part of the rubber-band gap
/// instead of sliding away from a flat background. Only this transform
/// rebuilds on scroll; the hero itself is passed in as a stable child.
class _HeroStretch extends StatelessWidget {
  const _HeroStretch({required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      // The hero (large image, gradients) is rasterized once and only its
      // texture is scaled while pulling, so refresh stays at 60 fps.
      child: RepaintBoundary(child: child),
      builder: (context, child) {
        final pulled = controller.hasClients
            ? math.max(0.0, -controller.position.pixels)
            : 0.0;
        // Always wrap, even at scale 1, so the hero keeps the same element
        // depth and is never remounted when the pull starts or ends.
        final scale = 1 + math.min(pulled, 120.0) / 2400;
        return Transform.scale(
          scale: scale,
          alignment: Alignment.bottomCenter,
          child: child,
        );
      },
    );
  }
}

class _SectionHost extends StatefulWidget {
  const _SectionHost({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_SectionHost> createState() => _SectionHostState();
}

class _SectionHostState extends State<_SectionHost>
    with AutomaticKeepAliveClientMixin<_SectionHost> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(enabled: widget.active, child: widget.child);
  }
}

class _RidingTabBar extends StatelessWidget {
  const _RidingTabBar({
    required this.selected,
    required this.onSelect,
    required this.isTabEnabled,
  });

  final AppTab selected;
  final ValueChanged<AppTab> onSelect;
  final bool Function(AppTab tab) isTabEnabled;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    // Reserve only the dock's real height plus the iPhone home-indicator area.
    // Never let a loose Center claim the full Scaffold height.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: appBottomBarHeight(context) + safeBottom,
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.only(bottom: safeBottom),
          child: AppBottomBar(
            selected: selected,
            onSelect: onSelect,
            isTabEnabled: isTabEnabled,
            bottomGap: 0,
          ),
        ),
      ),
    );
  }
}

class _WindowsNavigationRail extends StatelessWidget {
  const _WindowsNavigationRail({
    required this.selected,
    required this.onSelect,
    required this.isTabEnabled,
  });

  final AppTab selected;
  final ValueChanged<AppTab> onSelect;
  final bool Function(AppTab tab) isTabEnabled;

  static const _tabs = <({AppTab tab, IconData icon, String label})>[
    (tab: AppTab.home, icon: Icons.home_rounded, label: 'Home'),
    (tab: AppTab.search, icon: Icons.search_rounded, label: 'Search'),
    (tab: AppTab.reels, icon: Icons.play_arrow_rounded, label: 'Reels'),
    (tab: AppTab.library, icon: Icons.video_library_outlined, label: 'Library'),
    (tab: AppTab.settings, icon: Icons.settings_outlined, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs.where((tab) => isTabEnabled(tab.tab)).toList();
    final selectedIndex = tabs.indexWhere((tab) => tab.tab == selected);
    return Material(
      color: AppColors.surface,
      child: SizedBox(
        width: 78,
        child: Column(
          children: [
            const SizedBox(height: 18),
            const Icon(Icons.play_arrow_rounded, size: 28),
            const SizedBox(height: 18),
            const Divider(height: 1, indent: 12, endIndent: 12),
            const SizedBox(height: 8),
            Expanded(
              child: NavigationRail(
                backgroundColor: Colors.transparent,
                selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                onDestinationSelected: (index) => onSelect(tabs[index].tab),
                labelType: NavigationRailLabelType.all,
                minWidth: 76,
                groupAlignment: -0.85,
                indicatorColor: AppColors.accentStrong,
                selectedIconTheme: const IconThemeData(
                  color: Colors.white,
                  size: 24,
                ),
                unselectedIconTheme: IconThemeData(
                  color: AppColors.textSecondary,
                  size: 24,
                ),
                selectedLabelTextStyle: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelTextStyle: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
                destinations: [
                  for (final tab in tabs)
                    NavigationRailDestination(
                      icon: Icon(tab.icon),
                      selectedIcon: Icon(tab.icon),
                      label: Text(tab.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
