import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'error_text.dart';
import 'models.dart';
import 'video_details_page.dart';
import 'video_repository.dart';
import 'widgets/app_button.dart';
import 'widgets/back_button.dart';
import 'widgets/state_views.dart';
import 'widgets/video_grid.dart';

/// All the videos of one model / channel.
///
/// The first page is `.../models/slug/videos/`, the next ones `.../videos/2/`,
/// `.../videos/3/`, and so on. Pages are fetched one after another until the
/// last video, and the total at the top grows as they arrive.
class ModelPage extends StatefulWidget {
  const ModelPage({super.key, required this.model});

  final ModelRef model;

  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  /// Safety stop so a misbehaving site can never loop forever.
  static const int _maxPages = 300;

  final List<Video> _videos = <Video>[];
  final Set<String> _seen = <String>{};
  ModelProfile? _profile;
  int _nextPage = 1;
  bool _loading = true;
  Object? _error;

  /// Bumped on dispose / retry so an old loop stops quietly.
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _run++;
    super.dispose();
  }

  Future<void> _loadAll() async {
    final run = ++_run;
    while (mounted && run == _run && _nextPage <= _maxPages) {
      final page = _nextPage;
      final ModelPageResult result;
      try {
        result = await videoRepository.getModelPage(widget.model, page: page);
      } catch (error) {
        if (!mounted || run != _run) return;
        setState(() {
          _loading = false;
          _error = error;
        });
        return;
      }
      if (!mounted || run != _run) return;

      var added = 0;
      for (final video in result.videos) {
        if (_seen.add(video.id)) {
          _videos.add(video);
          added++;
        }
      }
      // An empty page (or one with nothing new) is the end of the list.
      final last = added == 0;
      setState(() {
        _profile ??= result.profile;
        _nextPage = page + 1;
        if (last) _loading = false;
      });
      if (last) return;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (mounted && run == _run) setState(() => _loading = false);
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _loadAll();
  }

  void _openVideo(Video video) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailsPage(video: video, queue: _videos),
      ),
    );
  }

  String get _countLabel {
    final n = _videos.length;
    final base = '$n video${n == 1 ? '' : 's'}';
    return _loading ? '$base \u00b7 loading\u2026' : base;
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    final darkMode = AppColors.palette.brightness == Brightness.dark;
    final name = _profile?.name ?? widget.model.name;
    final firstLoad = _videos.isEmpty && _loading;
    final failedEmpty = _videos.isEmpty && _error != null;
    final finishedEmpty = _videos.isEmpty && !_loading && _error == null;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeader(margin, name)),
            if (firstLoad)
              SliverSkeletonGrid(
                count: 4,
                padding: EdgeInsets.symmetric(horizontal: margin),
              )
            else if (failedEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StatusView(
                  icon: describeError(_error!).icon,
                  title: describeError(_error!).title,
                  message: describeError(_error!).message,
                  actionLabel: 'Retry',
                  onAction: _retry,
                ),
              )
            else if (finishedEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: StatusView(
                  icon: Icons.video_library_outlined,
                  title: 'No videos found',
                  message: 'This model has no videos yet.',
                ),
              )
            else
              SliverVideoGrid(
                videos: _videos,
                padding: EdgeInsets.symmetric(horizontal: margin),
                onOpen: _openVideo,
              ),
            if (_error != null && _videos.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: margin,
                    vertical: Gaps.lg,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Couldn\u2019t load the rest of the videos.',
                          style: AppText.body,
                        ),
                      ),
                      AppButton(
                        label: 'Retry',
                        icon: Icons.refresh_rounded,
                        style: AppButtonStyle.secondary,
                        onPressed: _retry,
                      ),
                    ],
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: Gaps.xl + context.safe.bottom),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(double margin, String name) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        margin,
        context.safe.top + Gaps.md,
        margin,
        Gaps.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageBackButton(),
          const SizedBox(height: Gaps.lg),
          Row(
            children: [
              _Avatar(name: name, imageUrl: _profile?.imageUrl, pageUrl: widget.model.url),
              const SizedBox(width: Gaps.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline,
                    ),
                    const SizedBox(height: 4),
                    // Total number of videos (grows while the pages arrive).
                    Text(
                      _countLabel,
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Round photo of the model. Some models have no photo: their initial is
/// shown instead.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.imageUrl, required this.pageUrl});

  static const double size = 84;

  final String name;
  final String? imageUrl;
  final String pageUrl;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    final placeholder = Container(
      color: AppColors.accentStrong,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: AppText.display.copyWith(fontSize: 34, color: Colors.white),
      ),
    );

    final url = imageUrl;
    final Widget content;
    if (url == null || url.isEmpty) {
      content = placeholder;
    } else {
      final origin = Uri.tryParse(pageUrl)?.origin;
      content = Image.network(
        url,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        // Some CDNs refuse hot-linked images without a Referer.
        headers: origin == null ? null : <String, String>{'Referer': '$origin/'},
        errorBuilder: (context, error, stackTrace) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.outline, width: 2),
      ),
      child: ClipOval(child: content),
    );
  }
}
