import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app_settings.dart';
import 'analytics_service.dart';
import 'app_theme.dart';
import 'download_store.dart';
import 'favorites_store.dart';
import 'history_store.dart';
import 'home_page.dart';
import 'local_store.dart';
import 'offline_listing_cache.dart';
import 'offline_album_cache.dart';
import 'widget_sync.dart';
import 'widgets/mini_player_overlay.dart';
import 'native_bridge.dart';
import 'platform_ui.dart';
import 'favorite_models_store.dart';
import 'photo_store.dart';
import 'playback_progress.dart';
import 'preview_manager.dart';
import 'search_history.dart';
import 'services/remote_access_gate.dart';
import 'services/remote_config_service.dart';

void main() {
  runZonedGuarded<Future<void>>(_bootstrap, (error, stack) {
    if (kDebugMode) debugPrint('[FATAL][zone] ${error.runtimeType}\n$stack');
  });
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AnalyticsService.instance.initialize();
  if (defaultTargetPlatform == TargetPlatform.windows) {
    VideoPlayerMediaKit.ensureInitialized(windows: true);
    try {
      await windowManager.ensureInitialized();
    } catch (_) {}
  }

  FlutterError.onError = (details) {
    if (kDebugMode) FlutterError.presentError(details);
    if (kDebugMode) {
      debugPrint(
        '[FATAL][flutter] ${details.exception.runtimeType}\n${details.stack}',
      );
    }
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    if (kDebugMode) {
      debugPrint('[FATAL][platform] ${error.runtimeType}\n$stack');
    }
    return true;
  };

  ErrorWidget.builder = (details) {
    final message = kDebugMode
        ? details.exceptionAsString()
        : 'Please try again. If the problem continues, restart VXTUBEFinal.';
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: AppColors.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              kDebugMode ? 'Something went wrong\n\n$message' : message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                height: 1.4,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  };

  final imageCache = PaintingBinding.instance.imageCache;
  // Keep enough decoded, size-limited thumbnails for an album/video page to
  // survive ordinary scrolling and route changes without refetching them.
  // The cache remains bounded to avoid unbounded image memory growth.
  imageCache.maximumSize =
      defaultTargetPlatform == TargetPlatform.windows ? 72 : 96;
  imageCache.maximumSizeBytes =
      defaultTargetPlatform == TargetPlatform.windows ? 40 << 20 : 64 << 20;

  await applyBrowseOrientation();

  try {
    await LocalStore.init();
    OfflineListingCache.init();
    OfflineAlbumCache.init();
    unawaited(purgeStaleTempFiles());
    AppSettings.instance.load();
    FavoritesStore.instance.load();
    HistoryStore.instance.load();
    SearchHistory.instance.load();
    PlaybackProgress.instance.load();
    FavoriteModelsStore.instance.init();
    await Future.wait<void>(<Future<void>>[
      DownloadStore.instance.init(),
      PhotoStore.instance.init(),
      NativeBridge.instance.init(),
    ]);
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[STARTUP] Local data failed: ${error.runtimeType}');
    }
  }

  runApp(const VXTUBEFinalApp());
  unawaited(_startRemoteConfiguration());
  WidgetSync.instance.start();
}

Future<void> _startRemoteConfiguration() async {
  try {
    await RemoteConfigService.instance.initialize();
    unawaited(RemoteConfigService.instance.start());
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[REMOTE] Startup unavailable: ${error.runtimeType}');
    }
  }
}

class VXTUBEFinalApp extends StatefulWidget {
  const VXTUBEFinalApp({super.key});

  @override
  State<VXTUBEFinalApp> createState() => _VXTUBEFinalAppState();
}

