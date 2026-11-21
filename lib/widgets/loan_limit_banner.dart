import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../privacy/savings_privacy.dart';
import '../accounts/account_balances.dart';
import '../accounts/loan_limit.dart';
import '../models/ledger.dart';
import '../theme/app_theme.dart';

/// A reminder on Home when a loan (e.g. one SIM's Fuliza) has used 80% or
/// more of the limit the user entered, saying what is still available.
///
/// "Dismiss" hides it until more is borrowed on that account: the amount
/// owed when dismissed is kept on this phone (per user and account).
class LoanLimitBanner extends StatefulWidget {
  const LoanLimitBanner({
    super.key,
    required this.balances,
    this.scope = '',
    this.onTap,
  });

  final List<AccountBalance> balances;

  /// Keeps one user's dismissals apart from another's on the same phone
  /// (their uid).
  final String scope;

  /// Opens the accounts (e.g. to change a limit).
  final VoidCallback? onTap;

  static String prefsKey(String scope, String accountId) =>
      'loanLimitDismissed.$scope.$accountId';

  @override
  State<LoanLimitBanner> createState() => _LoanLimitBannerState();
}

class _LoanLimitBannerState extends State<LoanLimitBanner> {
  /// Account id → amount owed (cents) when the reminder was dismissed.
  Map<String, int> _dismissed = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final out = <String, int>{};
      final prefix = LoanLimitBanner.prefsKey(widget.scope, '');
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(prefix)) continue;
        final v = prefs.get(key);
        if (v is int) out[key.substring(prefix.length)] = v;
      }
      if (mounted) {
        setState(() {
          _dismissed = out;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _dismiss(List<LoanLimit> shown) async {
    final next = {..._dismissed};
    for (final l in shown) {
      next[l.account.id] = Ledger.toCents(l.owed);
    }
    setState(() => _dismissed = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final l in shown) {
        await prefs.setInt(
          LoanLimitBanner.prefsKey(widget.scope, l.account.id),
          Ledger.toCents(l.owed),
        );
      }
    } catch (_) {
      // Not saved: the reminder comes back next time the app opens.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final shown = [
      for (final l in LoanLimit.all(widget.balances))
        if (l.level != LoanLimitLevel.ok &&
            Ledger.toCents(l.owed) > (_dismissed[l.account.id] ?? -1))
          l,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    final reached = shown.any((l) => l.level == LoanLimitLevel.reached);
    return Card(
      key: const Key('loanLimitBanner'),
      color: context.colors.warning.withValues(alpha: 0.10),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          Icons.credit_score_rounded,
          color: context.colors.warning,
        ),
        title: Text(reached ? 'Loan limit reached' : 'Loan limit almost used'),
        subtitle: Text(
          [
            for (final l in shown)
              '${l.account.name}: ${SavingsPrivacy.money(context, l.available)} left of '
                  '${SavingsPrivacy.money(context, l.limit)}',
          ].join('\n'),
        ),
        isThreeLine: shown.length > 1,
        onTap: widget.onTap,
        trailing: IconButton(
          tooltip: 'Dismiss until you borrow again',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => _dismiss(shown),
        ),
      ),
    );
  }
}
