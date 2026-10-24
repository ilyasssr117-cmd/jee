import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'tv_button.dart';
import 'video_card.dart';

/// Centered loading / error / empty message with a remote-focusable action.
/// Every error state in the app uses this so the viewer can always recover.
class TvStatusView extends StatelessWidget {
  const TvStatusView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon = Icons.refresh_rounded,
    this.secondaryLabel,
    this.onSecondary,
    this.autofocus = true,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData actionIcon;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.s(Gaps.xl)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: context.s(560)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: context.s(88),
                height: context.s(88),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(context.s(24)),
                ),
                child: Icon(
                  icon,
                  size: context.s(44),
                  color: AppColors.textTertiary,
                ),
              ),
              SizedBox(height: context.s(Gaps.lg)),
              Text(title, textAlign: TextAlign.center, style: AppText.headline),
              if (message != null) ...[
                SizedBox(height: context.s(Gaps.sm)),
                Text(message!, textAlign: TextAlign.center, style: AppText.body),
              ],
              if (actionLabel != null && onAction != null) ...[
                SizedBox(height: context.s(Gaps.xl)),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: context.s(Gaps.md),
                  runSpacing: context.s(Gaps.md),
                  children: [
                    TvButton(
                      label: actionLabel!,
                      icon: actionIcon,
                      autofocus: autofocus,
                      onPressed: onAction!,
                    ),
                    if (secondaryLabel != null && onSecondary != null)
                      TvButton(
                        label: secondaryLabel!,
                        style: TvButtonStyle.secondary,
                        onPressed: onSecondary!,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Neutral loading indicator for full-area loading.
class TvSpinner extends StatelessWidget {
  const TvSpinner({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: context.s(size),
        height: context.s(size),
        child: const CircularProgressIndicator(strokeWidth: 3.5),
      ),
    );
  }
}

/// Pulsing grey block used by skeletons. One controller per skeleton card.
class SkeletonPulse extends StatefulWidget {
  const SkeletonPulse({super.key, required this.child});

  final Widget child;

  @override
  State<SkeletonPulse> createState() => _SkeletonPulseState();
}

class _SkeletonPulseState extends State<SkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(begin: 0.45, end: 1)
      .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _opacity, child: widget.child);
}

class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({super.key, this.width, this.height, this.radius = 8});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(context.s(radius)),
      ),
    );
  }
}

/// Placeholder with exactly the same footprint as a real [VideoCard].
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({super.key});

  @override
  Widget build(BuildContext context) {
    return SkeletonPulse(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: SkeletonBlock(radius: Radii.card, width: double.infinity),
          ),
          SizedBox(height: context.s(14)),
          SkeletonBlock(height: context.s(14), width: double.infinity),
          SizedBox(height: context.s(8)),
          SkeletonBlock(height: context.s(14), width: context.s(120)),
        ],
      ),
    );
  }
}

/// Skeleton grid sharing [VideoCardMetrics] with the real grid.
class SliverSkeletonGrid extends StatelessWidget {
  const SliverSkeletonGrid({
    super.key,
    this.count = 8,
    this.columns = 4,
    this.padding = EdgeInsets.zero,
  });

  final int count;
  final int columns;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final gap = context.s(Gaps.lg);
        final width = constraints.crossAxisExtent - padding.horizontal;
        final cardWidth = ((width - gap * (columns - 1)) / columns)
            .clamp(0.0, double.infinity)
            .toDouble();
        return SliverPadding(
          padding: padding,
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: gap,
              mainAxisSpacing: context.s(Gaps.lg),
              mainAxisExtent: VideoCardMetrics.height(context, cardWidth),
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => const SkeletonCard(),
              childCount: count,
            ),
          ),
        );
      },
    );
  }
}
