import 'package:flutter/cupertino.dart'
    show
        CupertinoColors,
        CupertinoIcons,
        CupertinoSlidingSegmentedControl,
        CupertinoSwitch;
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
import 'ios_sheets.dart';
import 'large_title.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key, required this.bottomInset});

  final double bottomInset;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  static const List<int> _qualities = <int>[0, 1080, 720, 480, 360];

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
      confirmLabel: 'Clear Watch History',
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
      confirmLabel: 'Delete All Downloads',
    );
    if (!ok || !mounted) return;
    await store.removeAll();
    if (!mounted) return;
    showToast(context, 'Downloads deleted');
  }

  /// Native wheel picker (UIPickerView) for the preferred video quality.
  Future<void> _pickQuality() async {
    final settings = AppSettings.instance;
    final current = _qualityChoice(settings.preferredQuality);
    final result = await showWheelPicker(
      context,
      title: 'Video Quality',
      columns: [
        WheelColumn(
          labels: [for (final q in _qualities) _qualityLabel(q)],
          initialIndex: _qualities.indexOf(current).clamp(0, 4).toInt(),
        ),
      ],
    );
    if (result == null || !mounted) return;
    settings.setPreferredQuality(_qualities[result.first]);
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

        return CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            const LargeTitleSliver(title: 'Settings'),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                margin,
                Gaps.sm,
                margin,
                Gaps.xl + widget.bottomInset,
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _Group(
                    title: 'Appearance',
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(Gaps.md),
                        child: _Segmented<AppThemeMode>(
                          value: settings.themeMode,
                          onChanged: settings.setThemeMode,
                          options: const <(AppThemeMode, String)>[
                            (AppThemeMode.system, 'Automatic'),
                            (AppThemeMode.dark, 'Dark'),
                            (AppThemeMode.light, 'Light'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  _Group(
                    title: 'Playback',
                    children: [
                      _Row(
                        icon: CupertinoIcons.forward_end_fill,
                        color: CupertinoColors.systemIndigo,
                        title: 'Autoplay Next',
                        subtitle: 'Continue with the next video when one ends',
                        trailing: _Toggle(
                          value: settings.autoplayNext,
                          onChanged: settings.setAutoplayNext,
                        ),
                      ),
                      _Row(
                        icon: CupertinoIcons.slider_horizontal_3,
                        color: AppColors.accent,
                        title: 'Video Quality',
                        value: _qualityLabel(
                          _qualityChoice(settings.preferredQuality),
                        ),
                        chevron: true,
                        onTap: _pickQuality,
                      ),
                      _Row(
                        icon: CupertinoIcons.speaker_2_fill,
                        color: CupertinoColors.systemOrange,
                        title: 'Preview Sound',
                        subtitle: 'Play audio when you hold a video to preview',
                        trailing: _Toggle(
                          value: settings.previewSound,
                          onChanged: settings.setPreviewSound,
                        ),
                      ),
                    ],
                  ),
                  _Group(
                    title: 'Feedback',
                    children: [
                      _Row(
                        icon: CupertinoIcons.waveform,
                        color: CupertinoColors.systemGreen,
                        title: 'Haptics',
                        subtitle: 'Feel taps, scrolling ticks and long-presses',
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
                    footer: downloads.doneCount == 0
                        ? 'No videos are saved on this device.'
                        : null,
                    children: [
                      _Row(
                        icon: CupertinoIcons.sparkles,
                        color: CupertinoColors.systemYellow,
                        title: 'Clear Cache',
                        value: formatBytes(cacheBytes),
                        onTap: _clearImageCache,
                      ),
                      _Row(
                        icon: CupertinoIcons.arrow_down_circle_fill,
                        color: CupertinoColors.systemRed,
                        title: 'Delete All Downloads',
                        value: downloads.doneCount == 0
                            ? null
                            : '${downloads.doneCount} · ${formatBytes(downloads.totalBytes)}',
                        destructive: true,
                        onTap: downloads.items.isEmpty ? null : _deleteDownloads,
                      ),
                    ],
                  ),
                  _Group(
                    title: 'Privacy',
                    footer:
                        'Removes your History list and every saved resume point.',
                    children: [
                      _Row(
                        icon: CupertinoIcons.search,
                        color: CupertinoColors.systemGrey,
                        title: 'Clear Search History',
                        onTap: _clearSearches,
                      ),
                      _Row(
                        icon: CupertinoIcons.clock_fill,
                        color: CupertinoColors.systemRed,
                        title: 'Clear Watch History',
                        destructive: true,
                        onTap: _clearWatched,
                      ),
                    ],
                  ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _qualityLabel(int q) => q == 0 ? 'Auto' : '${q}p';

int _qualityChoice(int preferred) {
  const choices = <int>[1080, 720, 480, 360];
  if (preferred <= 0) return 0;
  for (final choice in choices) {
    if (preferred >= choice) return choice;
  }
  return 360;
}

/// Inset-grouped section: small caps header, rounded white/gray card, hairline
/// separators that start after the icon, optional footer note.
class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.footer});

  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: 60),
            child: Container(height: 0.5, color: AppColors.outline),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Gaps.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 7),
            child: Text(
              title.toUpperCase(),
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          DecoratedBox(
            decoration: ShapeDecoration(
              color: AppColors.surface,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(Radii.group),
              ),
            ),
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(Radii.group),
              child: Column(children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(footer!, style: AppText.caption),
            ),
        ],
      ),
    );
  }
}

