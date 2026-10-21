import 'package:flutter/material.dart';

import '../sms/sms_gateway.dart';
import '../sms/sms_import_service.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// App settings. For now: the "Automatic Transaction Detection" switch.
///
/// SMS permission is never requested silently: turning the switch on first
/// explains what PennyWise reads and why, and only asks Android for the
/// permission if the user chooses to continue.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.smsService});

  final SmsImportService smsService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  SmsImportService get _sms => widget.smsService;

  Future<void> _onToggle(bool turnOn) async {
    setState(() => _busy = true);
    try {
      if (turnOn) {
        await _turnOn();
      } else {
        await _sms.disable();
        _showMessage('Automatic detection is off. PennyWise no longer reads '
            'your SMS. You can also remove the SMS permission in Android '
            'Settings.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOn() async {
    if (!_sms.hasPermission) {
      // 1. Explain first.
      final agreed = await showDialog<bool>(
        context: context,
        builder: (_) => const _PermissionExplanationDialog(),
      );
      if (agreed != true || !mounted) return;

      // 2. Then let Android ask.
      final status = await _sms.requestPermission();
      if (!mounted) return;
      switch (status) {
        case SmsPermissionStatus.granted:
          break;
        case SmsPermissionStatus.denied:
          _showMessage('SMS permission was not given, so automatic detection '
              'stays off. You can still add transactions manually.');
          return;
        case SmsPermissionStatus.permanentlyDenied:
          await _showBlockedDialog();
          return;
      }
    }
    await _sms.enable();
    _showMessage('Automatic detection is on. New M-Pesa and Airtel Money '
        'transactions will be added for you.');
  }

  /// Android won't show its dialog again; only the Settings app can help.
  Future<void> _showBlockedDialog() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SMS permission is blocked'),
        content: const Text(
          'Android won\'t ask again. To use automatic detection, open '
          'Settings › Permissions › SMS and choose "Allow".\n\n'
          'If the option is greyed out, the app was installed from a file: '
          'open App info, tap ⋮ (top right), choose "Allow restricted '
          'settings", then try again.\n\n'
          'Everything else in PennyWise, including adding transactions '
          'manually, works without it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (open == true) await _sms.openAppSettings();
  }

  Future<void> _scanRecent() async {
    final added = await _sms.scanRecent(days: 30);
    if (!mounted) return;
    final error = _sms.lastError;
    _showMessage(error ??
        (added == 0
            ? 'No new transactions found in the last 30 days.'
            : 'Added $added transaction${added == 1 ? '' : 's'} from the '
                'last 30 days.'));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: _sms,
        builder: (context, _) {
          final supported = _sms.isSupported;
          final enabled = _sms.isEnabled;
          final permissionMissing = supported && enabled && !_sms.hasPermission;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Card(
                child: SwitchListTile(
                  title: const Text(
                    'Automatic Transaction Detection',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(supported
                      ? 'Add M-Pesa and Airtel Money transactions from '
                          'their SMS automatically.'
                      : 'Available in the Android app only.'),
                  value: supported && enabled,
                  onChanged: !supported || _busy ? null : _onToggle,
                ),
              ),
              if (permissionMissing) ...[
                const SizedBox(height: 12),
                _Notice(
                  icon: Icons.warning_amber_rounded,
                  color: AppColors.warning,
                  text: 'Detection is on, but PennyWise no longer has SMS '
                      'permission, so nothing is being detected. Allow SMS '
                      'access in Settings, or turn detection off.',
                  actionLabel: 'Open settings',
                  onAction: _sms.openAppSettings,
                ),
              ],
              if (_sms.isActive) ...[
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: const Text('Import last 30 days'),
                        subtitle: const Text(
                            'Add transactions from older M-Pesa / Airtel '
                            'messages. Duplicates are skipped.'),
                        trailing: _sms.isScanning
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : null,
                        onTap: _sms.isScanning ? null : _scanRecent,
                      ),
                      if (_sms.lastScan != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Last checked: '
                              '${Formatters.relativeDate(_sms.lastScan!)} at '
                              '${_time(_sms.lastScan!)}',
                              style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (_sms.lastError != null) ...[
                const SizedBox(height: 12),
                _Notice(
                  icon: Icons.cloud_off_rounded,
                  color: AppColors.expense,
                  text: '${_sms.lastError} PennyWise will try again next '
                      'time you open the app.',
                ),
              ],
              const SizedBox(height: 20),
              const _HowItWorks(),
            ],
          );
        },
      ),
    );
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// Shown before Android's permission dialog: what is read, and why.
class _PermissionExplanationDialog extends StatelessWidget {
  const _PermissionExplanationDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.sms_outlined, color: AppColors.primary),
      title: const Text('Allow PennyWise to read transaction SMS?'),
      content: const SingleChildScrollView(
        child: Text(
          'To add your M-Pesa and Airtel Money transactions automatically, '
          'PennyWise needs permission to read SMS on this phone.\n\n'
          '• Only messages from M-Pesa and Airtel Money are read. All other '
          'SMS are ignored on the phone and never leave it.\n'
          '• From each transaction message, only the amount, type, '
          'merchant/sender, date and transaction code are saved to your '
          'account, plus a copy of that one message with phone and account '
          'numbers masked.\n'
          '• You can turn this off at any time in Settings.\n\n'
          'Android will now ask you to allow SMS access.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: AppColors.textSecondary, height: 1.4);
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How it works',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'When an M-Pesa or Airtel Money message arrives, PennyWise reads '
            'the amount, merchant and transaction code and adds it to your '
            'transactions with a suggested category. Tap it to change '
            'anything.\n\n'
            'Messages are checked while the app is open, and any that arrived '
            'while it was closed are added the next time you open it. Each '
            'transaction code is only ever added once.',
            style: style,
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(color: AppColors.textPrimary)),
                if (actionLabel != null)
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    child: Text(actionLabel!),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
