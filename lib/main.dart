import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'favorites_store.dart';
import 'home_page.dart';
import 'local_store.dart';
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
  PlatformDispatcher.instance.onError = (error, stack) {
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
              style: const TextStyle(
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
    FavoritesStore.instance.load();
    SearchHistory.instance.load();
    PlaybackProgress.instance.load();
  } catch (error) {
    debugPrint('[STARTUP] Local data failed to load: $error');
  }

  runApp(const TubeApp());
}

class TubeApp extends StatelessWidget {
  const TubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TV Tube',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      scrollBehavior: const AppScrollBehavior(),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          // Respect the iPhone's text-size setting, within sane limits.
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
        );
      },
      home: const HomePage(),
    );
  }
}