class _VXTUBEFinalAppState extends State<VXTUBEFinalApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late Brightness _brightness = _resolve();

  final GlobalKey _boundaryKey = GlobalKey();
  ui.Image? _snapshot;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        final old = _snapshot;
        setState(() => _snapshot = null);
        old?.dispose();
      }
    });

  Brightness _resolve() {
    switch (AppSettings.instance.themeMode) {
      case AppThemeMode.dark:
        return Brightness.dark;
      case AppThemeMode.light:
        return Brightness.light;
      case AppThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  @override
  void initState() {
    super.initState();
    _applyPalette();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.addListener(_onSettings);
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onSettings);
    WidgetsBinding.instance.removeObserver(this);
    _fade.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _onSettings();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AnalyticsService.instance.onLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(RemoteConfigService.instance.onForeground());
    }
  }

  @override
  void didHaveMemoryPressure() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    PreviewManager.instance.stopNow(fade: false);
  }

  void _applyPalette() {
    AppColors.palette =
        _brightness == Brightness.dark ? Palette.dark : Palette.light;
  }

  Future<void> _onSettings() async {
    if (_resolve() == _brightness) return;

    ui.Image? shot;
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary != null && boundary.hasSize && mounted) {
        shot = await boundary.toImage(
          pixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
      }
    } catch (_) {
      shot = null;
    }
    if (!mounted) {
      shot?.dispose();
      return;
    }

    final next = _resolve();
    if (next == _brightness) {
      shot?.dispose();
      return;
    }
    _brightness = next;
    _applyPalette();
    _snapshot?.dispose();
    setState(() => _snapshot = shot);

    void markDirty(Element element) {
      element.markNeedsBuild();
      element.visitChildren(markDirty);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(markDirty);
    if (shot != null) _fade.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VXTUBE',
      navigatorKey: rootNavigatorKey,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _DesktopBackIntent(),
        SingleActivator(LogicalKeyboardKey.f11): _ToggleFullscreenIntent(),
      },
      actions: <Type, Action<Intent>>{
        _DesktopBackIntent: CallbackAction<_DesktopBackIntent>(
          onInvoke: (_) {
            unawaited(_handleDesktopBack());
            return null;
          },
        ),
        _ToggleFullscreenIntent: CallbackAction<_ToggleFullscreenIntent>(
          onInvoke: (_) {
            unawaited(_toggleDesktopFullscreen());
            return null;
          },
        ),
      },
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(_brightness),
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final snapshot = _snapshot;
        final isDark = _brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            // iOS uses the opposite brightness convention for status content.
            statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemStatusBarContrastEnforced: false,
            systemNavigationBarContrastEnforced: false,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                key: _boundaryKey,
                child: MediaQuery(
                  data: media.copyWith(
                    textScaler: media.textScaler,
                  ),
                  child: NotificationListener<ScrollStartNotification>(
                    onNotification: (notification) {
                      if (notification.dragDetails != null &&
                          PreviewManager.instance.active.value != null) {
                        PreviewManager.instance.stopNow();
                      }
                      return false;
                    },
                    child: IconTheme.merge(
                      data: const IconThemeData(size: 20, opticalSize: 20),
                      child: RemoteAccessGate(
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
              if (defaultTargetPlatform != TargetPlatform.windows)
                const MiniPlayerOverlay(),
              if (snapshot != null)
                IgnorePointer(
                  child: FadeTransition(
                    opacity: Tween<double>(begin: 1, end: 0).animate(
                      CurvedAnimation(parent: _fade, curve: Curves.easeInOut),
                    ),
                    child: RawImage(image: snapshot, fit: BoxFit.fill),
                  ),
                ),
            ],
          ),
        );
      },
      home: const HomePage(),
    );
  }
}

class _DesktopBackIntent extends Intent {
  const _DesktopBackIntent();
}

class _ToggleFullscreenIntent extends Intent {
  const _ToggleFullscreenIntent();
}

Future<void> _handleDesktopBack() async {
  await rootNavigatorKey.currentState?.maybePop();
}

Future<void> _toggleDesktopFullscreen() async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    final isFullscreen = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!isFullscreen);
  } catch (error) {
    if (kDebugMode) debugPrint('[WINDOW] Fullscreen toggle failed: $error');
  }
}
