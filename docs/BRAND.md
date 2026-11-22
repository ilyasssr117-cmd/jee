# VXTUBE Brand & Design System

## Identity
Premium dark-cinematic streaming. Deep ink surfaces, one restrained
indigo/violet accent family, the existing geometric VX logo and purple
play symbol unchanged. No competing accent colors, no per-screen
gradients, no neon/glass effects beyond the sanctioned hero wash.

## Tokens (code: `lib/design_tokens.dart`, values: `lib/app_theme.dart`)
- **Color**: `AppColors` — background `#0C1020`, surface `#151B2D`,
  surfaceHigh `#202943`, accent `#8585FF`, accentViolet `#9A86FF`,
  accentIndigo `#777EF5`. Only gradient: `VxBrand.heroWash`.
- **Spacing**: `VxSpace` — 4/8/12/16/24/32 scale; min touch target 48;
  TV min target 56.
- **Radii**: `VxRadius` — card 22, button/field 16, pill 999.
- **Type**: `VxType` — page title 28, section 20, card title 15, body
  14, secondary 13, metadata floor 12 (fix 24: 11sp is badge-only and
  must never carry required information). TV floors rise ~2sp.
- **Focus**: `VxBrand.focusRing` — white 2.5px ring + accent glow,
  shared by every remote/keyboard-focusable control.
- **Motion**: `VxMotion` — 130ms fast / 250ms standard, easeOut.
  Decorative animation never blocks initialization; the full intro
  plays on first launch only, returning users get a ~600ms flash,
  and reduced-motion is honored.

## Platform expression
- **Mobile**: bottom bar (Home/Reels/Library/Settings destinations +
  Search as an *action*), portrait browsing, content-aware player.
- **Android TV**: left rail, D-pad only navigation, TvVideoCard grid,
  landscape always, large type floors.
- **Windows**: navigation rail, mouse/keyboard, free window sizing.
- **Tablet/foldable**: large-screen tier by shortest side (>=600dp) —
  a layout breakpoint, never a TV classification.

## Icons
One family per surface: Material rounded icons for chrome/actions;
Cupertino glyphs only inside the Reels immersion layer where they
were already the established visual language. New UI uses Material.

## Applied (continuation pass, 2026-11-22)
- Type floors enforced in code: bottom-bar labels, card metadata,
  creator stats, reel timestamps and comment counts are all >= 12sp;
  the only remaining 11sp style is the overline/badge style, which
  never carries required information. TV floors: card title 17,
  metadata 14.
- Semantic tokens added: success / warning / error / divider /
  disabled / focusRing (single source in AppColors).
- Dialogs take the shared theme (surface + card radius + text set).
- TV Home is a real shelf interface (widgets/tv_home_shelves.dart);
  TV Details has its own layout in video_details_page.dart.
