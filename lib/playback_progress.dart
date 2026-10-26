import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'local_store.dart';

/// Remembers how far the viewer got in each video, and which ones are
/// finished. Both survive closing and reopening the app (local storage).
///
/// Writes are batched (at most one every couple of seconds) and flushed when
/// the player closes or the app leaves the foreground.
class PlaybackProgress {
  PlaybackProgress._();

  static final PlaybackProgress instance = PlaybackProgress._();

  static const Duration _minimumResume = Duration(seconds: 15);
  static const Duration _finishedMargin = Duration(seconds: 20);
  static const int _maxEntries = 200;

  static const String _progressKey = 'progress_v1';
  static const String _completedKey = 'completed_v1';
  static const int _maxCompleted = 300;

  final Map<String, _Entry> _entries = <String, _Entry>{};

  /// Videos watched to the end, oldest first.
  final Set<String> _completed = <String>{};

  Timer? _persistTimer;
  bool _observing = false;

  void save(String id, Duration position, Duration duration) {
    if (duration <= Duration.zero) return;
    if (position < _minimumResume) return;
    if (position >= duration - _finishedMargin) {
      if (_entries.remove(id) != null) _schedulePersist(); // Finished.
      return;
    }
    // Watching it again: it is in progress, no longer "completed".
    if (_completed.remove(id)) _persistCompleted();
    // Re-insert so the map stays ordered by recency, and cap its size.
    _entries
      ..remove(id)
      ..[id] = _Entry(position, duration);
    if (_entries.length > _maxEntries) _entries.remove(_entries.keys.first);
    _schedulePersist();
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

  void clear(String id) {
    if (_entries.remove(id) != null) _schedulePersist();
  }

  // ---- Completed ----------------------------------------------------------

  /// Loads saved progress and completed videos (call once at start-up).
  void load() {
    _completed
      ..clear()
      ..addAll(LocalStore.readList(_completedKey));

    _entries.clear();
    for (final raw in LocalStore.readList(_progressKey)) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.length != 3) continue;
        final id = decoded[0];
        final position = decoded[1];
        final duration = decoded[2];
        if (id is! String || position is! int || duration is! int) continue;
        if (duration <= 0 || position <= 0) continue;
        _entries[id] = _Entry(
          Duration(milliseconds: position),
          Duration(milliseconds: duration),
        );
      } catch (_) {
        // Skip a corrupt entry.
      }
    }
    while (_entries.length > _maxEntries) {
      _entries.remove(_entries.keys.first);
    }

    if (!_observing) {
      _observing = true;
      WidgetsBinding.instance.addObserver(_Flusher(this));
    }
  }

  /// Writes any pending progress now (player closed / app backgrounded).
  void flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    _persistProgress();
  }

  void _schedulePersist() {
    _persistTimer ??= Timer(const Duration(seconds: 2), () {
      _persistTimer = null;
      _persistProgress();
    });
  }

  void _persistProgress() => LocalStore.writeList(
        _progressKey,
        <String>[
          for (final entry in _entries.entries)
            jsonEncode(<Object>[
              entry.key,
              entry.value.position.inMilliseconds,
              entry.value.duration.inMilliseconds,
            ]),
        ],
      );

  /// Forgets every resume point and every "watched" mark.
  void clearAll() {
    _entries.clear();
    _completed.clear();
    _persistProgress();
    _persistCompleted();
  }

  bool isCompleted(String id) => _completed.contains(id);

  /// The video reached its end: nothing to resume, and it is marked watched.
  void markCompleted(String id) {
    if (_entries.remove(id) != null) _schedulePersist();
    _completed
      ..remove(id)
      ..add(id);
    while (_completed.length > _maxCompleted) {
      _completed.remove(_completed.first);
    }
    _persistCompleted();
  }

  void _persistCompleted() =>
      LocalStore.writeList(_completedKey, _completed.toList(growable: false));
}

class _Flusher with WidgetsBindingObserver {
  _Flusher(this._progress);

  final PlaybackProgress _progress;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _progress.flush();
  }
}

class _Entry {
  const _Entry(this.position, this.duration);

  final Duration position;
  final Duration duration;
}
