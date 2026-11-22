/// VXTUBE design system — single source of truth for brand tokens.
///
/// Premium dark-cinematic identity: deep ink surfaces, one restrained
/// indigo/violet accent family, no competing accent colors. Screens
/// must take colors from [AppColors], spacing from [VxSpace], radii
/// from [VxRadius] and type from [VxType] instead of literals.
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Spacing scale (4pt base). Aliases the existing [Gaps] values so old
/// and new code resolve to the same numbers.
abstract final class VxSpace {
  static const double xs = Gaps.xs; // 4
  static const double sm = Gaps.sm; // 8
  static const double md = Gaps.md; // 12
  static const double lg = Gaps.lg; // 16
  static const double xl = Gaps.xl; // 24
  static const double xxl = Gaps.xxl; // 32

  /// Minimum comfortable touch target (Material guideline).
  static const double minTouchTarget = 48;

  /// TV: minimum focusable target height at 10-foot distance.
  static const double tvMinTarget = 56;
}

/// Corner radii.
abstract final class VxRadius {
  static const double card = Radii.card; // 22
  static const double button = Radii.button; // 16
  static const double field = Radii.field; // 16
  static const double pill = Radii.pill;
  static const double small = Radii.small; // 12
  static const double medium = Radii.medium; // 22
}

/// Typography hierarchy. The readability floor is 12sp for metadata
/// and 13sp for secondary body text (fix 24); 11sp is reserved for
/// non-essential badges and must not carry required information.
abstract final class VxType {
  static const double pageTitle = 28;
  static const double sectionTitle = 20;
  static const double cardTitle = 15;
  static const double body = 14;
  static const double bodySecondary = 13;
  static const double metadata = 12;
  static const double badge = 11;

  /// TV scale: text is read from ~3m, so the floor rises.
  static const double tvCardTitle = 17;
  static const double tvBody = 16;
  static const double tvMetadata = 14;
}

/// Brand accent family (indigo/violet on dark cinematic surfaces).
abstract final class VxBrand {
  static const Color accent = AppColors.accent; // 0xFF8585FF
  static const Color accentViolet = AppColors.accentViolet;
  static const Color accentIndigo = AppColors.accentIndigo;

  /// The only sanctioned brand gradient: a restrained indigo→violet
  /// wash for hero/featured surfaces. Do not add per-screen gradients.
  static const LinearGradient heroWash = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1B1E3D), Color(0xFF0C1020)],
  );

  /// Focus ring used by every TV/remote-focusable control.
  static const Color focusRing = AppColors.focusRing;
  static const double focusRingWidth = 2.5;
}

/// Motion: restrained, shared durations/curves.
abstract final class VxMotion {
  static const Duration fast = Duration(milliseconds: 130);
  static const Duration standard = Duration(milliseconds: 250);
  static const Curve standardCurve = Curves.easeOut;
}
