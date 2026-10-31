class StreamQuality {
  const StreamQuality({required this.height, required this.url});

  final int height;
  final String url;
}

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
    this.qualities = const <StreamQuality>[],
  });

  final String id;
  final String title;
  final String streamUrl;
  final String? pageUrl;
  final String description;
  final String? thumbnailUrl;

  final String previewUrl;

  final List<StreamQuality> qualities;
  final String duration;
  final String views;

  final String likes;

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
    List<StreamQuality>? qualities,
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
      qualities: qualities ?? this.qualities,
    );
  }

  bool get isReel => id.startsWith('reel_');

  /// Reels have no page to re-resolve from, so their direct URL must survive
  /// persistence. Everything else keeps the old behaviour (URL stripped).
  Video withoutStream() => isReel ? this : copyWith(streamUrl: '');

  String streamForQuality(int preferred) {
    if (preferred <= 0 || qualities.length < 2) return streamUrl;
    for (final option in qualities) {
      if (option.height <= preferred) return option.url;
    }
    return qualities.last.url;
  }
}

class ModelRef {
  const ModelRef({required this.name, required this.url, this.imageUrl});

  final String name;

  final String url;

  final String? imageUrl;

  ModelRef withImage(String? image) =>
      ModelRef(name: name, url: url, imageUrl: image ?? imageUrl);

  @override
  bool operator ==(Object other) => other is ModelRef && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

class ModelProfile {
  const ModelProfile({required this.name, this.imageUrl});

  final String name;
  final String? imageUrl;
}

class ModelPageResult {
  const ModelPageResult({required this.videos, this.profile});

  final List<Video> videos;
  final ModelProfile? profile;
}

class AlbumRef {
  const AlbumRef({
    required this.id,
    required this.title,
    required this.url,
    this.thumbnailUrl,
    this.modelName,
  });

  final String id;
  final String title;
  final String url;

  final String? modelName;

  final String? thumbnailUrl;

  @override
  bool operator ==(Object other) => other is AlbumRef && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

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

class PeopleSearchResult {
  const PeopleSearchResult({required this.models, required this.albums});

  final List<ModelRef> models;
  final List<AlbumRef> albums;

  bool get isEmpty => models.isEmpty && albums.isEmpty;
}
