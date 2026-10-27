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
    this.previewUrl = '',
  });

  final String id;
  final String title;
  final String streamUrl;
  /// Optional page URL for catalogues that resolve the playable stream on demand.
  final String? pageUrl;
  final String description;
  final String? thumbnailUrl;

  /// Short muted preview clip exposed on the list card (`data-preview`).
  /// Empty when the source doesn't provide one. Not persisted (it can expire).
  final String previewUrl;
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
    String? previewUrl,
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
      previewUrl: previewUrl ?? this.previewUrl,
    );
  }
}

/// A model / channel that published a video (the "Models:" row of its page).
class ModelRef {
  const ModelRef({required this.name, required this.url});

  final String name;

  /// Model page, always ending with a slash: `https://site/models/slug/`.
  final String url;

  @override
  bool operator ==(Object other) => other is ModelRef && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Name and photo of a model. The photo is missing for some models.
class ModelProfile {
  const ModelProfile({required this.name, this.imageUrl});

  final String name;
  final String? imageUrl;
}

/// One page of a model's videos. [profile] is only read from the first page.
class ModelPageResult {
  const ModelPageResult({required this.videos, this.profile});

  final List<Video> videos;
  final ModelProfile? profile;
}

/// A photo album of a model (`/albums/<id>/<slug>/`).
class AlbumRef {
  const AlbumRef({
    required this.id,
    required this.title,
    required this.url,
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String url;

  /// The album's preview picture (portrait), when the card has one.
  final String? thumbnailUrl;

  @override
  bool operator ==(Object other) => other is AlbumRef && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// One picture of an album: a small thumbnail for the grid and the address of
/// the full-size picture for the viewer.
class AlbumPhoto {
  const AlbumPhoto({
    required this.id,
    required this.thumbUrl,
    required this.fullUrl,
  });

  final String id;
  final String thumbUrl;
  final String fullUrl;
}
