import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../favorite_models_store.dart';
import '../model_page.dart';
import '../models.dart';
import '../request_cache.dart';
import '../touch.dart';
import '../video_repository.dart';
import 'model_avatar.dart';

class ModelRow extends StatefulWidget {
  const ModelRow({super.key, required this.model});

  final ModelRef model;

  @override
  State<ModelRow> createState() => _ModelRowState();
}

class _ModelRowState extends State<ModelRow> {
  String? _image;

  @override
  void initState() {
    super.initState();
    _image = widget.model.imageUrl;
    if (_image == null) _lookUpPhoto();
  }

  Future<void> _lookUpPhoto() async {
    try {
      final profile = await profileCache.fetch(
        widget.model.url,
        () => videoRepository.getModelProfile(widget.model),
      );
      if (!mounted || profile.imageUrl == null) return;
      FavoriteModelsStore.instance.updateImage(widget.model.url, profile.imageUrl);
      setState(() => _image = profile.imageUrl);
    } catch (_) {
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    return Pressable(
      semanticLabel: 'Model ${model.name}',
      haptic: Haptic.selection,
      pressedScale: 0.98,
      onTap: () => openModelPage(context, model.withImage(_image)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ModelAvatar(
              name: model.name,
              imageUrl: _image,
              pageUrl: model.url,
              size: 52,
            ),
            const SizedBox(width: Gaps.md),
            Expanded(
              child: Text(
                model.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.title,
              ),
            ),
            ListenableBuilder(
              listenable: FavoriteModelsStore.instance,
              builder: (context, _) {
                final favorites = FavoriteModelsStore.instance;
                final isFavorite = favorites.isFavorite(model.url);
                return Pressable(
                  semanticLabel: isFavorite
                      ? 'Remove from favourite models'
                      : 'Add to favourite models',
                  haptic: Haptic.medium,
                  pressedScale: 0.85,
                  onTap: () => favorites.toggle(model.withImage(_image)),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                      size: 26,
                      color: isFavorite ? AppColors.star : AppColors.textTertiary,
                    ),
                  ),
                );
              },
            ),
            Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
