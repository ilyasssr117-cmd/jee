/// The catalog domains available from the home screen.
///
/// All three sources share the same scraper implementation; only the base
/// URL changes when the user switches between them.
enum ContentSource {
  fetish,
  straight,
  trans;

  /// Genre labels shown in the UI; actual domains stay internal.
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

  static ContentSource fromStoredValue(String? value) =>
      ContentSource.values.firstWhere(
        (source) => source.name == value,
        orElse: () => ContentSource.fetish,
      );
}
