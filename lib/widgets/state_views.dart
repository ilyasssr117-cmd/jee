import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'app_button.dart';
import 'video_card.dart';

/// Centered loading / error / empty message with optional actions.
class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon = Icons.refresh_rounded,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData actionIcon;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gaps.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, size: 30, color: AppColors.textTertiary),
              ),
              const SizedBox(height: Gaps.lg),
              Text(title, textAlign: TextAlign.center, style: AppText.title),
              if (message != null) ...[
                const SizedBox(height: Gaps.xs),
                Text(message!, textAlign: TextAlign.center, style: AppText.body),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: Gaps.lg),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: Gaps.sm,
                  runSpacing: Gaps.sm,
                  children: [
                    AppButton(
                      label: actionLabel!,
                      icon: actionIcon,
                      onPressed: onAction!,
                    ),
                    if (secondaryLabel != null && onSecondary != null)
                      AppButton(
                        label: secondaryLabel!,
                        style: AppButtonStyle.secondary,
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
class Spinner extends StatelessWidget {
  const Spinner({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(strokeWidth: 3),
      ),
    );
  }
}

/// Pulsing grey block used by skeletons.
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
        borderRadius: BorderRadius.circular(radius),
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
          const AspectRatio(
            aspectRatio: 16 / 9,
            child: SkeletonBlock(radius: Radii.card, width: double.infinity),
          ),
          const SizedBox(height: 10),
          const SkeletonBlock(height: 12, width: double.infinity),
          const SizedBox(height: 6),
          const SkeletonBlock(height: 12, width: 90),
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
    this.padding = EdgeInsets.zero,
  });

  final int count;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = videoGridColumns(context);
        const gap = Gaps.md;
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
              mainAxisSpacing: Gaps.lg,
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
