import 'package:flutter_test/flutter_test.dart';
import 'package:vxtube_final/content_source.dart';

void main() {
  test('catalog sources map to their requested domains', () {
    expect(ContentSource.fetish.baseUrl, 'https://x-fetish.tube');
    expect(ContentSource.straight.baseUrl, 'https://x-x-x.tube');
    expect(ContentSource.trans.baseUrl, 'https://x-tg.tube');
  });

  test('catalog source labels are the home-screen choices', () {
    expect(
      ContentSource.values.map((source) => source.label).toList(),
      <String>['Fetish', 'Straight', 'Trans'],
    );
  });

  test('unknown saved source defaults to Fetish', () {
    expect(ContentSource.fromStoredValue('unknown'), ContentSource.fetish);
    expect(ContentSource.fromStoredValue(null), ContentSource.fetish);
  });
}
