import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class VastAd {
  const VastAd(
    this.videoUrl,
    this.clickUrl,
    this.impressions,
    this.clickTracking,
    this.events,
  );

  final String videoUrl;
  final String? clickUrl;
  final List<String> impressions;
  final List<String> clickTracking;
  final Map<String, List<String>> events;
}

bool _isHttpUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

List<String> _urls(Iterable<XmlElement> elements) => elements
    .map((element) => element.innerText.trim())
    .where(_isHttpUrl)
    .toList(growable: false);

Map<String, List<String>> _trackingEvents(XmlDocument document) {
  final events = <String, List<String>>{};
  for (final tracking in document.findAllElements('Tracking')) {
    final name = tracking.getAttribute('event');
    final url = tracking.innerText.trim();
    if (name == null || name.isEmpty || !_isHttpUrl(url)) continue;
    events.putIfAbsent(name, () => <String>[]).add(url);
  }
  return events;
}

Future<VastAd?> fetchVast(String vastTagUrl, {int depth = 0}) async {
  if (depth > 3 || !_isHttpUrl(vastTagUrl)) return null;
  try {
    final tagUri = Uri.parse(vastTagUrl);
    final response = await http.get(tagUri, headers: const {
      'Accept': 'application/xml, text/xml'
    }).timeout(const Duration(seconds: 6));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (response.bodyBytes.length > 1024 * 1024) return null;

    final document = XmlDocument.parse(response.body);
    final wrapperUris = document.findAllElements('VASTAdTagURI');
    final impressions = _urls(document.findAllElements('Impression'));
    final clickTracking = _urls(document.findAllElements('ClickTracking'));
    final wrapperEvents = _trackingEvents(document);

    if (wrapperUris.isNotEmpty) {
      final wrapperUrl = wrapperUris.first.innerText.trim();
      final nestedUri = tagUri.resolve(wrapperUrl);
      if (!_isHttpUrl(nestedUri.toString())) return null;
      final nested = await fetchVast(nestedUri.toString(), depth: depth + 1);
      if (nested == null) return null;
      final mergedEvents = <String, List<String>>{
        for (final entry in wrapperEvents.entries) entry.key: [...entry.value],
        for (final entry in nested.events.entries)
          entry.key: [...?wrapperEvents[entry.key], ...entry.value],
      };
      return VastAd(
        nested.videoUrl,
        nested.clickUrl,
        [...impressions, ...nested.impressions],
        [...clickTracking, ...nested.clickTracking],
        mergedEvents,
      );
    }

    String? videoUrl;
    for (final mediaFile in document.findAllElements('MediaFile')) {
      final candidate = mediaFile.innerText.trim();
      final type = (mediaFile.getAttribute('type') ?? '').toLowerCase();
      final uri = Uri.tryParse(candidate);
      if (_isHttpUrl(candidate) &&
          (type.contains('mp4') ||
              (uri?.path.toLowerCase().endsWith('.mp4') ?? false))) {
        videoUrl = candidate;
        break;
      }
    }
    if (videoUrl == null) return null;

    String? clickUrl;
    for (final clickThrough in document.findAllElements('ClickThrough')) {
      final candidate = clickThrough.innerText.trim();
      if (_isHttpUrl(candidate)) {
        clickUrl = candidate;
        break;
      }
    }

    return VastAd(
      videoUrl,
      clickUrl,
      impressions,
      clickTracking,
      wrapperEvents,
    );
  } catch (_) {
    return null;
  }
}

void ping(List<String> urls) {
  for (final url in urls) {
    if (!_isHttpUrl(url)) continue;
    unawaitedPing(url);
  }
}

void unawaitedPing(String url) {
  unawaited(http.get(Uri.parse(url)).then<void>((_) {}, onError: (_) {}));
}
