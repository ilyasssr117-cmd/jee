import 'dart:collection';

import 'package:flutter/material.dart';

/// Fades a newly decoded thumbnail once, while cached/revisited items render
/// immediately. The small identity set survives sliver child disposal without
/// retaining decoded image data.
class FadeInThumbnail extends StatefulWidget {
  const FadeInThumbnail({
    super.key,
    required this.identity,
    required this.image,
    required this.fit,
    required this.errorBuilder,
    this.filterQuality = FilterQuality.medium,
    this.excludeFromSemantics = true,
  });

  final String identity;
  final ImageProvider<Object> image;
  final BoxFit fit;
  final ImageErrorWidgetBuilder errorBuilder;
  final FilterQuality filterQuality;
  final bool excludeFromSemantics;

  @override
  State<FadeInThumbnail> createState() => _FadeInThumbnailState();
}

class _FadeInThumbnailState extends State<FadeInThumbnail> {
  static const Duration _fadeDuration = Duration(milliseconds: 190);
  static const int _rememberedLimit = 256;
  static final LinkedHashSet<String> _shown = LinkedHashSet<String>();

  bool _knownLoaded = false;
  bool _receivedFrame = false;
  bool _fadeFinished = false;

  @override
  void initState() {
    super.initState();
    _knownLoaded = _isKnownLoaded(widget.identity);
  }

  @override
  void didUpdateWidget(covariant FadeInThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity == widget.identity) return;
    _knownLoaded = _isKnownLoaded(widget.identity);
    _receivedFrame = false;
    _fadeFinished = false;
  }

  static bool _isKnownLoaded(String identity) {
    final found = _shown.remove(identity);
    if (found) _shown.add(identity);
    return found;
  }

  static void _remember(String identity) {
    _shown
      ..remove(identity)
      ..add(identity);
    while (_shown.length > _rememberedLimit) {
      _shown.remove(_shown.first);
    }
  }

  void _completeFade() {
    if (!mounted || _fadeFinished) return;
    setState(() => _fadeFinished = true);
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      key: ValueKey<String>(widget.identity),
      image: widget.image,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
      excludeFromSemantics: widget.excludeFromSemantics,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame != null) {
          _remember(widget.identity);
          if (!_receivedFrame) {
            _receivedFrame = true;
            if (!_knownLoaded && !wasSynchronouslyLoaded) {
              Future<void>.delayed(_fadeDuration, _completeFade);
            } else {
              _knownLoaded = true;
            }
          }
        }
        if (_knownLoaded || _fadeFinished || wasSynchronouslyLoaded) {
          return child;
        }
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: _fadeDuration,
          curve: Curves.easeOut,
          child: child,
        );
      },
      errorBuilder: widget.errorBuilder,
    );
  }
}
