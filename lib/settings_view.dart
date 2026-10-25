import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_settings.dart';
import 'app_theme.dart';
import 'playback_progress.dart';
import 'preview_manager.dart';
import 'recent_videos_store.dart';

class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.bottomInset});

  final double bottomInset;

  Future<void> _clearCache(BuildContext context) async {
    PreviewManager.instance.stopNow(fade: false);
    PreviewManager.instance.clearResolvedUrlCache();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Temporary cache cleared')));
  }

  Future<void> _clearHistory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          'Recently played videos and saved watch progress will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    RecentVideosStore.instance.clear();
    PlaybackProgress.instance.clearAll();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Watch history cleared')));
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        final settings = AppSettings.instance;
        return CustomScrollView(
          key: const PageStorageKey<String>('settings-scroll'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  margin,
                  context.safe.top + Gaps.lg,
                  margin,
                  Gaps.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Settings', style: AppText.headline),
                    const SizedBox(height: 4),
                    Text(
                      'Make the app feel right for you.',
                      style: AppText.body,
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: margin),
                child: _SettingsGroup(
                  title: 'APPEARANCE',
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gaps.md,
                        Gaps.md,
                        Gaps.md,
                        Gaps.md,
                      ),
                      child: Row(
                        children: [
                          const _LeadingIcon(icon: Icons.palette_outlined),
                          const SizedBox(width: Gaps.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Theme', style: AppText.label),
                                const SizedBox(height: 3),
                                Text(
                                  settings.isDark ? 'Dark appearance' : 'Light appearance',
                                  style: AppText.caption,
                                ),
                              ],
                            ),
                          ),
                          SegmentedButton<ThemeMode>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                value: ThemeMode.dark,
                                icon: Icon(Icons.dark_mode_outlined, size: 17),
                              ),
                              ButtonSegment(
                                value: ThemeMode.light,
                                icon: Icon(Icons.light_mode_outlined, size: 17),
                              ),
                            ],
                            selected: <ThemeMode>{settings.themeMode},
                            onSelectionChanged: (selection) =>
                                settings.setThemeMode(selection.first),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(margin, Gaps.lg, margin, 0),
                child: _SettingsGroup(
                  title: 'FEEDBACK',
                  children: [
                    SwitchListTile.adaptive(
                      value: settings.hapticsEnabled,
                      onChanged: settings.setHapticsEnabled,
                      secondary: const _LeadingIcon(icon: Icons.vibration_rounded),
                      title: Text('Haptic feedback', style: AppText.label),
                      subtitle: Text(
                        'Turn off vibration when tapping controls.',
                        style: AppText.caption,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: Gaps.md,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(margin, Gaps.lg, margin, 0),
                child: _SettingsGroup(
                  title: 'STORAGE',
                  children: [
                    _ActionRow(
                      icon: Icons.cleaning_services_outlined,
                      title: 'Clear temporary cache',
                      subtitle: 'Free thumbnail and preview memory.',
                      onTap: () => _clearCache(context),
                    ),
                    const Divider(height: 1, indent: 58),
                    _ActionRow(
                      icon: Icons.delete_outline_rounded,
                      title: 'Clear watch history',
                      subtitle: 'Remove recently played items and progress.',
                      destructive: true,
                      onTap: () => _clearHistory(context),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  margin,
                  Gaps.xl,
                  margin,
                  Gaps.xl + bottomInset,
                ),
                child: Center(
                  child: Text(
                    'A calmer, cleaner viewing experience',
                    textAlign: TextAlign.center,
                    style: AppText.caption,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: Gaps.xs, bottom: Gaps.sm),
          child: Text(
            title,
            style: AppText.overline.copyWith(color: AppColors.textTertiary),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(Radii.card + 4),
            border: Border.all(color: AppColors.outline),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.card + 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ],
    );
  }
}

class _LeadingIcon extends StatelessWidget {
  const _LeadingIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 20, color: AppColors.accent),
      );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: _LeadingIcon(icon: icon),
        title: Text(
          title,
          style: AppText.label.copyWith(
            color: destructive ? AppColors.error : AppColors.textPrimary,
          ),
        ),
        subtitle: Text(subtitle, style: AppText.caption),
        trailing: const Icon(Icons.chevron_right_rounded, size: 20),
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: Gaps.md),
      );
}
