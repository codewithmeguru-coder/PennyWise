import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../utils/validators.dart';
import 'auth_widgets.dart';

/// Email/password account creation. Pushed on top of [LoginScreen].
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.authService});

  final AuthService authService;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  // Firebase Auth's own minimum.
  static const _minPasswordLength = 6;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _googleLoading = false;

  /// True while either sign-in method is running.
  bool get _busy => _loading || _googleLoading;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    // The keyboard's "done" and the button can both fire before the button
    // is disabled; don't submit twice.
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authService.register(
        name: _nameController.text,
        email: _emailController.text,
        password: _passwordController.text,
      );
      // The user is now signed in and AuthGate is showing the home shell
      // underneath this route, so close it.
      if (mounted) Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _continueWithGoogle() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _googleLoading = true;
      _error = null;
    });
    try {
      final signedIn = await widget.authService.signInWithGoogle();
      // Signed in: AuthGate is now showing the dashboard underneath this
      // route, so close it (same as email registration).
      if (signedIn && mounted) Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Enter a password';
    if (value.length < _minPasswordLength) {
      return 'Use at least $_minPasswordLength characters';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final visibilityToggle = IconButton(
      tooltip: _obscurePassword ? 'Show password' : 'Hide password',
      icon: Icon(_obscurePassword
          ? Icons.visibility_outlined
          : Icons.visibility_off_outlined),
      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
    );

    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              const AuthHeader(
                title: 'Create your account',
                subtitle: 'Start budgeting smarter with PennyWise.',
              ),
              const SizedBox(height: 32),
              if (_error != null) ...[
                AuthErrorBanner(message: _error!),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _nameController,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  counterText: '',
                ),
                // Stored in the users/{uid} profile, which the rules cap at
                // 100 (UTF-16 units).
                validator: (value) => Validators.requiredText(
                  value,
                  emptyMessage: 'Enter your name',
                  max: 100,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: AuthValidators.email,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                enabled: !_busy,
                obscureText: _obscurePassword,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: 'At least $_minPasswordLength characters',
                  suffixIcon: visibilityToggle,
                ),
                validator: _validatePassword,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                enabled: !_busy,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _register(),
                decoration: const InputDecoration(labelText: 'Confirm password'),
                validator: (value) => value != _passwordController.text
                    ? 'Passwords don\'t match'
                    : null,
              ),
              const SizedBox(height: 28),
              AuthSubmitButton(
                label: 'Create account',
                loading: _loading,
                onPressed: _googleLoading ? null : _register,
              ),
              const SizedBox(height: 20),
              const AuthDivider(),
              const SizedBox(height: 20),
              GoogleSignInButton(
                loading: _googleLoading,
                onPressed: _loading ? null : _continueWithGoogle,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Already have an account?'),
                  TextButton(
                    onPressed:
                        _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Sign in'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
