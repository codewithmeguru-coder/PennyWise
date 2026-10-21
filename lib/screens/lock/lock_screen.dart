import 'dart:async';

import 'package:flutter/material.dart';

import '../../security/app_lock_controller.dart';
import '../../security/pin_hasher.dart';
import '../../theme/app_theme.dart';
import '../../widgets/pin_pad.dart';

/// Full-screen PIN entry shown over the whole app while it's locked.
///
/// It sits above the app's Navigator (see `AppLockGate`), so it uses no
/// dialogs: the "Forgot PIN?" confirmation is shown in place.
class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    required this.controller,
    required this.onForgotPin,
  });

  final AppLockController controller;

  /// Signs out of Firebase, then clears App Lock on this device.
  final Future<void> Function() onForgotPin;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _pin = '';
  String? _message;
  bool _busy = false;
  bool _confirmingSignOut = false;
  Timer? _ticker;

  AppLockController get _lock => widget.controller;
  bool get _unreadable => _lock.status == AppLockStatus.unreadable;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_onLockChanged);
    _startTickerIfLockedOut();
    // Offer the fingerprint once per lock, after the screen is up.
    if (_lock.biometricsEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _biometrics());
    }
  }

  @override
  void dispose() {
    _lock.removeListener(_onLockChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onLockChanged() {
    if (mounted) setState(() {});
  }

  void _startTickerIfLockedOut() {
    _ticker?.cancel();
    if (_lock.lockoutRemaining == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_lock.lockoutRemaining == null) {
        _ticker?.cancel();
        setState(() => _message = null);
      }
    });
  }

  void _digit(String d) {
    if (_pin.length >= PinHasher.maxLength) return;
    setState(() {
      _pin += d;
      _message = null;
    });
  }

  void _delete() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_pin.length < PinHasher.minLength || _busy) return;
    setState(() => _busy = true);
    final check = await _lock.unlockWithPin(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin = '';
      if (!check.ok) {
        _message = switch (check) {
          PinCheck(:final wait?) =>
            'Too many wrong PINs. Try again in ${formatWait(wait)}.',
          PinCheck(triesLeft: 1) => 'Wrong PIN. 1 try left before a pause.',
          PinCheck(:final triesLeft?) =>
            'Wrong PIN. $triesLeft tries left before a pause.',
          _ => 'Wrong PIN.',
        };
      }
    });
    _startTickerIfLockedOut();
  }

  Future<void> _biometrics() async {
    if (!mounted || _busy) return;
    final ok = await _lock.unlockWithBiometrics();
    if (!ok && mounted) {
      setState(() => _message = 'Fingerprint not recognised. Enter your PIN.');
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await widget.onForgotPin();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Couldn\'t sign out. Check your connection and try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wait = _lock.lockoutRemaining;
    final canType = wait == null && !_busy && !_unreadable;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: _confirmingSignOut
                    ? _signOutConfirmation()
                    : _pinEntry(wait, canType),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pinEntry(Duration? wait, bool canType) {
    final message = wait != null
        ? 'Too many wrong PINs. Try again in ${formatWait(wait)}.'
        : _unreadable
            ? 'App Lock settings on this phone couldn\'t be read. Sign out '
                'to reset App Lock, then sign in again.'
            : _message;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const CircleAvatar(
          radius: 32,
          backgroundColor: AppColors.primary,
          child: Icon(Icons.lock_rounded, color: Colors.white, size: 32),
        ),
        const SizedBox(height: 16),
        const Text(
          'PennyWise is locked',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Enter your PIN to continue',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 24),
        PinDots(length: _pin.length, error: message != null),
        SizedBox(
          height: 48,
          child: Center(
            child: message == null
                ? null
                : Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.expense),
                  ),
          ),
        ),
        PinPad(
          enabled: canType,
          onDigit: _digit,
          onDelete: _delete,
          bottomLeft: _lock.biometricsEnabled && !_unreadable
              ? IconButton(
                  tooltip: 'Use fingerprint',
                  onPressed: _busy ? null : _biometrics,
                  icon: const Icon(Icons.fingerprint_rounded, size: 32),
                  color: AppColors.primary,
                )
              : null,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed:
                canType && _pin.length >= PinHasher.minLength ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Unlock'),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _confirmingSignOut = true),
          child: const Text('Forgot PIN? Sign out'),
        ),
      ],
    );
  }

  Widget _signOutConfirmation() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.logout_rounded, size: 40, color: AppColors.primary),
        const SizedBox(height: 16),
        const Text(
          'Sign out and reset App Lock?',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'You\'ll be signed out of PennyWise, and App Lock will be turned off '
          'on this phone. Your transactions, budgets and profile stay safe in '
          'your account.\n\nSign in again with Google or your email to get '
          'back in, then set a new PIN in Settings.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.expense),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _signOut,
          style: FilledButton.styleFrom(backgroundColor: AppColors.expense),
          child: const Text('Sign out'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _confirmingSignOut = false;
                    _message = null;
                  }),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
