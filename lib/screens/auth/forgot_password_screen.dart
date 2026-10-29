import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import 'auth_widgets.dart';

/// "Forgot password?": sends a Firebase password-reset email.
///
/// After sending, it always shows the same message, whether or not an
/// account uses that email, so nobody can find out who is registered.
/// Sending again is possible after [resendDelay]. Pops with the email typed
/// here, so the sign-in screen can keep it.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({
    super.key,
    required this.authService,
    this.initialEmail = '',
  });

  final AuthService authService;

  /// What was typed on the sign-in screen.
  final String initialEmail;

  static const resendDelay = Duration(seconds: 60);

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _email = TextEditingController(text: widget.initialEmail.trim());

  bool _sending = false;
  String? _error;

  /// The address the last request went to; null until one succeeds.
  String? _sentTo;

  /// Seconds until another request is allowed (0: allowed).
  int _wait = 0;
  Timer? _timer;

  bool get _canSend => !_sending && _wait == 0;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() => _wait = ForgotPasswordScreen.resendDelay.inSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _wait--);
      if (_wait <= 0) {
        _wait = 0;
        t.cancel();
      }
    });
  }

  Future<void> _send() async {
    // The keyboard's "done" and the button can both fire; and no new
    // request while the countdown runs.
    if (!_canSend) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final email = _email.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.authService.sendPasswordReset(email);
      if (!mounted) return;
      setState(() => _sentTo = email);
      _startCountdown();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _back() => Navigator.of(context).pop(_email.text.trim());

  @override
  Widget build(BuildContext context) {
    final sentTo = _sentTo;
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: [
              const AuthHeader(
                title: 'Reset your password',
                subtitle:
                    'Enter the email you sign in with. We\'ll send a '
                    'link to choose a new password.',
              ),
              const SizedBox(height: 28),
              if (_error != null) ...[
                AuthErrorBanner(message: _error!),
                const SizedBox(height: 16),
              ],
              if (sentTo != null) ...[
                _SentNotice(email: sentTo),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _email,
                enabled: !_sending,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _send(),
                decoration: const InputDecoration(labelText: 'Email'),
                validator: AuthValidators.email,
              ),
              const SizedBox(height: 24),
              AuthSubmitButton(
                label: sentTo == null
                    ? 'Send reset link'
                    : _wait > 0
                    ? 'Resend in ${_wait}s'
                    : 'Resend link',
                loading: _sending,
                onPressed: _canSend ? _send : null,
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: _sending ? null : _back,
                  child: const Text('Back to sign in'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The same words for every address: whether an account exists never shows.
class _SentNotice extends StatelessWidget {
  const _SentNotice({required this.email});

  final String email;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.mark_email_read_outlined, color: context.colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'If a PennyWise account with a password uses $email, '
                  'we\'ve sent a link to reset it. Check your inbox and '
                  'spam folder.',
                ),
                const SizedBox(height: 6),
                Text(
                  'If you use Continue with Google, sign in that way '
                  'instead.',
                  style: TextStyle(color: context.colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
