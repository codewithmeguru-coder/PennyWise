import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/transaction_category.dart';
import 'package:pennywise/models/transaction_model.dart';

final oct = DateTime(2026, 10, 10, 12);

TransactionModel tx(
  TransactionType type,
  double amount, {
  String? category,
  Account? account = Account.mpesa,
  Account? toAccount,
  double? fee,
  double? interest,
  TransactionSource source = TransactionSource.manual,
  DateTime? date,
}) =>
    TransactionModel(
      description: 'x',
      amount: amount,
      type: type,
      categoryId: category ??
          (DefaultCategories.hasFixedCategory(type)
              ? DefaultCategories.fixedCategoryFor(type)
              : 'food'),
      date: date ?? oct,
      account: account,
      toAccount: toAccount,
      fee: fee,
      interest: interest,
      source: source,
    );

void main() {
  group('transfers', () {
    test('a cash withdrawal moves money, only its fee is spending', () {
      // KSh 1,000 withdrawn at an agent, M-Pesa charges KSh 29.
      final ledger = Ledger.of([
        tx(TransactionType.transfer, 1000,
            account: Account.mpesa, toAccount: Account.cash, fee: 29),
      ]);

      expect(ledger.income, 0);
      expect(ledger.spending, 29);
      expect(ledger.fees, 29);
      expect(ledger.balanceOf(Account.mpesa), -1029);
      expect(ledger.balanceOf(Account.cash), 1000);
      expect(ledger.available, -29); // only the fee left your money
    });

    test('a cash deposit is not income', () {
      final ledger = Ledger.of([
        tx(TransactionType.transfer, 5000,
            account: Account.cash, toAccount: Account.mpesa),
      ]);

      expect(ledger.income, 0);
      expect(ledger.spending, 0);
      expect(ledger.balanceOf(Account.cash), -5000);
      expect(ledger.balanceOf(Account.mpesa), 5000);
      expect(ledger.available, 0);
    });

    test('bank to M-Pesa does not inflate income or spending', () {
      final ledger = Ledger.of([
        tx(TransactionType.income, 65000,
            category: 'salary', account: Account.bank),
        tx(TransactionType.transfer, 20000,
            account: Account.bank, toAccount: Account.mpesa),
      ]);

      expect(ledger.income, 65000);
      expect(ledger.spending, 0);
      expect(ledger.available, 65000);
    });
  });

  group('savings', () {
    test('a contribution is not spending and stays yours', () {
      final ledger = Ledger.of([
        tx(TransactionType.income, 10000, category: 'salary'),
        tx(TransactionType.savingsContribution, 5000),
      ]);

      expect(ledger.spending, 0);
      expect(ledger.net, 10000);
      expect(ledger.available, 5000);
      expect(ledger.savingsBalance, 5000);
      expect(ledger.netSaved, 5000);
    });

    test('a withdrawal is not income', () {
      final ledger = Ledger.of([
        tx(TransactionType.savingsContribution, 5000),
        tx(TransactionType.savingsWithdrawal, 1500),
      ]);

      expect(ledger.income, 0);
      expect(ledger.savingsBalance, 3500);
      expect(ledger.available, -3500);
      expect(ledger.netSaved, 3500);
    });

    test('a fee on a contribution is spending', () {
      final ledger =
          Ledger.of([tx(TransactionType.savingsContribution, 1000, fee: 13)]);

      expect(ledger.spending, 13);
      expect(ledger.savingsBalance, 1000);
      expect(ledger.available, -1013);
    });
  });

  group('refunds', () {
    test('reduce spending in their category instead of adding income', () {
      final ledger = Ledger.of([
        tx(TransactionType.expense, 1200, category: 'food'),
        tx(TransactionType.refund, 450, category: 'food'),
      ]);

      expect(ledger.income, 0);
      expect(ledger.spending, 750);
      expect(ledger.categoryCents['food'], 75000);
      expect(ledger.available, -750);
    });

    test('a refund larger than the month\'s spending in its category is '
        'left out of the breakdown', () {
      final ledger = Ledger.of([
        tx(TransactionType.expense, 300, category: 'transport'),
        tx(TransactionType.refund, 500, category: 'shopping'),
      ]);

      expect(ledger.spending, -200);
      expect(ledger.spendingByCategory.map((e) => e.key), ['transport']);
    });
  });

  group('M-Pesa fees', () {
    test('count as spending under "fees", on top of the amount', () {
      final ledger = Ledger.of([
        tx(TransactionType.expense, 1500, category: 'bills', fee: 22),
      ]);

      expect(ledger.spending, 1522);
      expect(ledger.categoryCents['bills'], 150000);
      expect(ledger.categoryCents['fees'], 2200);
      expect(ledger.balanceOf(Account.mpesa), -1522);
    });
  });

  group('debt repayments', () {
    test('only the interest is spending; principal still leaves the account',
        () {
      // Fuliza: KSh 1,000 borrowed earlier, KSh 1,030 repaid.
      final ledger = Ledger.of([
        tx(TransactionType.debtRepayment, 1030, interest: 30),
      ]);

      expect(ledger.spending, 30);
      expect(ledger.debtPrincipal, 1000);
      expect(ledger.categoryCents['debt_repayment'], 3000);
      expect(ledger.available, -1030);
    });

    test('unknown interest means none is counted as spending', () {
      final ledger = Ledger.of([tx(TransactionType.debtRepayment, 2000)]);

      expect(ledger.spending, 0);
      expect(ledger.debtPrincipal, 2000);
      expect(ledger.available, -2000);
    });

    test('interest is capped at the amount repaid', () {
      final ledger =
          Ledger.of([tx(TransactionType.debtRepayment, 100, interest: 150)]);

      expect(ledger.spending, 100);
      expect(ledger.debtPrincipal, 0);
    });
  });

  test('a realistic month: every rule together, accounts add up', () {
    final ledger = Ledger.of([
      tx(TransactionType.income, 65000,
          category: 'salary', account: Account.bank),
      tx(TransactionType.transfer, 20000,
          account: Account.bank, toAccount: Account.mpesa, fee: 50),
      tx(TransactionType.expense, 2450, category: 'shopping'), // Naivas till
      tx(TransactionType.transfer, 1000,
          account: Account.mpesa, toAccount: Account.cash, fee: 29),
      tx(TransactionType.expense, 200,
          category: 'transport', account: Account.cash), // matatu
      tx(TransactionType.savingsContribution, 5000), // to Ziidi
      tx(TransactionType.savingsWithdrawal, 1500), // from Ziidi
      tx(TransactionType.expense, 1200, category: 'food'),
      tx(TransactionType.refund, 450, category: 'food'),
      tx(TransactionType.debtRepayment, 1030, interest: 30), // Fuliza
      tx(TransactionType.expense, 1500, category: 'bills', fee: 22), // KPLC
    ]);

    expect(ledger.income, 65000);
    expect(ledger.fees, 101);
    expect(ledger.refunds, 450);
    // 5,350 expenses + 101 fees + 30 interest − 450 refund
    expect(ledger.spending, 5031);
    expect(ledger.net, 59969);
    expect(ledger.savingsBalance, 3500);
    expect(ledger.debtPrincipal, 1000);
    expect(ledger.balanceOf(Account.bank), 44950);
    expect(ledger.balanceOf(Account.mpesa), 9719);
    expect(ledger.balanceOf(Account.cash), 800);
    // Available = income − spending − principal − net saved, and it equals
    // the sum of the non-savings accounts.
    expect(ledger.available, 65000 - 5031 - 1000 - 3500);
    expect(ledger.available, 44950 + 9719 + 800);
  });

  group('older transactions (saved before Phase 2)', () {
    test('give exactly the old totals', () {
      final ledger = Ledger.of([
        tx(TransactionType.income, 65000, category: 'salary', account: null),
        tx(TransactionType.expense, 850, account: null),
      ]);

      expect(ledger.income, 65000);
      expect(ledger.spending, 850);
      expect(ledger.available, 64150); // the old "balance"
      expect(ledger.balanceOf(null), 64150);
    });

    test('an SMS-detected one counts against M-Pesa', () {
      final ledger = Ledger.of([
        tx(TransactionType.expense, 300,
            account: null, source: TransactionSource.mpesa),
      ]);

      expect(ledger.balanceOf(Account.mpesa), -300);
      expect(ledger.balanceOf(null), 0);
    });
  });

  test('sums in whole cents', () {
    final ledger = Ledger.of([
      tx(TransactionType.expense, 0.1),
      tx(TransactionType.expense, 0.2),
    ]);

    expect(ledger.spending, 0.3);
  });

  test('MonthlySummary and budgets use spending, not raw outflows', () {
    final summary = MonthlySummary.calculate(
      month: DateTime(2026, 10),
      budget: 2000,
      transactions: [
        tx(TransactionType.expense, 1200, category: 'food', fee: 20),
        tx(TransactionType.savingsContribution, 5000),
        tx(TransactionType.transfer, 1000, toAccount: Account.cash),
        tx(TransactionType.refund, 200, category: 'food'),
        // September: excluded.
        tx(TransactionType.expense, 999, date: DateTime(2026, 9, 30)),
      ],
    );

    expect(summary.expenses, 1020);
    expect(summary.netSaved, 5000);
    expect(summary.remaining, 980);
    expect(summary.transactionCount, 4);
    expect(summary.byCategory.map((c) => c.categoryId), ['food', 'fees']);
    expect(summary.byCategory.first.amount, 1000);
  });

  group('stored type names', () {
    test('round-trip, and unknown values are rejected', () {
      for (final type in TransactionType.values) {
        expect(TransactionType.fromWire(type.wireName), type);
      }
      expect(TransactionType.fromWire('income'), TransactionType.income);
      expect(TransactionType.fromWire('expense'), TransactionType.expense);
      expect(TransactionType.fromWire('gift'), isNull);
      expect(Account.fromWire('airtel_money'), Account.airtelMoney);
      expect(Account.fromWire(null), isNull);
    });

    test('an unknown category shows as "Other", not as Food', () {
      expect(DefaultCategories.byId('subscriptions').name, 'Other');
    });
  });
}
