import 'models.dart';

Map<String, dynamic> videoToJson(Video video) => <String, dynamic>{
      'id': video.id,
      'title': video.title,
      'thumb': video.thumbnailUrl,
      'page': video.pageUrl,
      'duration': video.duration,
      'views': video.views,
      'likes': video.likes,
      'date': video.date,
      'category': video.category,
    };

Video? videoFromJson(Map<String, dynamic> map) {
  final id = map['id'];
  final title = map['title'];
  if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
    return null;
  }
  String text(String key) => map[key] is String ? map[key] as String : '';
  String? optional(String key) {
    final value = text(key);
    return value.isEmpty ? null : value;
  }

  return Video(
    id: id,
    title: title,
    thumbnailUrl: optional('thumb'),
    pageUrl: optional('page'),
    duration: text('duration'),
    views: text('views'),
    likes: text('likes'),
    date: text('date'),
    category: text('category').isEmpty ? 'Video' : text('category'),
  );
}
