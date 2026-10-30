import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'app_button.dart';

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
    final margin = context.hMargin;
    return SizedBox(
      height: 32 + 12,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(margin, 6, margin, 6),
        itemCount: categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: Gaps.sm),
        itemBuilder: (context, index) {
          final category = categories[index];
          return AppChip(
            label: category,
            selected: category == selected,
            onPressed: () => onSelected(category),
          );
        },
      ),
    );
  }
}
