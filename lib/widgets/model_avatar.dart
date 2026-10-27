import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../image_headers.dart';

/// Round photo of a model. Models without a photo (or whose photo cannot be
/// loaded) show their first letter instead.
///
/// A picture the site refuses is retried with simpler headers before giving
/// up: first the model's page as Referer, then the site address, then no extra
/// headers at all.
class ModelAvatar extends StatefulWidget {
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
  State<ModelAvatar> createState() => _ModelAvatarState();
}

class _ModelAvatarState extends State<ModelAvatar> {
  static const int _lastAttempt = 2;
  int _attempt = 0;

  @override
  void didUpdateWidget(ModelAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _attempt = 0;
  }

  Map<String, String>? get _headers {
    switch (_attempt) {
      case 0:
        final base = imageHeadersFor(widget.pageUrl);
        return base == null
            ? null
            : <String, String>{...base, 'Referer': widget.pageUrl};
      case 1:
        return imageHeadersFor(widget.pageUrl);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final trimmed = widget.name.trim();
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

    final url = widget.imageUrl;
    final Widget content = (url == null || url.isEmpty)
        ? placeholder
        : Image.network(
            url,
            key: ValueKey<String>('$url|$_attempt'),
            fit: BoxFit.cover,
            cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
            headers: _headers,
            errorBuilder: (context, error, stackTrace) {
              debugPrint(
                '[AVATAR] attempt $_attempt failed (${error.runtimeType}) for $url',
              );
              if (_attempt < _lastAttempt) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _attempt++);
                });
              }
              return placeholder;
            },
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
