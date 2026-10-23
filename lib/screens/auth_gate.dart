import 'package:flutter/material.dart';

import '../categorization/category_rule_repository.dart';
import '../data/budget_repository.dart';
import '../data/transaction_repository.dart';
import '../data/transaction_store.dart';
import '../services/auth_service.dart';
import '../sms/sms_gateway.dart';
import '../sms/sms_import_service.dart';
import '../sms/sms_settings.dart';
import '../theme/app_theme.dart';
import 'auth/login_screen.dart';
import 'home_shell.dart';

/// Shows the login flow or the main app depending on the auth state.
///
/// Signing in, registering and signing out never navigate by hand; they
/// change the auth state and this widget rebuilds.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authService,
    required this.repositoryForUser,
    required this.budgetRepositoryForUser,
    required this.categoryRulesForUser,
    required this.smsGateway,
    required this.smsSettingsForUser,
  });

  final AuthService authService;
  final TransactionRepository Function(String uid) repositoryForUser;
  final BudgetRepository Function(String uid) budgetRepositoryForUser;
  final CategoryRuleRepository Function(String uid) categoryRulesForUser;
  final SmsGateway smsGateway;
  final SmsSettings Function(String uid) smsSettingsForUser;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // Subscribed once. Passing a new stream on every build would make the
  // StreamBuilder resubscribe, flash the loading screen, and throw away the
  // signed-in user's state.
  late final Stream<AppUser?> _userChanges = widget.authService.userChanges;

  @override
  Widget build(BuildContext context) {
    final authService = widget.authService;
    return StreamBuilder<AppUser?>(
      stream: _userChanges,
      builder: (context, snapshot) {
        // Firebase restores a saved session asynchronously on start-up.
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoadingScreen();
        }

        final user = snapshot.data;
        if (user == null) return LoginScreen(authService: authService);

        return _SignedInScope(
          // A different user gets a fresh store (and fresh tab state).
          key: ValueKey(user.uid),
          user: user,
          repository: widget.repositoryForUser(user.uid),
          budgetRepository: widget.budgetRepositoryForUser(user.uid),
          categoryRules: widget.categoryRulesForUser(user.uid),
          smsGateway: widget.smsGateway,
          smsSettings: widget.smsSettingsForUser(user.uid),
          onSignOut: authService.signOut,
        );
      },
    );
  }
}

/// Owns the signed-in user's [TransactionStore] and [SmsImportService] for
/// as long as they stay signed in, and closes both on sign-out (so detected
/// transactions always go to the account that is signed in right now).
class _SignedInScope extends StatefulWidget {
  const _SignedInScope({
    super.key,
    required this.user,
    required this.repository,
    required this.budgetRepository,
    required this.categoryRules,
    required this.smsGateway,
    required this.smsSettings,
    required this.onSignOut,
  });

  final AppUser user;
  final TransactionRepository repository;
  final BudgetRepository budgetRepository;
  final CategoryRuleRepository categoryRules;
  final SmsGateway smsGateway;
  final SmsSettings smsSettings;
  final Future<void> Function() onSignOut;

  @override
  State<_SignedInScope> createState() => _SignedInScopeState();
}

class _SignedInScopeState extends State<_SignedInScope>
    with WidgetsBindingObserver {
  late final TransactionStore _store = TransactionStore(widget.repository);
  late final CategoryRuleStore _rules =
      CategoryRuleStore(widget.categoryRules);
  late final SmsImportService _sms = SmsImportService(
    gateway: widget.smsGateway,
    settings: widget.smsSettings,
    // Detected transactions go through the same store and repository as
    // manual ones, into users/{uid}/transactions.
    save: (t, key) => _store.addDetected(t, dedupeKey: key),
    // The user's learned categories are used first for new imports.
    rules: () => _rules.rules,
  );
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sms.start(); // does nothing unless the user turned detection on
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Catch up on SMS that arrived while the app was in the background.
    if (state == AppLifecycleState.resumed) _sms.onAppResumed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Kept for dispose(), where looking it up via context isn't allowed.
    _navigator = Navigator.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sms.dispose();
    _rules.dispose();
    _store.dispose();
    // The session ended (sign-out, or the account was disabled elsewhere).
    // Close any form or dialog still open on top of the home screen so it
    // doesn't sit over the login screen with the old user's data.
    final navigator = _navigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator != null && navigator.mounted) {
        navigator.popUntil((route) => route.isFirst);
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HomeShell(
      store: _store,
      budgetRepository: widget.budgetRepository,
      categoryRules: _rules,
      smsService: _sms,
      user: widget.user,
      onSignOut: widget.onSignOut,
    );
  }
}

class _AuthLoadingScreen extends StatelessWidget {
  const _AuthLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );
  }
}
