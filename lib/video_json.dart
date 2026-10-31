import 'models.dart';

String _bounded(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

String? _boundedHttpUrl(String? value) {
  if (value == null || value.isEmpty || value.length > 4096) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return value;
}

/// Persist catalogue metadata only. Expiring media URLs and quality variants
/// are deliberately omitted so offline cache entries never keep stale streams.
Map<String, dynamic> videoToJson(Video video) => <String, dynamic>{
  'id': _bounded(video.id, 512),
  'title': _bounded(video.title, 300),
  'description': _bounded(video.description, 1500),
  'thumb': _boundedHttpUrl(video.thumbnailUrl),
  'page': _boundedHttpUrl(video.pageUrl),
  'duration': _bounded(video.duration, 64),
  'views': _bounded(video.views, 64),
  'likes': _bounded(video.likes, 64),
  'date': _bounded(video.date, 64),
  'category': _bounded(video.category, 100),
};

Video? videoFromJson(Map<String, dynamic> map) {
  final id = map['id'];
  final title = map['title'];
  if (id is! String ||
      id.isEmpty ||
      id.length > 512 ||
      title is! String ||
      title.isEmpty ||
      title.length > 300) {
    return null;
  }
  String text(String key, {int maxLength = 1500}) {
    final value = map[key];
    if (value is! String) return '';
    return _bounded(value, maxLength);
  }

  String? optional(String key) =>
      _boundedHttpUrl(map[key] is String ? map[key] as String : null);

  return Video(
    id: id,
    title: title,
    description: text('description'),
    thumbnailUrl: optional('thumb'),
    pageUrl: optional('page'),
    duration: text('duration', maxLength: 64),
    views: text('views', maxLength: 64),
    likes: text('likes', maxLength: 64),
    date: text('date', maxLength: 64),
    category: text('category', maxLength: 100).isEmpty
        ? 'Video'
        : text('category', maxLength: 100),
  );
}
