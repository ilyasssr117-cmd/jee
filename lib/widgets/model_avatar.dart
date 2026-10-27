import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../image_headers.dart';

/// Round photo of a model. Models without a photo (or whose photo cannot be
/// loaded) show their first letter instead.
class ModelAvatar extends StatelessWidget {
  const ModelAvatar({
    super.key,
    required this.name,
    required this.imageUrl,
    required this.pageUrl,
    this.size = 48,
  });

  final String name;
  final String? imageUrl;

  /// Address of the model page: gives the site the picture is requested for.
  final String pageUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    final placeholder = Container(
      color: AppColors.accentStrong,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: AppText.display.copyWith(
          fontSize: size * 0.42,
          color: Colors.white,
        ),
      ),
    );

    final url = imageUrl;
    final Widget content = (url == null || url.isEmpty)
        ? placeholder
        : Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            headers: imageHeadersFor(pageUrl),
            errorBuilder: (context, error, stackTrace) => placeholder,
            loadingBuilder: (context, child, progress) =>
                progress == null ? child : placeholder,
          );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.outline, width: size > 60 ? 2 : 1),
      ),
      child: ClipOval(child: content),
    );
  }
}
