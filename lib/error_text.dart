import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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

/// Converts implementation/network failures into short, actionable copy.
/// HTTP status codes, exception names, hostnames and stack details are never
/// exposed to the app's normal UI.
FriendlyError describeError(Object error, {String subject = 'videos'}) {
  debugPrint('[ERROR] $subject: ${error.runtimeType}');

  const offline = FriendlyError(
    title: 'You’re offline',
    message: 'Check your internet connection and try again.',
    icon: Icons.wifi_off_rounded,
    offline: true,
  );

  if (error is TimeoutException ||
      error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException) {
    return offline;
  }

  if (error is ScraperException) {
    final text = error.message.toLowerCase();
    if (text.contains('could not reach') ||
        text.contains('connection') ||
        text.contains('timed out')) {
      return offline;
    }
    if (text.contains('configure')) {
      return FriendlyError(
        title: 'Video source not configured',
        message: 'Choose a video source in Settings and try again.',
        icon: Icons.settings_outlined,
      );
    }
    return FriendlyError(
      title: 'Unable to load $subject',
      message: 'The source could not provide this content. Please try again.',
      icon: Icons.cloud_off_rounded,
    );
  }

  if (error is HttpException) {
    return FriendlyError(
      title: 'Service unavailable',
      message: 'We couldn’t load this right now. Please try again in a moment.',
      icon: Icons.cloud_off_rounded,
    );
  }

  if (error is FormatException) {
    return FriendlyError(
      title: 'Unable to display $subject',
      message: 'This content could not be read. Please try again later.',
      icon: Icons.error_outline_rounded,
    );
  }

  return FriendlyError(
    title: 'Unable to load $subject',
    message: 'Something went wrong. Please try again.',
    icon: Icons.error_outline_rounded,
  );
}
