import 'package:flutter/material.dart';

import 'data/budget_repository.dart';
import 'data/transaction_repository.dart';
import 'screens/auth_gate.dart';
import 'security/app_lock_controller.dart';
import 'security/app_lock_gate.dart';
import 'services/auth_service.dart';
import 'sms/sms_gateway.dart';
import 'sms/sms_settings.dart';
import 'theme/app_theme.dart';

/// Root widget: owns the [AuthService] and applies the theme.
class PennyWiseApp extends StatefulWidget {
  const PennyWiseApp({
    super.key,
    this.authService,
    this.repositoryForUser,
    this.budgetRepositoryForUser,
    this.smsGateway,
    this.smsSettingsForUser,
    this.appLock,
  });

  /// Optional auth service, so tests can run without Firebase.
  final AuthService? authService;

  /// Optional factory for a user's transaction repository, so tests can run
  /// without Firestore. Defaults to [FirestoreTransactionRepository].
  final TransactionRepository Function(String uid)? repositoryForUser;

  /// Same, for budgets. Defaults to [FirestoreBudgetRepository].
  final BudgetRepository Function(String uid)? budgetRepositoryForUser;

  /// Optional SMS access for automatic transaction detection, so tests can
  /// run without Android. Defaults to [AndroidSmsGateway].
  final SmsGateway? smsGateway;

  /// Same, for the detection settings. Defaults to [SharedPrefsSmsSettings].
  final SmsSettings Function(String uid)? smsSettingsForUser;

  /// Optional App Lock, so tests can use in-memory storage. Defaults to one
  /// backed by secure storage and the device's biometrics.
  final AppLockController? appLock;

  @override
  State<PennyWiseApp> createState() => _PennyWiseAppState();
}

class _PennyWiseAppState extends State<PennyWiseApp> {
  late final AuthService _authService =
      widget.authService ?? FirebaseAuthService();

  late final AppLockController _appLock =
      (widget.appLock ?? AppLockController())..init();

  /// "Forgot PIN? Sign out": signs out of Firebase first (if that fails,
  /// nothing changes), then clears App Lock on this device only. No cloud
  /// data is touched.
  Future<void> _forgotPin() async {
    await _authService.signOut();
    await _appLock.resetAfterSignOut();
  }

  @override
  void dispose() {
    _appLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PennyWise',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      // App Lock wraps every route and dialog, not just one screen.
      builder: (context, child) => AppLockScope(
        controller: _appLock,
        child: AppLockGate(
          controller: _appLock,
          onForgotPin: _forgotPin,
          child: child!,
        ),
      ),
      home: AuthGate(
        authService: _authService,
        repositoryForUser: widget.repositoryForUser ??
            (uid) => FirestoreTransactionRepository(uid: uid),
        budgetRepositoryForUser: widget.budgetRepositoryForUser ??
            (uid) => FirestoreBudgetRepository(uid: uid),
        smsGateway: widget.smsGateway ?? AndroidSmsGateway(),
        smsSettingsForUser: widget.smsSettingsForUser ??
            (uid) => SharedPrefsSmsSettings(uid: uid),
      ),
    );
  }
}
