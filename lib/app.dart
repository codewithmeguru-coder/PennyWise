import 'package:flutter/material.dart';

import 'data/budget_repository.dart';
import 'data/transaction_repository.dart';
import 'screens/auth_gate.dart';
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

  @override
  State<PennyWiseApp> createState() => _PennyWiseAppState();
}

class _PennyWiseAppState extends State<PennyWiseApp> {
  late final AuthService _authService =
      widget.authService ?? FirebaseAuthService();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PennyWise',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
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
