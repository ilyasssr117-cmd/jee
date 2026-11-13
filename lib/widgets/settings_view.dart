import 'package:flutter/cupertino.dart'
    show CupertinoIcons, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../app_settings.dart';
import '../content_source.dart';
import '../app_theme.dart';
import '../download_store.dart';
import '../history_store.dart';
import '../playback_progress.dart';
import '../preview_manager.dart';
import '../request_cache.dart';
import '../search_history.dart';
import '../touch.dart';
import 'dialogs.dart';
import 'content_source_picker.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.bottomInset,
    required this.onContentSourceChanged,
  });

  final double bottomInset;
  final ValueChanged<ContentSource> onContentSourceChanged;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  Future<void> _chooseContentSource() async {
    final settings = AppSettings.instance;
    final source = await showContentSourcePicker(
      context,
      initialSource: settings.contentSource,
    );
    if (!mounted || source == null || source == settings.contentSource) return;
    widget.onContentSourceChanged(source);
  }

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
            Text(
              'Settings',
              style: AppText.display.copyWith(fontSize: 34),
            ),
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
              title: 'Content',
              children: [
                _Row(
                  icon: Icons.language_rounded,
                  color: AppColors.accentBlue,
                  title: 'Content source',
                  subtitle: settings.contentSource.label,
                  onTap: _chooseContentSource,
                ),
              ],
            ),
            _Group(
              title: 'Playback & feedback',
              children: [
                _Row(
                  icon: Icons.skip_next_rounded,
                  color: AppColors.accentStrong,
                  title: 'Autoplay next video',
                  subtitle: 'Continue with the next one when a video ends',
                  trailing: _Toggle(
                    value: settings.autoplayNext,
                    onChanged: settings.setAutoplayNext,
                  ),
                ),
                _Row(
                  icon: Icons.volume_up_rounded,
                  color: AppColors.accentBlue,
                  title: 'Preview sound',
                  subtitle: 'Play sound when you hold a video to preview it',
                  trailing: _Toggle(
                    value: settings.previewSound,
                    onChanged: settings.setPreviewSound,
                  ),
                ),
                _Row(
                  icon: Icons.vibration_rounded,
                  color: AppColors.accentViolet,
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
                  color: AppColors.accentIndigo,
                  title: 'Clear cache',
                  subtitle:
                      'Images, previews and saved lists \u00b7 ${formatBytes(cacheBytes)}',
                  onTap: _clearImageCache,
                ),
                _Row(
                  icon: Icons.download_for_offline_rounded,
                  color: AppColors.accentStrong,
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
                  color: AppColors.accentMuted,
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
            thickness: 0.5,
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
              title,
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(Radii.card),
              border: Border.all(color: AppColors.outline, width: 0.7),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.card),
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
          padding: const EdgeInsets.symmetric(
            horizontal: Gaps.md,
            vertical: 11,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 19, color: color),
              ),
              const SizedBox(width: Gaps.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 3,
                      overflow: TextOverflow.visible,
                      style: AppText.title.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: destructive
                            ? AppColors.error
                            : AppColors.textPrimary,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        softWrap: true,
                        style: AppText.caption,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 15,
                  color: AppColors.textTertiary,
                ),
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
    final platform = Theme.of(context).platform;
    final isCupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

    void select(T next) {
      if (next == value) return;
      Haptics.play(Haptic.selection);
      onChanged(next);
    }

    if (isCupertino) {
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
            if (next != null) select(next);
          },
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        segments: <ButtonSegment<T>>[
          for (final (option, label) in options)
            ButtonSegment<T>(value: option, label: Text(label)),
        ],
        selected: <T>{value},
        showSelectedIcon: false,
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) select(selection.first);
        },
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>(
            (states) => states.contains(WidgetState.selected)
                ? AppColors.accentStrong
                : AppColors.surfaceHigh,
          ),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white
                : AppColors.textSecondary,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: AppColors.outline)),
        ),
      ),
    );
  }
}
