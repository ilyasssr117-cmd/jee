import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Whether the user has already answered the age question.
Future<bool> ageAlreadyAsked() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool('age_asked') ?? false;
  } catch (_) {
    return false;
  }
}

/// Clears the stored answer so the gate is shown again.
/// Exposed in Settings > Privacy (fixes 06/42).
Future<void> resetAgeConfirmation() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('age_asked');
    await preferences.remove('is18');
  } catch (_) {}
}

/// Full-screen age gate (fix 06).
///
/// The audit found the age dialog only fired before ads and Reels,
/// while the adult Home feed itself was ungated. [AgeGate] wraps the
/// app's home content: nothing restricted renders until the user
/// confirms they are 18+. Answering No shows a clear exit state
/// instead of the content. No personal data is collected — only the
/// boolean answer is stored locally.
class AgeGate extends StatefulWidget {
  const AgeGate({super.key, required this.child});

  final Widget child;

  @override
  State<AgeGate> createState() => _AgeGateState();
}

class _AgeGateState extends State<AgeGate> {
  bool? _confirmed;
  bool _denied = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final asked = await ageAlreadyAsked();
    if (!mounted) return;
    if (!asked) {
      setState(() => _confirmed = null);
      return;
    }
    final ok = await confirmAge(context);
    if (mounted) {
      setState(() {
        _confirmed = ok;
        _denied = !ok;
      });
    }
  }

  Future<void> _answer() async {
    final ok = await confirmAge(context);
    if (!mounted) return;
    setState(() {
      _confirmed = ok;
      _denied = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_confirmed == true) return widget.child;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.eighteen_up_rating_outlined, size: 56),
              const SizedBox(height: 20),
              Text(
                _denied
                    ? 'VXTUBE contains adult content and is only '
                        'available to users who are 18 or older.'
                    : 'VXTUBE contains adult content.\n'
                        'Please confirm your age to continue.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.45),
              ),
              const SizedBox(height: 24),
              if (!_denied)
                FilledButton(
                  onPressed: _answer,
                  child: const Text('Confirm my age'),
                )
              else
                const Text(
                  'You can close the app now. If you made a mistake, '
                  'restart it and answer again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
