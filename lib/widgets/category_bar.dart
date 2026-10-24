import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'tv_button.dart';

/// Horizontally scrolling, remote-focusable category chips.
class CategoryBar extends StatelessWidget {
  const CategoryBar({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final margin = context.s(Gaps.screenH);
    return SizedBox(
      // Chip height + vertical room so the focus scale is never clipped.
      height: context.s(44 + 24),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.symmetric(
          horizontal: margin,
          vertical: context.s(12),
        ),
        itemCount: categories.length,
        separatorBuilder: (_, __) => SizedBox(width: context.s(Gaps.md - 4)),
        itemBuilder: (context, index) {
          final category = categories[index];
          return TvChip(
            label: category,
            selected: category == selected,
            onPressed: () => onSelected(category),
          );
        },
      ),
    );
  }
}
