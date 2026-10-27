import 'dart:async';

import 'package:flutter/material.dart';

import 'scraper.dart';

/// User-facing description of a failure. Raw exception text never reaches the
/// viewer; it is only printed to the debug console.
class FriendlyError {
  const FriendlyError({
    required this.title,
    required this.message,
    required this.icon,
    this.offline = false,
  });

  final String title;
  final String message;
  final IconData icon;
  final bool offline;
}

/// Converts any thrown object into something a viewer can act on.
/// [subject] completes the title, e.g. "Unable to load videos".
FriendlyError describeError(Object error, {String subject = 'videos'}) {
  debugPrint('[ERROR] $subject: ${error.runtimeType}');

  const offline = FriendlyError(
    title: 'No connection',
    message: 'Check your internet connection, then try again.',
    icon: Icons.wifi_off_rounded,
    offline: true,
  );

  if (error is TimeoutException) return offline;

  if (error is ScraperException) {
    final code = error.statusCode;
    if (code != null) {
      return FriendlyError(
        title: 'Unable to load $subject',
        message: 'The video source returned an error ($code). '
            'Please try again in a moment.',
        icon: Icons.cloud_off_rounded,
      );
    }
    final text = error.message.toLowerCase();
    if (text.contains('could not reach')) return offline;
    if (text.contains('security check')) {
      return const FriendlyError(
        title: 'The source is blocking the app',
        message: 'The video source is asking for a security check. '
            'Try again later or from another network.',
        icon: Icons.shield_outlined,
      );
    }
    if (text.contains('layout') || text.contains('no readable video list')) {
      return const FriendlyError(
        title: 'Couldn\u2019t read the video list',
        message: 'The source page looks different from what the app '
            'expects. Check the selectors in lib/video_repository.dart.',
        icon: Icons.web_asset_off_rounded,
      );
    }
    if (text.contains('configure')) {
      return FriendlyError(
        title: 'Video source not configured',
        message: error.message,
        icon: Icons.settings_outlined,
      );
    }
  }

  return FriendlyError(
    title: 'Unable to load $subject',
    message: 'Something went wrong while contacting the video source.',
    icon: Icons.error_outline_rounded,
  );
}
