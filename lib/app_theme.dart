import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

abstract final class OnDark {
  static const Color background = Color(0xFF0B0D12);
  static const Color surface = Color(0xFF151923);
  static const Color surfaceHigh = Color(0xFF1E2333);
  static const Color outline = Color(0x1FFFFFFF);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB7BDCB);
  static const Color textTertiary = Color(0xFF8E96A8);
  static const Color blueSoft = Color(0xFF1B2B4D);
  static const Color error = Color(0xFFFF8A80);
}

class Palette {
  const Palette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.blueSoft,
    required this.error,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color blueSoft;
  final Color error;

  static const Palette dark = Palette(
    brightness: Brightness.dark,
    background: OnDark.background,
    surface: OnDark.surface,
    surfaceHigh: OnDark.surfaceHigh,
    outline: OnDark.outline,
    textPrimary: OnDark.textPrimary,
    textSecondary: OnDark.textSecondary,
    textTertiary: OnDark.textTertiary,
    blueSoft: OnDark.blueSoft,
    error: OnDark.error,
  );

  static const Palette light = Palette(
    brightness: Brightness.light,
    background: Color(0xFFF4F5FA),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE8EBF2),
    outline: Color(0x1F000000),
    textPrimary: Color(0xFF12141B),
    textSecondary: Color(0xFF4B5265),
    textTertiary: Color(0xFF7B8396),
    blueSoft: Color(0xFFDDE9FF),
    error: Color(0xFFD93025),
  );
}

abstract final class AppColors {
  static Palette palette = Palette.dark;

  static Color get background => palette.background;
  static Color get surface => palette.surface;
  static Color get surfaceHigh => palette.surfaceHigh;
  static Color get outline => palette.outline;
  static Color get textPrimary => palette.textPrimary;
  static Color get textSecondary => palette.textSecondary;
  static Color get textTertiary => palette.textTertiary;
  static Color get blueSoft => palette.blueSoft;
  static Color get error => palette.error;

  static const Color accent = Color(0xFF8B7CFF);

  static const Color accentStrong = Color(0xFF6C5CE7);

  static const Color blue = Color(0xFF4C93FF);

  static const Color star = Color(0xFFFFC857);
}

abstract final class Gaps {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class Radii {
  static const double card = 12;
  static const double button = 10;
  static const double field = 12;
  static const double pill = 999;
}

abstract final class Motion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration fade = Duration(milliseconds: 320);
  static const Duration scroll = Duration(milliseconds: 260);
  static const Curve curve = Curves.easeOutCubic;
}

extension UiScale on BuildContext {
  bool get isPhone => MediaQuery.sizeOf(this).shortestSide < 600;

  double get uiScale =>
      (MediaQuery.sizeOf(this).shortestSide / 390).clamp(0.9, 1.25).toDouble();

  double s(double value) => value * uiScale;

  double get hMargin => isPhone ? 16 : 24;

  EdgeInsets get safe => MediaQuery.viewPaddingOf(this);
}

int videoGridColumns(BuildContext context) => context.isPhone ? 2 : 3;

class TextSet {
  const TextSet(this.palette);

  final Palette palette;

  TextStyle get display => TextStyle(
        fontSize: 26,
        height: 1.15,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: palette.textPrimary,
      );

  TextStyle get headline => TextStyle(
        fontSize: 20,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: palette.textPrimary,
      );

  TextStyle get title => TextStyle(
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
      );

  TextStyle get cardTitle => TextStyle(
        fontSize: 13.5,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
      );

  TextStyle get body => TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w400,
        color: palette.textSecondary,
      );

  TextStyle get label => TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
      );

  TextStyle get caption => TextStyle(
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: palette.textTertiary,
      );

  TextStyle get overline => const TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: AppColors.accent,
      );
}

abstract final class AppText {
  static TextSet get _set => TextSet(AppColors.palette);

  static TextStyle get display => _set.display;
  static TextStyle get headline => _set.headline;
  static TextStyle get title => _set.title;
  static TextStyle get cardTitle => _set.cardTitle;
  static TextStyle get body => _set.body;
  static TextStyle get label => _set.label;
  static TextStyle get caption => _set.caption;
  static TextStyle get overline => _set.overline;
}

const TextSet darkText = TextSet(Palette.dark);

ThemeData buildAppTheme(Brightness brightness) {
  final p = brightness == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: p.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: brightness,
      surface: p.surface,
    ),
    splashFactory: NoSplash.splashFactory,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: p.textPrimary,
      displayColor: p.textPrimary,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.brightness == Brightness.dark
          ? OnDark.surfaceHigh
          : const Color(0xFF2A2F3D),
      contentTextStyle: const TextStyle(
        fontSize: 14,
        color: Colors.white,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.button),
      ),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        for (final platform in TargetPlatform.values)
          platform: const CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}

class FadePageRoute<T> extends PageRouteBuilder<T> {
  FadePageRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, _, __) => builder(context),
          transitionDuration: const Duration(milliseconds: 380),
          reverseTransitionDuration: const Duration(milliseconds: 300),
          transitionsBuilder: (context, animation, _, child) => FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
              reverseCurve: Curves.easeIn,
            ),
            child: child,
          ),
        );
}

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}
