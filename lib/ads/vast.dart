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

/// Replaces common VAST macros and strips any leftover [MACRO] placeholders
/// (for example [ERRORCODE]) so tracking URLs are always valid.
String _cleanMacros(String value) {
  final now = DateTime.now();
  return value
      .trim()
      .replaceAll('[TIMESTAMP]', now.millisecondsSinceEpoch.toString())
      .replaceAll('[CACHEBUSTING]', now.microsecondsSinceEpoch.toString())
      .replaceAll('[RANDOM]', now.microsecondsSinceEpoch.toString())
      .replaceAll(RegExp(r'\[[A-Z_]+\]'), '');
}

bool _isHttpUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

Iterable<XmlElement> _elements(XmlNode node, String localName) =>
    node.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);

String? _firstText(XmlNode node, String localName) {
  for (final element in _elements(node, localName)) {
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

List<String> _urls(Iterable<XmlElement> elements) => elements
    .map((element) => _cleanMacros(element.innerText))
    .where(_isHttpUrl)
    .toList(growable: false);

Map<String, List<String>> _trackingEvents(XmlNode node) {
  final events = <String, List<String>>{};
  for (final tracking in _elements(node, 'Tracking')) {
    final name = tracking.getAttribute('event');
    final url = _cleanMacros(tracking.innerText);
    if (name == null || name.isEmpty || !_isHttpUrl(url)) continue;
    events.putIfAbsent(name, () => <String>[]).add(url);
  }
  return events;
}

/// Only the ExoClick-hosted tag is known to accept an extra query parameter;
/// other networks use signed/path-token URLs, so they are requested as-is.
Uri _requestUri(Uri uri) {
  if (uri.host != 's.magsrv.com') return uri;
  return uri.replace(
    queryParameters: <String, String>{
      ...uri.queryParameters,
      '_cb': DateTime.now().microsecondsSinceEpoch.toString(),
    },
  );
}

/// Picks the MP4 whose width is closest to 640 (good quality, light download).
String? _pickMp4(XmlNode node) {
  String? best;
  var bestDistance = 1 << 30;
  for (final mediaFile in _elements(node, 'MediaFile')) {
    final candidate = _cleanMacros(mediaFile.innerText);
    if (!_isHttpUrl(candidate)) continue;
    final type = (mediaFile.getAttribute('type') ?? '').toLowerCase();
    final path = Uri.parse(candidate).path.toLowerCase();
    if (!(type.contains('mp4') || path.endsWith('.mp4'))) continue;
    final width = int.tryParse(mediaFile.getAttribute('width') ?? '') ?? 640;
    final distance = (width - 640).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = candidate;
    }
  }
  return best;
}

/// Fetches a VAST tag, follows wrappers (accumulating every wrapper's
/// Impression / ClickTracking / Tracking URLs so each network gets credit),
/// and uses ONLY the first <Ad> of each response. Trackers of ads that are
/// not shown are never fired. Error URLs are never fired.
Future<VastAd?> fetchVast(String vastTagUrl, {int depth = 0}) async {
  if (depth > 3 || !_isHttpUrl(vastTagUrl)) return null;

  try {
    final originalUri = Uri.parse(vastTagUrl);
    final response = await http.get(
      _requestUri(originalUri),
      headers: const <String, String>{
        'Accept': 'application/xml, text/xml, */*',
        'Cache-Control': 'no-cache, no-store, max-age=0',
        'Pragma': 'no-cache',
      },
    ).timeout(const Duration(seconds: 5));

    debugPrint(
      '[ADS][VAST] host=${originalUri.host} depth=$depth '
      'status=${response.statusCode} bytes=${response.bodyBytes.length}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (response.bodyBytes.isEmpty || response.bodyBytes.length > 1024 * 1024) {
      return null;
    }

    final xmlText = utf8.decode(response.bodyBytes, allowMalformed: true);
    final document = XmlDocument.parse(xmlText);

    final ads = _elements(document, 'Ad').toList(growable: false);
    if (ads.isEmpty) {
      debugPrint('[ADS][VAST] host=${originalUri.host}: empty VAST (no <Ad>).');
      return null;
    }
    final ad = ads.first; // the only ad that will actually be shown

    final impressions = _urls(_elements(ad, 'Impression'));
    final clickTracking = _urls(_elements(ad, 'ClickTracking'));
    final wrapperEvents = _trackingEvents(ad);

    final wrapperUrl = _firstText(ad, 'VASTAdTagURI');
    if (wrapperUrl != null) {
      final nestedUri = originalUri.resolve(_cleanMacros(wrapperUrl));
      if (!_isHttpUrl(nestedUri.toString())) return null;
      final nested = await fetchVast(nestedUri.toString(), depth: depth + 1);
      if (nested == null) return null;

      final mergedEvents = <String, List<String>>{};
      for (final entry in wrapperEvents.entries) {
        mergedEvents[entry.key] = [...entry.value];
      }
      for (final entry in nested.events.entries) {
        mergedEvents
            .putIfAbsent(entry.key, () => <String>[])
            .addAll(entry.value);
      }
      return VastAd(
        nested.videoUrl,
        nested.clickUrl,
        [...impressions, ...nested.impressions],
        [...clickTracking, ...nested.clickTracking],
        mergedEvents,
      );
    }

    final videoUrl = _pickMp4(ad);
    if (videoUrl == null) {
      debugPrint('[ADS][VAST] valid XML but no supported MP4 MediaFile.');
      return null;
    }

    String? clickUrl;
    for (final clickThrough in _elements(ad, 'ClickThrough')) {
      final candidate = _cleanMacros(clickThrough.innerText);
      if (_isHttpUrl(candidate)) {
        clickUrl = candidate;
        break;
      }
    }

    return VastAd(videoUrl, clickUrl, impressions, clickTracking, wrapperEvents);
  } catch (error) {
    debugPrint('[ADS][VAST] parse/network failure: ${error.runtimeType}.');
    return null;
  }
}

void ping(List<String> urls) {
  for (final raw in urls) {
    final url = _cleanMacros(raw);
    if (!_isHttpUrl(url)) continue;
    unawaited(
      http.get(Uri.parse(url)).then<void>((_) {}, onError: (_) {}),
    );
  }
}
