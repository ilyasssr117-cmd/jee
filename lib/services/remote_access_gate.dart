import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import 'remote_config_service.dart';

/// Applies server-delivered maintenance, update, and installation restriction
/// states around the existing app without changing its navigation structure.
class RemoteAccessGate extends StatefulWidget {
  const RemoteAccessGate({super.key, required this.child});

  final Widget child;

  @override
  State<RemoteAccessGate> createState() => _RemoteAccessGateState();
}

class _RemoteAccessGateState extends State<RemoteAccessGate> {
  bool _dismissUpdate = false;
  String? _dismissedVersion;

  @override
  Widget build(BuildContext context) {
    final remote = RemoteConfigService.instance;
    return AnimatedBuilder(
      animation: remote,
      builder: (context, _) {
        final config = remote.config;
        if (remote.isBanned) {
          return const _BlockingScreen(
            title: 'Access unavailable',
            message: 'This installation cannot access VXTUBE right now.',
          );
        }
        if (config.maintenanceEnabled) {
          return _BlockingScreen(
            title: 'VXTUBE is under maintenance',
            message: config.maintenanceMessage,
          );
        }
        if (remote.updateRequired) {
          return _BlockingScreen(
            title: 'Update required',
            message:
                'Install VXTUBE ${config.minimumVersion} or newer to continue.',
            actionLabel: 'Update VXTUBE',
            onAction: remote.updateUrl == null
                ? null
                : () => _openUpdate(remote.updateUrl!),
          );
        }
        final showUpdate = remote.updateAvailable &&
            !_dismissUpdate &&
            _dismissedVersion != config.latestVersion;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (showUpdate)
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Material(
                      color: AppColors.palette.brightness == Brightness.dark
                          ? const Color(0xFF1D2946)
                          : const Color(0xFFF2F5FF),
                      elevation: 5,
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(
                          children: [
                            Icon(Icons.system_update_alt,
                                color: AppColors.accentStrong),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'VXTUBE ${config.latestVersion} is available',
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: remote.updateUrl == null
                                  ? null
                                  : () => _openUpdate(remote.updateUrl!),
                              child: const Text('Update'),
                            ),
                            IconButton(
                              tooltip: 'Dismiss update notice',
                              onPressed: () => setState(() {
                                _dismissUpdate = true;
                                _dismissedVersion = config.latestVersion;
                              }),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _openUpdate(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class _BlockingScreen extends StatelessWidget {
  const _BlockingScreen({
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_circle_fill_rounded,
                    size: 54, color: AppColors.accentStrong),
                const SizedBox(height: 22),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, height: 1.5),
                ),
                if (actionLabel != null) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: onAction,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
