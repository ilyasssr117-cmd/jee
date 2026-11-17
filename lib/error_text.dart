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
  // Keep technical details available to developers without exposing them in
  // the interface (HTTP codes, parser names, or implementation details).
  debugPrint('[ERROR] $subject: ${error.runtimeType}');

  const offline = FriendlyError(
    title: 'You’re offline',
    message: 'Check your internet connection and try again.',
    icon: Icons.wifi_off_rounded,
    offline: true,
  );

  if (error is TimeoutException) return offline;

  if (error is ScraperException) {
    if (error.statusCode != null) {
      return FriendlyError(
        title: 'Couldn’t load $subject',
        message: 'This content is temporarily unavailable. Please try again.',
        icon: Icons.cloud_off_rounded,
      );
    }
    final text = error.message.toLowerCase();
    if (text.contains('could not reach')) return offline;
    if (text.contains('configure')) {
      return const FriendlyError(
        title: 'Content unavailable',
        message: 'Check your content settings and try again.',
        icon: Icons.settings_outlined,
      );
    }
  }

  return FriendlyError(
    title: 'Couldn’t load $subject',
    message: 'Something went wrong. Please try again.',
    icon: Icons.error_outline_rounded,
  );
}
