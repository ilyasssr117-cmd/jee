import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks once and remembers the answer. Returns true only when the user
/// confirms they are 18 or older. If preferences cannot be read or saved,
/// ads stay disabled for this session.
Future<bool> confirmAge(BuildContext context) async {
  try {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool('age_asked') ?? false) {
      return preferences.getBool('is18') ?? false;
    }
    if (!context.mounted) return false;

    final answer = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Age confirmation'),
        content: const Text('Are you 18 or older?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    await preferences.setBool('age_asked', true);
    await preferences.setBool('is18', answer == true);
    return answer == true;
  } catch (_) {
    return false;
  }
}
