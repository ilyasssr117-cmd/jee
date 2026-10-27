import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../favorite_models_store.dart';
import 'model_row.dart';
import 'state_views.dart';

/// Library > Models: the models marked with a star.
class FavoriteModelsView extends StatelessWidget {
  const FavoriteModelsView({
    super.key,
    required this.onBrowse,
    required this.bottomInset,
  });

  final VoidCallback onBrowse;

  /// Space kept free at the bottom (the floating bar).
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final margin = context.hMargin;
    return ListenableBuilder(
      listenable: FavoriteModelsStore.instance,
      builder: (context, _) {
        final models = FavoriteModelsStore.instance.items;
        if (models.isEmpty) {
          return StatusView(
            icon: Icons.star_border_rounded,
            title: 'No favourite models yet',
            message: 'Tap the star on a model\u2019s page to keep it here.',
            actionLabel: 'Browse videos',
            actionIcon: Icons.home_rounded,
            onAction: onBrowse,
          );
        }
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(margin, Gaps.sm, margin, Gaps.xl + bottomInset),
          itemCount: models.length,
          itemBuilder: (context, index) => ModelRow(
            key: ValueKey<String>(models[index].url),
            model: models[index],
          ),
        );
      },
    );
  }
}
