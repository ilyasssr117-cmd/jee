/// Remembers how far the viewer got in each video for the current app session.
///
/// It is intentionally in-memory: it powers "Resume" and the thin progress bar
/// on cards without adding a storage dependency. Swap the map for persistent
/// storage later without touching any widget.
class PlaybackProgress {
  PlaybackProgress._();

  static final PlaybackProgress instance = PlaybackProgress._();

  static const Duration _minimumResume = Duration(seconds: 15);
  static const Duration _finishedMargin = Duration(seconds: 20);
  static const int _maxEntries = 200;

  final Map<String, _Entry> _entries = <String, _Entry>{};

  void save(String id, Duration position, Duration duration) {
    if (duration <= Duration.zero) return;
    if (position < _minimumResume) return;
    if (position >= duration - _finishedMargin) {
      _entries.remove(id); // Finished: nothing to resume.
      return;
    }
    // Re-insert so the map stays ordered by recency, and cap its size.
    _entries
      ..remove(id)
      ..[id] = _Entry(position, duration);
    if (_entries.length > _maxEntries) _entries.remove(_entries.keys.first);
  }

  /// Position to resume from, or null if there is nothing worth resuming.
  Duration? resumePosition(String id) => _entries[id]?.position;

  /// Watched fraction in (0, 1), or null.
  double? fraction(String id) {
    final entry = _entries[id];
    if (entry == null || entry.duration <= Duration.zero) return null;
    return (entry.position.inMilliseconds / entry.duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  void clear(String id) => _entries.remove(id);
}

class _Entry {
  const _Entry(this.position, this.duration);

  final Duration position;
  final Duration duration;
}
