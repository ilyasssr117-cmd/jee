import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'home_page.dart';
import 'tv_focusable.dart';

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

  // In release builds a widget error is normally a blank grey screen. Show the
  // message instead so a problem can be read straight off the TV.
  ErrorWidget.builder = (details) {
    final message = details.exceptionAsString();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: AppColors.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Text(
              'Something went wrong\n\n'
              '${message.length > 600 ? message.substring(0, 600) : message}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                height: 1.4,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  };

  // TV boxes often have 1-2 GB of RAM. Keep the decoded-image cache small
  // (thumbnails are already decoded at display size by VideoArtwork).
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 150;
  imageCache.maximumSizeBytes = 64 << 20;

  // Televisions are always landscape. Never let an orientation call block or
  // crash start-up on unusual devices.
  try {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } catch (error) {
    debugPrint('[STARTUP] Orientation lock failed: $error');
  }

  runApp(const TvTubeApp());
}

class TvTubeApp extends StatelessWidget {
  const TvTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TV Tube',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      scrollBehavior: const TvScrollBehavior(),
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        // D-pad centre (select) and Enter are already mapped by default;
        // add the gamepad "A" button so game-controller remotes work too.
        LogicalKeySet(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
      },
      builder: (context, child) {
        // Scale all text with the screen so the UI looks identical on 720p,
        // 1080p and 4K panels (layout metrics scale the same way via `s()`).
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(context.tvScale),
          ),
          // One traversal policy for the whole app: geometric D-pad movement,
          // with scrolling owned by TvFocusable.
          child: FocusTraversalGroup(
            policy: buildTvTraversalPolicy(),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      home: const HomePage(),
    );
  }
}
