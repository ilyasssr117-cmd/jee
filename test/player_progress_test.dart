// Tests for the logic extracted from player_page.dart in the final
// architecture pass: duration formatting used by the seek row.
import 'package:flutter_test/flutter_test.dart';

import 'package:vxtube_final/widgets/player_progress.dart';

void main() {
  group('formatPlayerDuration', () {
    test('formats zero and sub-minute durations as mm:ss', () {
      expect(formatPlayerDuration(Duration.zero), '00:00');
      expect(formatPlayerDuration(const Duration(seconds: 7)), '00:07');
      expect(formatPlayerDuration(const Duration(seconds: 59)), '00:59');
    });

    test('formats minutes with padded seconds', () {
      expect(
        formatPlayerDuration(const Duration(minutes: 3, seconds: 5)),
        '03:05',
      );
      expect(
        formatPlayerDuration(const Duration(minutes: 59, seconds: 59)),
        '59:59',
      );
    });

    test('switches to h:mm:ss at one hour', () {
      expect(
        formatPlayerDuration(const Duration(hours: 1)),
        '1:00:00',
      );
      expect(
        formatPlayerDuration(
          const Duration(hours: 2, minutes: 4, seconds: 9),
        ),
        '2:04:09',
      );
    });
  });
}
