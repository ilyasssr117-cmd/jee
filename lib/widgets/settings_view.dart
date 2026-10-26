import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../app_theme.dart';
import '../download_store.dart';
import '../history_store.dart';
import '../playback_progress.dart';
import '../preview_manager.dart';
import '../request_cache.dart';
import '../search_history.dart';
import '../touch.dart';
import 'dialogs.dart';

/// The Settings tab.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.bottomInset});

  /// Space kept free at the bottom (the floating bar).
  final double bottomInset;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  void _clearImageCache() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    PreviewManager.instance.clearCaches();
    clearRequestCaches();
    setState(() {});
    showToast(context, 'Cache cleared');
  }

  void _clearSearches() {
    SearchHistory.instance.clear();
    showToast(context, 'Search history cleared');
  }

  Future<void> _clearWatched() async {
    final ok = await confirmDialog(
      context,
      title: 'Clear watch history?',
      message: 'This removes your History list and every resume point.',
      confirmLabel: 'Clear',
    );
    if (!ok || !mounted) return;
    HistoryStore.instance.clear();
    PlaybackProgress.instance.clearAll();
    showToast(context, 'Watch history cleared');
  }

  Future<void> _deleteDownloads() async {
    final store = DownloadStore.instance;
    final ok = await confirmDialog(
      context,
      title: 'Delete all downloads?',
      message: '${store.doneCount} video(s) will be removed from your phone.',
      confirmLabel: 'Delete all',
    );
    if (!ok || !mounted) return;
    await store.removeAll();
    if (!mounted) return;
    showToast(context, 'Downloads deleted');
  }

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        AppSettings.instance,
        DownloadStore.instance,
      ]),
      builder: (context, _) {
        final settings = AppSettings.instance;
        final downloads = DownloadStore.instance;
        final cacheBytes = PaintingBinding.instance.imageCache.currentSizeBytes;

        return ListView(
          padding: EdgeInsets.fromLTRB(
            margin,
            context.safe.top + Gaps.lg,
            margin,
            Gaps.xl + widget.bottomInset,
          ),
          children: [
            Text('Settings', style: AppText.headline),
            const SizedBox(height: Gaps.lg),
            _Group(
              title: 'Appearance',
              children: [
                Padding(
                  padding: const EdgeInsets.all(Gaps.md),
                  child: _Segmented<AppThemeMode>(
                    value: settings.themeMode,
                    onChanged: settings.setThemeMode,
                    options: const <(AppThemeMode, String)>[
                      (AppThemeMode.system, 'System'),
                      (AppThemeMode.dark, 'Dark'),
                      (AppThemeMode.light, 'Light'),
                    ],
                  ),
                ),
              ],
            ),
            _Group(
              title: 'Playback & feedback',
              children: [
                _Row(
                  icon: Icons.skip_next_rounded,
                  color: const Color(0xFF6C5CE7),
                  title: 'Autoplay next video',
                  subtitle: 'Continue with the next one when a video ends',
                  trailing: _Toggle(
                    value: settings.autoplayNext,
                    onChanged: settings.setAutoplayNext,
                  ),
                ),
                _Row(
                  icon: Icons.volume_up_rounded,
                  color: const Color(0xFFE8710A),
                  title: 'Preview sound',
                  subtitle: 'Play sound when you hold a video to preview it',
                  trailing: _Toggle(
                    value: settings.previewSound,
                    onChanged: settings.setPreviewSound,
                  ),
                ),
                _Row(
                  icon: Icons.vibration_rounded,
                  color: const Color(0xFF34A853),
                  title: 'Haptic feedback',
                  subtitle: 'Vibrate on taps and long-press',
                  trailing: _Toggle(
                    value: settings.haptics,
                    onChanged: (value) {
                      settings.setHaptics(value);
                      if (value) Haptics.play(Haptic.medium);
                    },
                  ),
                ),
              ],
            ),
            _Group(
              title: 'Storage',
              children: [
                _Row(
                  icon: Icons.cleaning_services_rounded,
                  color: const Color(0xFFF29900),
                  title: 'Clear cache',
                  subtitle: 'Images, previews and saved lists \u00b7 ${formatBytes(cacheBytes)}',
                  onTap: _clearImageCache,
                ),
                _Row(
                  icon: Icons.download_for_offline_rounded,
                  color: const Color(0xFF4C93FF),
                  title: 'Delete all downloads',
                  subtitle: downloads.doneCount == 0
                      ? 'Nothing saved'
                      : '${downloads.doneCount} video(s) \u00b7 ${formatBytes(downloads.totalBytes)}',
                  destructive: true,
                  onTap: downloads.items.isEmpty ? null : _deleteDownloads,
                ),
              ],
            ),
            _Group(
              title: 'Privacy',
              children: [
                _Row(
                  icon: Icons.search_off_rounded,
                  color: const Color(0xFF8E96A8),
                  title: 'Clear search history',
                  onTap: _clearSearches,
                ),
                _Row(
                  icon: Icons.history_toggle_off_rounded,
                  color: const Color(0xFFD93025),
                  title: 'Clear watch history',
                  subtitle: 'History list and resume points',
                  destructive: true,
                  onTap: _clearWatched,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// iOS-style inset group: small title above a rounded card of rows.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: 56,
            color: AppColors.outline,
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Gaps.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              title.toUpperCase(),
              style: AppText.caption.copyWith(letterSpacing: 0.8),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.outline),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Column(children: rows),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null && trailing == null;
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: Pressable(
        semanticLabel: title,
        pressedScale: 1,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gaps.md, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: Colors.white),
              ),
              const SizedBox(width: Gaps.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppText.title.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: destructive
                            ? AppColors.error
                            : AppColors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: AppText.caption),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Switch.adaptive(
      value: value,
      activeTrackColor: AppColors.accentStrong,
      onChanged: (next) {
        Haptics.play(Haptic.selection);
        onChanged(next);
      },
    );
  }
}

/// Native iOS sliding segmented control (the thumb glides between options).
class _Segmented<T extends Object> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.onChanged,
    required this.options,
  });

  final T value;
  final ValueChanged<T> onChanged;
  final List<(T, String)> options;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        backgroundColor: AppColors.surfaceHigh,
        thumbColor: AppColors.accentStrong,
        padding: const EdgeInsets.all(3),
        children: <T, Widget>{
          for (final (option, label) in options)
            option: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(
                label,
                style: AppText.label.copyWith(
                  fontSize: 13,
                  color: option == value
                      ? Colors.white
                      : AppColors.textSecondary,
                ),
              ),
            ),
        },
        onValueChanged: (next) {
          if (next == null) return;
          Haptics.play(Haptic.selection);
          onChanged(next);
        },
      ),
    );
  }
}
