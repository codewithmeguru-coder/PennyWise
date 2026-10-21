import 'dart:async';

import 'package:flutter/material.dart';

import '../security/app_lock_controller.dart';
import '../security/pin_hasher.dart';
import '../theme/app_theme.dart';
import '../widgets/pin_pad.dart';

/// Settings › App Lock: turn it on or off, change the PIN, fingerprint
/// unlock and the auto-lock timeout. Changing or turning it off asks for the
/// current PIN first.
class AppLockSettingsScreen extends StatelessWidget {
  const AppLockSettingsScreen({super.key, required this.controller});

  final AppLockController controller;

  static String timeoutLabel(Duration d) => switch (d.inSeconds) {
        0 => 'Immediately',
        60 => 'After 1 minute',
        300 => 'After 5 minutes',
        final s => 'After $s seconds',
      };

  void _toast(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _turnOn(BuildContext context) async {
    final pin = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const PinSetupScreen()));
    if (pin == null || !context.mounted) return;
    await controller.enable(pin);
    if (context.mounted) _toast(context, 'App Lock is on.');
  }

  Future<void> _turnOff(BuildContext context) async {
    if (!await _verify(context, 'Enter your PIN to turn off App Lock')) {
      return;
    }
    await controller.disable();
    if (context.mounted) _toast(context, 'App Lock is off.');
  }

  Future<void> _changePin(BuildContext context) async {
    if (!await _verify(context, 'Enter your current PIN')) return;
    if (!context.mounted) return;
    final pin = await Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => const PinSetupScreen(title: 'New PIN')));
    if (pin == null || !context.mounted) return;
    await controller.changePin(pin);
    if (context.mounted) _toast(context, 'PIN changed.');
  }

  Future<bool> _verify(BuildContext context, String prompt) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) =>
            PinVerifyScreen(controller: controller, prompt: prompt)));
    return ok == true;
  }

  Future<void> _toggleBiometrics(BuildContext context, bool on) async {
    final ok = await controller.setBiometrics(on);
    if (!context.mounted) return;
    if (on && !ok) {
      _toast(context, 'Fingerprint not confirmed, so it stays off. '
          'Your PIN still works.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App Lock')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final on = controller.isEnabled;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.lock_outline_rounded),
                title: const Text('Use App Lock'),
                subtitle: const Text('Ask for a PIN when PennyWise opens or '
                    'comes back from the background. This is separate from '
                    'your PennyWise sign-in.'),
                value: on,
                onChanged: (value) =>
                    value ? _turnOn(context) : _turnOff(context),
              ),
              if (on) ...[
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.pin_outlined),
                  title: const Text('Change PIN'),
                  onTap: () => _changePin(context),
                ),
                if (controller.biometricsAvailable)
                  SwitchListTile(
                    secondary: const Icon(Icons.fingerprint_rounded),
                    title: const Text('Unlock with fingerprint or face'),
                    subtitle: const Text('Your PIN always works too.'),
                    value: controller.biometricsEnabled,
                    onChanged: (v) => _toggleBiometrics(context, v),
                  )
                else
                  const ListTile(
                    leading: Icon(Icons.fingerprint_rounded),
                    title: Text('Unlock with fingerprint or face'),
                    subtitle: Text('Not available: this phone has no '
                        'fingerprint or face set up for apps.'),
                    enabled: false,
                  ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'Lock after leaving the app',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                RadioGroup<Duration>(
                  groupValue: controller.timeout,
                  onChanged: (d) {
                    if (d != null) controller.setTimeout(d);
                  },
                  child: Column(
                    children: [
                      for (final d in AppLockController.timeouts)
                        RadioListTile<Duration>(
                          value: d,
                          title: Text(timeoutLabel(d)),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Create a PIN: enter it, then enter it again. Pops with the PIN.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key, this.title = 'Create a PIN'});

  final String title;

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String _pin = '';
  String? _first;
  String? _error;

  void _digit(String d) {
    if (_pin.length >= PinHasher.maxLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _delete() {
    if (_pin.isNotEmpty) {
      setState(() => _pin = _pin.substring(0, _pin.length - 1));
    }
  }

  void _next() {
    if (!PinHasher.isValidPin(_pin)) return;
    if (_first == null) {
      setState(() {
        _first = _pin;
        _pin = '';
      });
    } else if (_first == _pin) {
      Navigator.of(context).pop(_pin);
    } else {
      setState(() {
        _first = null;
        _pin = '';
        _error = 'The PINs didn\'t match. Start again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final confirming = _first != null;
    return _PinScaffold(
      title: widget.title,
      heading: confirming ? 'Confirm your PIN' : 'Choose a 4–6 digit PIN',
      hint: confirming
          ? 'Enter the same PIN again.'
          : 'You\'ll use it to open PennyWise on this phone.',
      pin: _pin,
      error: _error,
      onDigit: _digit,
      onDelete: _delete,
      actionLabel: confirming ? 'Confirm' : 'Next',
      onAction: PinHasher.isValidPin(_pin) ? _next : null,
    );
  }
}

/// Asks for the current PIN; pops with true when it's right. Wrong PINs
/// count towards the same lockout as the lock screen.
class PinVerifyScreen extends StatefulWidget {
  const PinVerifyScreen({
    super.key,
    required this.controller,
    required this.prompt,
  });

  final AppLockController controller;
  final String prompt;

  @override
  State<PinVerifyScreen> createState() => _PinVerifyScreenState();
}

class _PinVerifyScreenState extends State<PinVerifyScreen> {
  String _pin = '';
  String? _error;
  bool _busy = false;

  /// Refreshes the remaining wait during a lockout.
  late final Timer _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    if (mounted && widget.controller.lockoutRemaining != null) {
      setState(() {});
    }
  });

  @override
  void initState() {
    super.initState();
    _ticker; // start it
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  void _digit(String d) {
    if (_pin.length >= PinHasher.maxLength) return;
    setState(() {
      _pin += d;
      _error = null;
    });
  }

  void _delete() {
    if (_pin.isNotEmpty) {
      setState(() => _pin = _pin.substring(0, _pin.length - 1));
    }
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    final check = await widget.controller.checkPin(_pin);
    if (!mounted) return;
    if (check.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _pin = '';
      _error = switch (check) {
        PinCheck(:final wait?) =>
          'Too many wrong PINs. Try again in ${formatWait(wait)}.',
        PinCheck(:final triesLeft?) =>
          'Wrong PIN. $triesLeft ${triesLeft == 1 ? 'try' : 'tries'} left.',
        _ => 'Wrong PIN.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final wait = widget.controller.lockoutRemaining;
    return _PinScaffold(
      title: 'Confirm it\'s you',
      heading: widget.prompt,
      hint: '',
      pin: _pin,
      error: wait != null
          ? 'Too many wrong PINs. Try again in ${formatWait(wait)}.'
          : _error,
      enabled: wait == null && !_busy,
      onDigit: _digit,
      onDelete: _delete,
      actionLabel: 'Continue',
      onAction: wait == null && !_busy && PinHasher.isValidPin(_pin)
          ? _check
          : null,
    );
  }
}

class _PinScaffold extends StatelessWidget {
  const _PinScaffold({
    required this.title,
    required this.heading,
    required this.hint,
    required this.pin,
    required this.error,
    required this.onDigit,
    required this.onDelete,
    required this.actionLabel,
    required this.onAction,
    this.enabled = true,
  });

  final String title;
  final String heading;
  final String hint;
  final String pin;
  final String? error;
  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final String actionLabel;
  final VoidCallback? onAction;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            children: [
              Text(
                heading,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              if (hint.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ],
              const SizedBox(height: 24),
              PinDots(length: pin.length, error: error != null),
              SizedBox(
                height: 48,
                child: Center(
                  child: error == null
                      ? null
                      : Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.expense),
                        ),
                ),
              ),
              PinPad(onDigit: onDigit, onDelete: onDelete, enabled: enabled),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onAction,
                  child: Text(actionLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
