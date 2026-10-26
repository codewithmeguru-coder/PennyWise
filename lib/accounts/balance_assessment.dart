import '../models/duplicate_finder.dart';
import '../models/transaction_model.dart';
import 'account_balances.dart';
import 'money_account.dart';

/// One thing that makes a balance less reliable, with what to do about it.
class BalanceFinding {
  const BalanceFinding(this.title, this.detail, this.action, {this.count = 1});

  final String title;
  final String detail;

  /// The proposed next step. Nothing is changed by the assessment itself.
  final String action;
  final int count;
}

/// A read-only check of how far the user's balances can be trusted, for
/// any user and any set of accounts. It reads accounts and transactions
/// only; every repair is a separate, explicit step.
class BalanceAssessment {
  BalanceAssessment._();

  static final _toZiidi = RegExp(r'sent\s+to\s+ziidi\s+on', caseSensitive: false);
  static final _fromZiidi =
      RegExp(r'received\s+ksh.{0,20}from\s+ziidi\s+on', caseSensitive: false);

  static List<BalanceFinding> of(
    List<MoneyAccount> accounts,
    List<TransactionModel> transactions,
  ) {
    final out = <BalanceFinding>[];
    final active = accounts.where((a) => a.active).toList();
    final balances = AccountBalance.forAll(active, transactions);

    // Accounts without a verified starting point.
    final unanchored = [
      for (final b in balances)
        if (!b.hasOpening) b.account.name,
    ];
    if (unanchored.isNotEmpty) {
      out.add(BalanceFinding(
        'No starting balance',
        unanchored.join(', '),
        'Set a starting balance for each (or use its latest SMS balance). '
            'Until then these are estimates.',
        count: unanchored.length,
      ));
    }

    // History that starts while the account was already in use: the first
    // recorded SMS states a balance its own transaction doesn't explain.
    for (final b in balances) {
      final a = b.account;
      if (a.kind != AccountKind.mobileMoney || b.hasOpening) continue;
      final own = [
        for (final t in transactions)
          if (t.isDetected && AccountBalance.belongs(a, t)) t,
      ]..sort((x, y) => x.date.compareTo(y.date));
      for (final t in own) {
        final stated = AccountBalance.statedBalance(t.smsText);
        if (stated == null) continue;
        final before = AccountBalance.of(
                a.copyWith(openingBalance: 0, openingDate: t.date),
                [t]).computed;
        final earlier = stated - before;
        if (earlier.abs() > 1) {
          out.add(BalanceFinding(
            '${a.name}: history starts part-way',
            'The first recorded message (${t.date.day}/${t.date.month}/'
                '${t.date.year}) shows money that was there before PennyWise '
                'started recording.',
            'Set a starting balance; older history can\'t be summed into a '
                'balance.',
          ));
        }
        break;
      }
    }

    // SMS without a SIM or account.
    final noSim = transactions
        .where((t) => t.isDetected && t.simSlot == null && t.accountId == null)
        .length;
    if (noSim > 0) {
      out.add(BalanceFinding(
        'Messages without a SIM',
        '$noSim imported messages don\'t say which SIM they came from, so '
            'they aren\'t in any SIM\'s balance.',
        'Review a SIM assignment from evidence (a later step, with preview '
            'and Undo). Nothing is guessed.',
        count: noSim,
      ));
    }

    // Savings moves stored as spending or income.
    final ziidi = transactions
        .where((t) =>
            (t.type == TransactionType.expense &&
                _toZiidi.hasMatch(t.smsText ?? '')) ||
            (t.type == TransactionType.income &&
                _fromZiidi.hasMatch(t.smsText ?? '')))
        .toList();
    if (ziidi.isNotEmpty) {
      out.add(BalanceFinding(
        'Savings counted as spending or income',
        '${ziidi.length} Ziidi deposits or withdrawals are stored as an '
            'expense or income.',
        'Reclassify them as savings (a later step, with preview and Undo).',
        count: ziidi.length,
      ));
    }

    // Manual entries that may repeat an SMS import.
    final manual = transactions.where((t) => !t.isDetected).toList();
    var dups = 0;
    for (final m in manual) {
      final others = [for (final t in transactions) if (t.id != m.id) t];
      if (DuplicateFinder.smsMatchesFor(m, others).isNotEmpty) dups++;
    }
    if (dups > 0) {
      out.add(BalanceFinding(
        'Possible duplicates',
        '$dups manual entries look like transactions already imported from '
            'SMS.',
        'Open each and delete it if it is the same payment.',
        count: dups,
      ));
    }

    // Loans that show credit: a starting amount with the wrong sign, or
    // repayments without the borrowing they repaid.
    for (final b in balances) {
      if (b.account.kind != AccountKind.loan || b.owed >= 0) continue;
      out.add(BalanceFinding(
        '${b.account.name}: shows credit',
        'It shows more repaid than borrowed '
            '(${(-b.owed).toStringAsFixed(2)}).',
        'Enter the amount currently owed as its starting balance.',
      ));
    }

    // Balances the latest SMS disagrees with.
    for (final b in balances) {
      if (!b.differs) continue;
      out.add(BalanceFinding(
        '${b.account.name}: differs from SMS',
        'The SMS says ${b.reported!.toStringAsFixed(2)}, PennyWise has '
            '${b.calculatedAtReport!.toStringAsFixed(2)} for the same time.',
        'Review it: a message may be missing, duplicated or on the other '
            'SIM. You can then use the SMS balance as the new starting point.',
      ));
    }
    return out;
  }
}
