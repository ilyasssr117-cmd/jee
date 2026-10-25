import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Colours
// ---------------------------------------------------------------------------

const Color appBackground = Color(0xFF0B0D12);
const Color panelColor = Color(0xFF151923);
const Color accentColor = Color(0xFF8B7CFF);

/// Colour tokens. Text colours are chosen for >= 4.5:1 contrast on
/// [appBackground] so metadata stays readable from a sofa.
abstract final class AppColors {
  static const Color background = appBackground;
  static const Color surface = panelColor;
  static const Color surfaceHigh = Color(0xFF1E2333);
  static const Color outline = Color(0x1FFFFFFF);

  /// Brand accent for text / thin lines on dark surfaces.
  static const Color accent = accentColor;

  /// Darker accent used for filled buttons so white labels stay legible.
  static const Color accentStrong = Color(0xFF6C5CE7);

  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB7BDCB);
  static const Color textTertiary = Color(0xFF8E96A8);

  static const Color focusRing = Color(0xFFFFFFFF);
  static const Color error = Color(0xFFFF8A80);

  /// Blue focus glow used by search and cards (reference design).
  static const Color glowBlue = Color(0xFF2E7BFF);

  /// Active favourite star.
  static const Color star = Color(0xFFFFC857);
}

// ---------------------------------------------------------------------------
// Spacing, radii, motion
// ---------------------------------------------------------------------------
//
// All values below are expressed on a 1280 x 720 design canvas and scaled to
// the real screen with `context.s(...)`, so the layout looks the same on a
// 720p, 1080p or 4K TV regardless of the device's density bucket.

abstract final class Gaps {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Horizontal safe margin (about 4.4% of the width, inside TV overscan).
  static const double screenH = 56;

  /// Vertical safe margin.
  static const double screenV = 32;
}

abstract final class Radii {
  static const double card = 12;
  static const double button = 12;
  static const double field = 14;
  static const double pill = 999;
}

abstract final class Motion {
  static const Duration focus = Duration(milliseconds: 160);
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration scroll = Duration(milliseconds: 240);
  static const Duration page = Duration(milliseconds: 260);
  static const Curve curve = Curves.easeOutCubic;
}

// ---------------------------------------------------------------------------
// Responsive scaling
// ---------------------------------------------------------------------------

const double _designWidth = 1280;

/// Phones are laid out on a ~460 px wide canvas (measured on the short side,
/// so the player in landscape keeps the same sizes as the portrait screens).
const double _phoneDesignWidth = 460;

extension TvScale on BuildContext {
  /// iPhone / Android phone (short side under 600 logical px). Tablets and TVs
  /// keep the 10-foot layout.
  bool get isPhone => MediaQuery.sizeOf(this).shortestSide < 600;

  /// Ratio between the real logical size and the design canvas.
  double get tvScale {
    final size = MediaQuery.sizeOf(this);
    if (size.shortestSide < 600) {
      return (size.shortestSide / _phoneDesignWidth).clamp(0.75, 1.3).toDouble();
    }
    return (size.width / _designWidth).clamp(0.5, 2.5).toDouble();
  }

  /// Scales a design-canvas value to the current screen.
  double s(double value) => value * tvScale;

  /// Horizontal page margin: a slim fixed one on phones, TV safe-area on TVs.
  double get hMargin => isPhone ? 16 : s(Gaps.screenH);

  /// Notch / home-indicator insets (all zero on a TV).
  EdgeInsets get safe => MediaQuery.viewPaddingOf(this);
}

/// Columns of every video grid: 2 on phones, 4 elsewhere.
int videoGridColumns(BuildContext context) => context.isPhone ? 2 : 4;

// ---------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------
//
// Sizes are design-canvas values. `MaterialApp.builder` applies a text scaler
// equal to [TvScale.tvScale], so these styles are used as-is in widgets.

abstract final class AppText {
  static const TextStyle display = TextStyle(
    fontSize: 46,
    height: 1.1,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.6,
    color: AppColors.textPrimary,
  );

  static const TextStyle headline = TextStyle(
    fontSize: 28,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: AppColors.textPrimary,
  );

  static const TextStyle title = TextStyle(
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle cardTitle = TextStyle(
    fontSize: 17,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 18,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
  );

  static const TextStyle label = TextStyle(
    fontSize: 18,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.1,
    color: AppColors.textPrimary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: AppColors.textTertiary,
  );

  static const TextStyle overline = TextStyle(
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: AppColors.accent,
  );
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
      surface: AppColors.surface,
    ),
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.surfaceHigh,
      contentTextStyle: AppText.body.copyWith(color: AppColors.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.button),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: TvPageTransitionsBuilder(),
        TargetPlatform.fuchsia: TvPageTransitionsBuilder(),
        TargetPlatform.linux: TvPageTransitionsBuilder(),
        TargetPlatform.windows: TvPageTransitionsBuilder(),
        TargetPlatform.macOS: TvPageTransitionsBuilder(),
        // Native iOS push + edge-swipe back gesture.
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

/// Short fade with a small upward drift. Cheap to render on low-end TV SoCs.
class TvPageTransitionsBuilder extends PageTransitionsBuilder {
  const TvPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Motion.page;

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Motion.curve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Removes the glow overscroll indicator and keeps scrolling predictable with a
/// remote control.
class TvScrollBehavior extends MaterialScrollBehavior {
  const TvScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}
