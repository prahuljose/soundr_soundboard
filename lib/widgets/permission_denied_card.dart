import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/app_colors.dart';

/// A unified card explaining why a permission is needed and offering a clear
/// path to grant it. Handles two states automatically:
///
/// * **Soft denial** — user denied once. Shows an "Allow access" button that
///   re-requests the permission.
/// * **Permanent denial** — user denied with "Don't ask again" (or set to
///   blocked in system Settings). Re-requesting does nothing, so we show an
///   "Open Settings" button that deep-links to the app's permission page.
///
/// The card observes app lifecycle: if the user opens Settings and toggles
/// the permission on, the card re-checks on resume and calls [onGranted].
class PermissionDeniedCard extends StatefulWidget {
  /// The permission to gate. Most commonly [Permission.microphone].
  final Permission permission;

  /// Icon shown at the top of the card. e.g. [Icons.mic_rounded].
  final IconData icon;

  /// Short human label, e.g. "Microphone" or "Notifications".
  final String permissionLabel;

  /// One- or two-sentence explanation of why this app needs the permission.
  /// Body copy — keep it user-facing and reassuring.
  final String purpose;

  /// Called as soon as the permission transitions to granted (either via the
  /// in-card button or by the user returning from system Settings).
  final VoidCallback? onGranted;

  const PermissionDeniedCard({
    super.key,
    required this.permission,
    required this.icon,
    required this.permissionLabel,
    required this.purpose,
    this.onGranted,
  });

  @override
  State<PermissionDeniedCard> createState() => _PermissionDeniedCardState();
}

class _PermissionDeniedCardState extends State<PermissionDeniedCard>
    with WidgetsBindingObserver {
  PermissionStatus _status = PermissionStatus.denied;
  bool _busy = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on resume so changes made in system Settings take effect.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final s = await widget.permission.status;
    if (!mounted) return;
    setState(() {
      _status = s;
      _checking = false;
    });
    if (s.isGranted) widget.onGranted?.call();
  }

  Future<void> _requestAgain() async {
    setState(() => _busy = true);
    final s = await widget.permission.request();
    if (!mounted) return;
    setState(() {
      _status = s;
      _busy = false;
    });
    if (s.isGranted) widget.onGranted?.call();
  }

  Future<void> _openSettings() async {
    setState(() => _busy = true);
    await openAppSettings();
    // didChangeAppLifecycleState will re-check on resume.
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    if (_checking) {
      return const SizedBox.shrink();
    }

    final isPermanent = _status.isPermanentlyDenied;
    final title = isPermanent
        ? '${widget.permissionLabel} permission blocked'
        : '${widget.permissionLabel} access needed';
    final detail = isPermanent
        ? '${widget.purpose}\n\nYou\'ve blocked this permission. Open system settings to allow it.'
        : widget.purpose;
    final buttonLabel = isPermanent ? 'Open Settings' : 'Allow access';
    final onPressed = isPermanent ? _openSettings : _requestAgain;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Icon in a tinted circle
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.10),
              border: Border.all(
                color: accent.withValues(alpha: 0.30),
              ),
            ),
            child: Icon(widget.icon, color: accent, size: 26),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : onPressed,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : Icon(
                      isPermanent
                          ? Icons.settings_rounded
                          : Icons.lock_open_rounded,
                      size: 18,
                    ),
              label: Text(
                buttonLabel,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: accent.withValues(alpha: 0.40),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          // Reassurance footer — only for soft denial, before user grants.
          if (!isPermanent) ...[
            const SizedBox(height: 10),
            Text(
              'Processed on-device. Nothing leaves your phone.',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
