import 'package:flutter_test/flutter_test.dart';
import 'package:watch_tube/request_cache.dart';

void main() {
  test('fetch completes (regression: it used to wait for itself forever)',
      () async {
    final cache = TtlCache<int>();
    final value = await cache
        .fetch('key', () async => 42)
        .timeout(const Duration(seconds: 2));
    expect(value, 42);
  });

  test('a fresh result is served from the cache without a second request',
      () async {
    final cache = TtlCache<int>();
    var calls = 0;
    Future<int> loader() async => ++calls;

    expect(await cache.fetch('key', loader), 1);
    expect(await cache.fetch('key', loader), 1);
    expect(calls, 1);
  });

  test('force skips the cache', () async {
    final cache = TtlCache<int>();
    var calls = 0;
    Future<int> loader() async => ++calls;

    await cache.fetch('key', loader);
    expect(await cache.fetch('key', loader, force: true), 2);
  });

  test('callers asking at the same time share one running request', () async {
    final cache = TtlCache<int>();
    var calls = 0;
    Future<int> loader() async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return 7;
    }

    final results = await Future.wait<int>([
      cache.fetch('key', loader),
      cache.fetch('key', loader),
    ]).timeout(const Duration(seconds: 2));

    expect(results, <int>[7, 7]);
    expect(calls, 1);
  });

  test('a failed request reports its error and can be retried', () async {
    final cache = TtlCache<int>();
    var calls = 0;
    Future<int> loader() async {
      calls++;
      if (calls == 1) throw StateError('network down');
      return 5;
    }

    await expectLater(cache.fetch('key', loader), throwsStateError);
    expect(await cache.fetch('key', loader), 5);
    expect(calls, 2);
  });
}
