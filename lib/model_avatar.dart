import 'dart:async';

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../media_headers.dart';

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

  final String pageUrl;
  final double size;

  @override
  State<ModelAvatar> createState() => _ModelAvatarState();
}

class _ModelAvatarState extends State<ModelAvatar> {
  static const int _lastAttempt = 2;
  int _attempt = 0;
  Timer? _retryTimer;

  @override
  void didUpdateWidget(ModelAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _attempt = 0;
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  void _scheduleRetry() {
    if (_attempt >= _lastAttempt || _retryTimer != null) return;
    _retryTimer = Timer(Duration(milliseconds: 800 * (_attempt + 1)), () {
      _retryTimer = null;
      if (mounted) setState(() => _attempt++);
    });
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
        : Stack(
            fit: StackFit.expand,
            children: [
              placeholder,
              Image.network(
                url,
                fit: BoxFit.cover,
                // Retain the previous profile photo while a new URL loads.
                gaplessPlayback: true,
                cacheWidth:
                    (size * MediaQuery.devicePixelRatioOf(context)).round(),
                headers: _headers,
                errorBuilder: (context, error, stackTrace) {
                  // Retry slowly on unstable connections, without exposing
                  // signed image URLs or tokens in debug logs.
                  _scheduleRetry();
                  return placeholder;
                },
              ),
            ],
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