/// iOS table cell: tint-colored squircle icon, 17pt title, optional detail,
/// trailing value / chevron / control, and a gray highlight while pressed.
class _Row extends StatefulWidget {
  const _Row({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.chevron = false,
    this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value || !mounted) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    final disabled = !tappable && widget.trailing == null;
    final highlight = AppColors.palette.brightness == Brightness.dark
        ? const Color(0xFF3A3A3C)
        : const Color(0xFFD1D1D6);

    final content = Container(
      color: _down ? highlight : Colors.transparent,
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: ShapeDecoration(
              color: widget.color,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            child: Icon(widget.icon, size: 18, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 17,
                    height: 1.25,
                    letterSpacing: -0.41,
                    color: widget.destructive
                        ? AppColors.error
                        : AppColors.textPrimary,
                  ),
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(widget.subtitle!, style: AppText.caption),
                ],
              ],
            ),
          ),
          if (widget.value != null) ...[
            const SizedBox(width: 8),
            Text(
              widget.value!,
              style: TextStyle(
                fontSize: 17,
                letterSpacing: -0.41,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          if (widget.trailing != null) ...[
            const SizedBox(width: 8),
            widget.trailing!,
          ],
          if (widget.chevron) ...[
            const SizedBox(width: 6),
            Icon(
              CupertinoIcons.chevron_forward,
              size: 15,
              color: AppColors.textTertiary,
            ),
          ],
        ],
      ),
    );

    return Opacity(
      opacity: disabled || (!tappable && widget.trailing == null) ? 0.45 : 1,
      child: tappable
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _set(true),
              onTapCancel: () => _set(false),
              onTapUp: (_) => _set(false),
              onTap: () {
                Haptics.play(Haptic.selection);
                widget.onTap!();
              },
              child: Semantics(
                button: true,
                label: widget.title,
                child: content,
              ),
            )
          : content,
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return CupertinoSwitch(
      value: value,
      activeTrackColor: CupertinoColors.systemGreen,
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
    final dark = AppColors.palette.brightness == Brightness.dark;
    return SizedBox(
      width: double.infinity,
      child: CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        backgroundColor: dark
            ? const Color(0x3D767680)
            : const Color(0x1F767680),
        thumbColor: dark ? const Color(0xFF636366) : Colors.white,
        padding: const EdgeInsets.all(2),
        children: <T, Widget>{
          for (final (option, label) in options)
            option: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: option == value ? FontWeight.w600 : FontWeight.w500,
                  letterSpacing: -0.08,
                  color: AppColors.textPrimary,
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
