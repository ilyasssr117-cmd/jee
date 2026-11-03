import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/player_page.dart';

void main() {
  test('restore position remains unchanged when it fits the new stream', () {
    expect(
      safePlaybackRestorePosition(
        const Duration(minutes: 2),
        const Duration(minutes: 5),
      ),
      const Duration(minutes: 2),
    );
  });

  test('restore position is clamped before the new stream ends', () {
    expect(
      safePlaybackRestorePosition(
        const Duration(minutes: 15),
        const Duration(minutes: 10),
      ),
      const Duration(minutes: 9, seconds: 59, milliseconds: 750),
    );
  });

  test('invalid or too-short stream durations skip seeking', () {
    expect(
      safePlaybackRestorePosition(
        const Duration(seconds: 1),
        Duration.zero,
      ),
      isNull,
    );
    expect(
      safePlaybackRestorePosition(
        const Duration(seconds: 1),
        const Duration(milliseconds: 200),
      ),
      isNull,
    );
  });
}
