import 'dart:ui' as ui show ImageFilter;

import 'package:flutter/cupertino.dart'
    show
        CupertinoColors,
        CupertinoPageRoute,
        CupertinoPageTransitionsBuilder,
        CupertinoScrollBehavior,
        CupertinoTextThemeData,
        CupertinoThemeData;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

abstract final class OnDark {
  // iOS dark system colors (systemBackground / secondarySystemGroupedBackground
  // / tertiarySystemFill / separator / label tiers / systemRed).
  static const Color background = Color(0xFF000000);
  static const Color surface = Color(0xFF1C1C1E);
  static const Color surfaceHigh = Color(0xFF2C2C2E);
  static const Color outline = Color(0x54545458);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF9E9EA3);
  static const Color textTertiary = Color(0xFF76767B);
  static const Color accentSoft = Color(0xFF3B171B);
  static const Color error = Color(0xFFFF453A);
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
    required this.accentSoft,
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
  final Color accentSoft;
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
    accentSoft: OnDark.accentSoft,
    error: OnDark.error,
  );

  static const Palette light = Palette(
    brightness: Brightness.light,
    background: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE5E5EA),
    outline: Color(0x4A3C3C43),
    textPrimary: Color(0xFF000000),
    textSecondary: Color(0xFF6C6C70),
    textTertiary: Color(0xFF8E8E93),
    accentSoft: Color(0xFFFCE4E6),
    error: Color(0xFFFF3B30),
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
  static Color get accentSoft => palette.accentSoft;
  static Color get error => palette.error;

  static const Color accent = Color(0xFFF04452);

  static const Color accentStrong = Color(0xFFDC2626);


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
  static const double card = 14;
  static const double button = 14;
  static const double field = 12;
  static const double group = 12; // inset-grouped list corner
  static const double pill = 999;
}

abstract final class Motion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration fade = Duration(milliseconds: 320);
  static const Duration scroll = Duration(milliseconds: 260);
  static const Curve curve = Curves.easeOutCubic;
  static const Curve spring = Curves.easeOutBack;
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
        fontSize: 28,
        height: 1.12,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
        color: palette.textPrimary,
      );

  /// iOS Large Title (34pt bold).
  TextStyle get largeTitle => TextStyle(
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.37,
        color: palette.textPrimary,
      );

  TextStyle get headline => TextStyle(
        fontSize: 22,
        height: 1.18,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.35,
        color: palette.textPrimary,
      );

  TextStyle get title => TextStyle(
        fontSize: 17,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.41,
        color: palette.textPrimary,
      );

  TextStyle get cardTitle => TextStyle(
        fontSize: 13.5,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
      );

  TextStyle get body => TextStyle(
        fontSize: 15,
        height: 1.35,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.24,
        color: palette.textSecondary,
      );

  TextStyle get label => TextStyle(
        fontSize: 15,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.24,
        color: palette.textPrimary,
      );

  TextStyle get caption => TextStyle(
        fontSize: 13,
        height: 1.3,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.08,
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
  static TextStyle get largeTitle => _set.largeTitle;
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
    highlightColor: Colors.transparent,
    visualDensity: VisualDensity.standard,
    iconTheme: const IconThemeData(size: 20, opticalSize: 20),
    // Every Cupertino widget (pickers, action sheets, alerts, search field,
    // switches, refresh control) follows the same palette automatically.
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: AppColors.accent,
      primaryContrastingColor: CupertinoColors.white,
      scaffoldBackgroundColor: p.background,
      barBackgroundColor: p.surface.withValues(alpha: 0.78),
      applyThemeToAll: true,
      textTheme: CupertinoTextThemeData(
        primaryColor: AppColors.accent,
        textStyle: TextStyle(
          inherit: false,
          fontSize: 17,
          letterSpacing: -0.41,
          color: p.textPrimary,
        ),
        pickerTextStyle: TextStyle(
          inherit: false,
          fontSize: 21,
          letterSpacing: -0.4,
          color: p.textPrimary,
        ),
        actionTextStyle: const TextStyle(
          inherit: false,
          fontSize: 17,
          letterSpacing: -0.41,
          color: AppColors.accent,
        ),
      ),
    ),
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: p.textPrimary,
      displayColor: p.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: p.textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.41,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        iconSize: const WidgetStatePropertyAll(20),
        shape: const WidgetStatePropertyAll(CircleBorder()),
        overlayColor: WidgetStatePropertyAll(
          AppColors.accent.withValues(alpha: 0.10),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      isDense: true,
      fillColor: p.surfaceHigh,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
      hintStyle: TextStyle(color: p.textTertiary),
      labelStyle: TextStyle(color: p.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide.none,
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide(color: p.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide(color: p.error, width: 1.4),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleSize: const Size(36, 5),
      dragHandleColor: p.textTertiary.withValues(alpha: 0.55),
      modalBackgroundColor: p.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 14,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: p.outline),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.accent,
      selectionColor: AppColors.accent.withValues(alpha: 0.24),
      selectionHandleColor: AppColors.accentStrong,
    ),
    dividerTheme: DividerThemeData(
      color: p.outline,
      thickness: 1,
      space: 1,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.accent,
      linearTrackColor: Color(0x263F3F46),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.selected)
            ? CupertinoColors.systemGreen
            : null,
      ),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: AppColors.accent,
      thumbColor: AppColors.accentStrong,
      overlayColor: AppColors.accent.withValues(alpha: 0.12),
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
        borderRadius: BorderRadius.circular(Radii.pill),
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

/// iOS push/pop route that blurs the page progressively while it closes
/// (button pop or interactive swipe-back). The blur is only applied while the
/// page is leaving, in coarse steps, so it stays cheap on the GPU.
class BlurCupertinoPageRoute<T> extends CupertinoPageRoute<T> {
  BlurCupertinoPageRoute({
    required super.builder,
    this.maxSigma = 14,
  });

  final double maxSigma;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final blurred = AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (context, cached) {
        final leaving = animation.status == AnimationStatus.reverse ||
            (navigator?.userGestureInProgress ?? false);
        final value = animation.value;
        if (!leaving || value >= 1) return cached!;
        // Quantised to 1.5px steps: smooth to the eye, no per-frame filter churn.
        final raw = (1 - value) * maxSigma;
        final sigma = (raw / 1.5).round() * 1.5;
        if (sigma < 1.5) return cached!;
        return ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: TileMode.clamp,
          ),
          child: cached,
        );
      },
    );
    return super.buildTransitions(context, animation, secondaryAnimation, blurred);
  }
}

class AppScrollBehavior extends CupertinoScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.mouse,
      };

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
