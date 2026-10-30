import 'dart:async';

import 'package:flutter/material.dart';

import 'scraper.dart';

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
