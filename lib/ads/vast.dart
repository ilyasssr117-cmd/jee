import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

Iterable<XmlElement> _elements(XmlDocument document, String localName) =>
    document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);

String? _firstText(XmlDocument document, String localName) {
  for (final element in _elements(document, localName)) {
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

List<String> _urls(Iterable<XmlElement> elements) => elements
    .map((element) => element.innerText.trim())
    .where(_isHttpUrl)
    .toList(growable: false);

Map<String, List<String>> _trackingEvents(XmlDocument document) {
  final events = <String, List<String>>{};
  for (final tracking in _elements(document, 'Tracking')) {
    final name = tracking.getAttribute('event');
    final url = tracking.innerText.trim();
    if (name == null || name.isEmpty || !_isHttpUrl(url)) continue;
    events.putIfAbsent(name, () => <String>[]).add(url);
  }
  return events;
}

Uri _cacheBusted(Uri uri) {
  final parameters = <String, String>{
    ...uri.queryParameters,
    '_cb': DateTime.now().microsecondsSinceEpoch.toString(),
  };
  return uri.replace(queryParameters: parameters);
}

Future<VastAd?> fetchVast(String vastTagUrl, {int depth = 0}) async {
  if (depth > 3 || !_isHttpUrl(vastTagUrl)) return null;

  try {
    final originalUri = Uri.parse(vastTagUrl);
    // Prevent a proxy/URL cache from reusing a previous VAST response. The
    // ExoClick zone ID and all existing query parameters remain unchanged.
    final requestUri = _cacheBusted(originalUri);
    final response = await http.get(
      requestUri,
      headers: const <String, String>{
        'Accept': 'application/xml, text/xml, */*',
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
      },
    ).timeout(const Duration(seconds: 8));

    debugPrint(
      '[ADS][VAST] depth=$depth status=${response.statusCode} '
      'bytes=${response.bodyBytes.length} '
      'content-type=${response.headers['content-type'] ?? 'unknown'}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (response.bodyBytes.isEmpty || response.bodyBytes.length > 1024 * 1024) {
      return null;
    }

    final xmlText = utf8.decode(response.bodyBytes, allowMalformed: true);
    final document = XmlDocument.parse(xmlText);
    final impressions = _urls(_elements(document, 'Impression'));
    final clickTracking = _urls(_elements(document, 'ClickTracking'));
    final wrapperEvents = _trackingEvents(document);

    final wrapperUrl = _firstText(document, 'VASTAdTagURI');
    if (wrapperUrl != null) {
      final nestedUri = originalUri.resolve(wrapperUrl);
      if (!_isHttpUrl(nestedUri.toString())) return null;
      final nested = await fetchVast(nestedUri.toString(), depth: depth + 1);
      if (nested == null) return null;

      final mergedEvents = <String, List<String>>{};
      for (final entry in wrapperEvents.entries) {
        mergedEvents[entry.key] = [...entry.value];
      }
      for (final entry in nested.events.entries) {
        mergedEvents.putIfAbsent(entry.key, () => <String>[]).addAll(entry.value);
      }
      return VastAd(
        nested.videoUrl,
        nested.clickUrl,
        [...impressions, ...nested.impressions],
        [...clickTracking, ...nested.clickTracking],
        mergedEvents,
      );
    }

    String? videoUrl;
    for (final mediaFile in _elements(document, 'MediaFile')) {
      final candidate = mediaFile.innerText.trim();
      if (!_isHttpUrl(candidate)) continue;
      final type = (mediaFile.getAttribute('type') ?? '').toLowerCase();
      final path = Uri.parse(candidate).path.toLowerCase();
      if (type.contains('mp4') || path.endsWith('.mp4')) {
        videoUrl = candidate;
        break;
      }
    }
    if (videoUrl == null) {
      debugPrint('[ADS][VAST] XML was valid but contained no supported MP4 MediaFile.');
      return null;
    }

    String? clickUrl;
    for (final clickThrough in _elements(document, 'ClickThrough')) {
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
  } catch (error) {
    debugPrint('[ADS][VAST] Parse/network failure: ${error.runtimeType}.');
    return null;
  }
}

void ping(List<String> urls) {
  for (final url in urls) {
    if (!_isHttpUrl(url)) continue;
    unawaited(
      http.get(Uri.parse(url)).then<void>((_) {}, onError: (_) {}),
    );
  }
}
