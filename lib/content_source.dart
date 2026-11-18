enum ContentSource {
  fetish,
  straight,
  trans;

  String get label => switch (this) {
    ContentSource.fetish => 'Fetish',
    ContentSource.straight => 'Straight',
    ContentSource.trans => 'Trans',
  };

  String get baseUrl => switch (this) {
    ContentSource.fetish => 'https://x-fetish.tube',
    ContentSource.straight => 'https://x-x-x.tube',
    ContentSource.trans => 'https://x-tg.tube',
  };

  String get cacheScope => '$name@${Uri.parse(baseUrl).host.toLowerCase()}';

  static ContentSource fromStoredValue(String? value) =>
      ContentSource.values.firstWhere(
        (source) => source.name == value,
        orElse: () => ContentSource.fetish,
      );
}
