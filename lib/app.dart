import 'package:flutter/material.dart';

import 'accounts/account_repository.dart';
import 'categorization/category_rule_repository.dart';
import 'data/avatar_repository.dart';
import 'data/budget_repository.dart';
import 'data/category_budget_repository.dart';
import 'data/category_repository.dart';
import 'data/transaction_repository.dart';
import 'screens/auth_gate.dart';
import 'security/app_lock_controller.dart';
import 'security/app_lock_gate.dart';
import 'services/auth_service.dart';
import 'services/photo_picker.dart';
import 'sms/sms_gateway.dart';
import 'sms/sms_settings.dart';
import 'theme/app_theme.dart';
import 'privacy/savings_privacy.dart';
import 'theme/appearance.dart';

/// Root widget: owns the [AuthService] and applies the theme.
class PennyWiseApp extends StatefulWidget {
  const PennyWiseApp({
    super.key,
    this.authService,
    this.repositoryForUser,
    this.budgetRepositoryForUser,
    this.categoryBudgetsForUser,
    this.categoriesForUser,
    this.avatarForUser,
    this.photoPicker,
    this.categoryRulesForUser,
    this.accountsForUser,
    this.smsGateway,
    this.smsSettingsForUser,
    this.appLock,
    this.appearance,
    this.savingsPrivacy,
  });

  /// Optional auth service, so tests can run without Firebase.
  final AuthService? authService;

  /// Optional factory for a user's transaction repository, so tests can run
  /// without Firestore. Defaults to [FirestoreTransactionRepository].
  final TransactionRepository Function(String uid)? repositoryForUser;

  /// Same, for budgets. Defaults to [FirestoreBudgetRepository].
  final BudgetRepository Function(String uid)? budgetRepositoryForUser;

  /// Same, for per-category limits. Defaults to
  /// [FirestoreCategoryBudgetRepository].
  final CategoryBudgetRepository Function(String uid)? categoryBudgetsForUser;

  /// Same, for the user's own categories. Defaults to
  /// [FirestoreCategoryRepository].
  final CategoryRepository Function(String uid)? categoriesForUser;

  /// Same, for the user's own profile photo. Defaults to
  /// [FirestoreAvatarRepository].
  final AvatarRepository Function(String uid)? avatarForUser;

  /// Chooses a profile photo. Defaults to [AndroidPhotoPicker].
  final PhotoPicker? photoPicker;

  /// Same, for learned category rules. Defaults to
  /// [FirestoreCategoryRuleRepository].
  final CategoryRuleRepository Function(String uid)? categoryRulesForUser;

  /// Same, for the user's own accounts. Defaults to
  /// [FirestoreAccountRepository].
  final AccountRepository Function(String uid)? accountsForUser;

  /// Optional SMS access for automatic transaction detection, so tests can
  /// run without Android. Defaults to [AndroidSmsGateway].
  final SmsGateway? smsGateway;

  /// Same, for the detection settings. Defaults to [SharedPrefsSmsSettings].
  final SmsSettings Function(String uid)? smsSettingsForUser;

  /// Optional App Lock, so tests can use in-memory storage. Defaults to one
  /// backed by secure storage and the device's biometrics.
  final AppLockController? appLock;

  /// Optional Light / Dark / System choice, so tests can keep it in
  /// memory. Defaults to one saved on this phone.
  final AppearanceController? appearance;

  /// Optional "Hide savings amounts", so tests can keep it in memory.
  final SavingsPrivacyController? savingsPrivacy;

  @override
  State<PennyWiseApp> createState() => _PennyWiseAppState();
}

class _PennyWiseAppState extends State<PennyWiseApp> {
  late final AuthService _authService =
      widget.authService ?? FirebaseAuthService();

  late final AppLockController _appLock =
      (widget.appLock ?? AppLockController())..init();

  late final AppearanceController _appearance =
      (widget.appearance ?? AppearanceController())..init();

  late final SavingsPrivacyController _privacy =
      (widget.savingsPrivacy ?? SavingsPrivacyController())..init();

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
    _appearance.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SavingsPrivacy(
      controller: _privacy,
      child: AppearanceScope(
        controller: _appearance,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: _appearance,
          builder: (context, mode, _) => _app(mode),
        ),
      ),
    );
  }

  Widget _app(ThemeMode mode) {
    return MaterialApp(
      title: 'PennyWise',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
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
        categoryBudgetsForUser: widget.categoryBudgetsForUser ??
            (uid) => FirestoreCategoryBudgetRepository(uid: uid),
        categoriesForUser: widget.categoriesForUser ??
            (uid) => FirestoreCategoryRepository(uid: uid),
        avatarForUser: widget.avatarForUser ??
            (uid) => FirestoreAvatarRepository(uid: uid),
        photoPicker: widget.photoPicker ?? AndroidPhotoPicker(),
        categoryRulesForUser: widget.categoryRulesForUser ??
            (uid) => FirestoreCategoryRuleRepository(uid: uid),
        accountsForUser: widget.accountsForUser ??
            (uid) => FirestoreAccountRepository(uid: uid),
        smsGateway: widget.smsGateway ?? AndroidSmsGateway(),
        smsSettingsForUser: widget.smsSettingsForUser ??
            (uid) => SharedPrefsSmsSettings(uid: uid),
      ),
    );
  }
}
