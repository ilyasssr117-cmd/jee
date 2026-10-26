import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';

import 'app_settings.dart';
import 'app_theme.dart';
import 'download_store.dart';
import 'favorites_store.dart';
import 'history_store.dart';
import 'home_page.dart';
import 'local_store.dart';
import 'native_bridge.dart';
import 'platform_ui.dart';
import 'playback_progress.dart';
import 'preview_manager.dart';
import 'search_history.dart';

void main() {
  // Any error thrown anywhere is logged instead of silently killing the app.
  runZonedGuarded<Future<void>>(
    _bootstrap,
    (error, stack) => debugPrint('[FATAL][zone] $error\n$stack'),
  );
}

Future<void> _bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FATAL][flutter] ${details.exceptionAsString()}\n${details.stack}');
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[FATAL][platform] $error\n$stack');
    return true; // Handled: do not take the process down.
  };

  // In release builds a widget error is normally a blank grey screen.
  ErrorWidget.builder = (details) {
    final message = details.exceptionAsString();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: AppColors.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Something went wrong\n\n'
              '${message.length > 600 ? message.substring(0, 600) : message}',
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
  imageCache.maximumSize = 300;
  imageCache.maximumSizeBytes = 120 << 20;

  await applyBrowseOrientation();

  // A failure here must never block start-up: the app just starts empty.
  try {
    await LocalStore.init();
    AppSettings.instance.load();
    FavoritesStore.instance.load();
    HistoryStore.instance.load();
    SearchHistory.instance.load();
    PlaybackProgress.instance.load();
    await DownloadStore.instance.init();
    await NativeBridge.instance.init();
  } catch (error) {
    debugPrint('[STARTUP] Local data failed to load: $error');
  }

  runApp(const FlowApp());
}

class FlowApp extends StatefulWidget {
  const FlowApp({super.key});

  @override
  State<FlowApp> createState() => _FlowAppState();
}

class _FlowAppState extends State<FlowApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late Brightness _brightness = _resolve();

  /// Picture of the screen taken just before a theme switch. It is laid over
  /// the new theme and faded out, so the whole app changes in one smooth
  /// cross-fade instead of piece by piece.
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

  /// Dark, light, or whatever the iPhone is set to.
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
      shot = null; // No picture: the switch is simply instant.
    }
    if (!mounted) {
      shot?.dispose();
      return;
    }

    final next = _resolve(); // May have changed again while we waited.
    if (next == _brightness) {
      shot?.dispose();
      return;
    }
    _brightness = next;
    _applyPalette();
    _snapshot?.dispose();
    setState(() => _snapshot = shot);

    // Colours are read when a widget builds, so every widget builds again
    // (state, scroll positions and loaded videos are all kept).
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
      title: 'Flow',
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(_brightness),
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final snapshot = _snapshot;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: _brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                key: _boundaryKey,
                child: MediaQuery(
                  // Respect the iPhone's text-size setting, within limits.
                  data: media.copyWith(
                    textScaler: media.textScaler.clamp(
                      minScaleFactor: 0.9,
                      maxScaleFactor: 1.25,
                    ),
                  ),
                  // A card preview stops as soon as the finger starts scrolling.
                  child: NotificationListener<ScrollStartNotification>(
                    onNotification: (notification) {
                      if (notification.dragDetails != null &&
                          PreviewManager.instance.active.value != null) {
                        PreviewManager.instance.stopNow();
                      }
                      return false;
                    },
                    child: child ?? const SizedBox.shrink(),
                  ),
                ),
              ),
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
