import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Structured in-app error log (audit fix 03).
///
/// Production error handlers used to swallow everything. AppLog keeps a
/// bounded ring buffer of structured entries, prints them in debug mode,
/// and exposes [entries] / [export] so a crash reporter (Sentry /
/// Crashlytics) can be attached in one place without touching call
/// sites. Entries never include tokens, cookies, URLs with query
/// strings, or user content: callers pass a short [scope] and a message
/// that has already been scrubbed by [scrub].
class AppLog {
  AppLog._();

  static const int _capacity = 200;
  static final ListQueue<String> _buffer = ListQueue<String>();

  /// Attach a crash reporter here, e.g.
  /// `AppLog.sink = (scope, error, stack) => Sentry.captureException(...)`.
  static void Function(String scope, Object error, StackTrace stack)? sink;

  static List<String> get entries => List<String>.unmodifiable(_buffer);

  static String export() => _buffer.join('\n');

  static String scrub(String value) {
    // Strip URL query strings and bearer-style tokens from messages.
    var out = value.replaceAll(RegExp(r'(https?://[^\s?]+)\?[^\s]+'), r'$1?…');
    out = out.replaceAll(
      RegExp(r'(token|apikey|api_key|authorization)[=:\s]+\S+', caseSensitive: false),
      r'$1=<redacted>',
    );
    return out.length > 500 ? out.substring(0, 500) : out;
  }

  static void error(String scope, Object error, [StackTrace? stack]) {
    final trace = stack ?? StackTrace.current;
    final line =
        '${DateTime.now().toUtc().toIso8601String()} [ERROR][$scope] '
        '${error.runtimeType}: ${scrub('$error')}';
    _push(line);
    if (kDebugMode) debugPrint('$line\n$trace');
    final s = sink;
    if (s != null) {
      try {
        s(scope, error, trace);
      } catch (_) {
        // A failing reporter must never take the app down with it.
      }
    }
  }

  static void warn(String scope, String message) {
    _push('${DateTime.now().toUtc().toIso8601String()} [WARN][$scope] '
        '${scrub(message)}');
    if (kDebugMode) debugPrint('[WARN][$scope] ${scrub(message)}');
  }

  static void _push(String line) {
    _buffer.addLast(line);
    while (_buffer.length > _capacity) {
      _buffer.removeFirst();
    }
  }
}

/// Runs [body] and reports (never rethrows) failures under [scope].
/// Use for fire-and-forget operations whose failure the user should
/// not see but the team must: persistence, remote config, analytics.
Future<void> guard(String scope, Future<void> Function() body) async {
  try {
    await body();
  } catch (error, stack) {
    AppLog.error(scope, error, stack);
  }
}
