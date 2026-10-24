class Video {
  const Video({
    required this.id,
    required this.title,
    this.streamUrl = '',
    this.description = '',
    this.thumbnailUrl,
    this.duration = '',
    this.views = '',
    this.likes = '',
    this.date = '',
    this.category = 'Featured',
    this.pageUrl,
  });

  final String id;
  final String title;
  final String streamUrl;
  /// Optional page URL for catalogues that resolve the playable stream on demand.
  final String? pageUrl;
  final String description;
  final String? thumbnailUrl;
  final String duration;
  final String views;

  /// Like ratio as shown by the source, e.g. `99%` (empty when unknown).
  final String likes;

  /// Upload date / age as shown by the source, e.g. `2 months ago`.
  final String date;
  final String category;

  Video copyWith({
    String? id,
    String? title,
    String? streamUrl,
    String? description,
    String? thumbnailUrl,
    String? duration,
    String? views,
    String? likes,
    String? date,
    String? category,
    String? pageUrl,
  }) {
    return Video(
      id: id ?? this.id,
      title: title ?? this.title,
      streamUrl: streamUrl ?? this.streamUrl,
      description: description ?? this.description,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      views: views ?? this.views,
      likes: likes ?? this.likes,
      date: date ?? this.date,
      category: category ?? this.category,
      pageUrl: pageUrl ?? this.pageUrl,
    );
  }
}
