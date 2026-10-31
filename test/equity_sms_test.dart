import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/account_repository.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/screens/settings_screen.dart';
import 'package:pennywise/sms/sms_gateway.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_transaction.dart';

import 'fake_accounts.dart';
import 'fake_sms.dart';

// Equity Bank SMS: only the user's own account is read; Equity's receipts
// for M-Pesa payments are ignored (M-Pesa already records them). Wording is
// copied from real Equity messages; names, numbers and codes are made up.

final when = DateTime(2026, 10, 31, 10, 53);

const card =
    'CONFIRMED. USD 20.00, Auth for card 4111..1111 at ANTHROPIC* CLAUDE SUB '
    'on 2026-10-31 10:53:00 Ref:123456789012.For any queries, contact '
    '0763000000. #KulipaNiEquityCard';
const cardKes =
    'CONFIRMED. KES 1,250.00, Auth for card 4111..1111 at JAVA HOUSE on '
    '2026-10-20 13:05:00 Ref:223456789012.For any queries, contact '
    '0763000000. #KulipaNiEquityCard';
const cardFailed =
    'Your card no. 4111..1111 payment to ANTHROPIC* CLAUDE SUB of USD 20.00 '
    'has failed due to insufficient funds. Dial *247#, use Equitel or Equity '
    'Mobile App to get an instant loan in your account and proceed to pay';
const fee =
    'Txn: A fee has been deducted from your account Acct:0123XXXXXX4567 '
    'Amt:KES 300.00 Desc: Annual Debit Card Fee Date:11-09-2026 17:15:02 Use '
    'Equity USSD on Any Telco.';
const drawn =
    'Dear PAT KES 5000.00 has been drawn from your account 0123......4567  '
    'Ref:12345678 on 14-SEP-2026 09:50:01 AM. For any queries, contact '
    '0763000000';
const sentOut =
    '1500.00 KES has been successfully sent to JANE WANJIKU 0********123. Ref. '
    'AB12CD34EF567 on 28 Oct 2025 at 19:18 EAT. Transaction charge 10.00 KES, '
    'SMS alert charge 2.00 KES';
const receivedIn =
    'You have received 2000.00 KES from JOHN OTIENO 0********456 to your '
    'Equity account 0********789. Ref. CD34EF56AB789 on 30 Oct 2025 at 17:23 '
    'EAT';
const viaMpesa =
    'Confirmed. KES. 2,000.00 from PAT OWNER received via M-Pesa Ref. '
    'UJV0000009 on 31-10-2026 at 10:46. Thank you.';
const viaMpesaWithPhone =
    'Confirmed. KES. 700.00 from JOHN OTIENO Phone No. 254700000000 received '
    'via M-Pesa Ref. UCC0000001 on 12-03-2026 at 15:35. Thank you.';

// Equity's receipts for M-Pesa payments: ignored.
const receipts = [
  'Your transaction of Kshs. 500.00  has been credited to  0123456789  JOHN '
      'OTIENO. Ref.  EQA123456. MPESA Ref.  UJ00000001 on  14/09/2026 at '
      '10:00:00.',
  'JOHN OTIENO has sent KShs. 300.00 to your MPESA. The MPESA receipt number '
      'is  UJ00000002 and transaction reference is  TTS123.',
  'Dear PAT, Your transaction of KES. 400.00 has successfully been deposited '
      'to Equity Account in favor of JANE WANJIKU Ref. Number UJ00000003 on '
      '30-09-2026 at 10:00. Thank you.',
  'Confirmed. Payment of KES. 250.00 to MAMA PIMA Till No. 123456 has been '
      'received. Ref. UJ00000004 on 14-08-2026 at 13:00. Thank you.',
  'Confirmed, Bill payment to KPLC of KES. 1000.00 for account 123456  and '
      'Ref. UJ00000005 on 27-09-2026 at 09:00.Thank you.',
  'Dear Member, our branches will be closed on Fri 1 May & resume Sat 2 May.',
];

SmsTransaction? parse(String body, {String sender = 'Equity Bank'}) =>
    SmsParser.parse(sender: sender, body: body, date: when);

final equityAccount = MoneyAccount(
  id: 'equity',
  name: 'Equity',
  kind: AccountKind.bank,
  provider: AccountProvider.equity,
);

Future<AccountStore> accountsWith({bool equity = true}) async {
  final s = AccountStore(
    FakeAccountRepository([
      ...MoneyAccount.starterSet(),
      if (equity) equityAccount,
    ]),
  );
  await Future<void>.delayed(Duration.zero);
  return s;
}

void main() {
  group('reading', () {
    test('every spelling of the sender is Equity', () {
      for (final s in ['Equity Bank', 'EQUITY BANK', 'EQUITYBANK']) {
        expect(SmsParser.sourceFor(s), TransactionSource.equity);
      }
    });

    test('a card payment: amount, currency and merchant', () {
      final usd = parse(card)!;
      expect([usd.kind, usd.currency, usd.amount], [
        SmsTransactionKind.payment,
        'USD',
        20.0,
      ]);
      expect(usd.counterparty, 'Anthropic Claude Sub');
      expect(usd.reference, 'CARD123456789012');
      final kes = parse(cardKes)!;
      expect([kes.currency, kes.amount], ['KES', 1250.0]);
      expect(kes.type, TransactionType.expense);
    });

    test('a failed card payment is not a transaction', () {
      expect(parse(cardFailed), isNull);
    });

    test('the bank\'s own fee is spending', () {
      final f = parse(fee)!;
      expect([f.kind, f.amount, f.type], [
        SmsTransactionKind.charge,
        300.0,
        TransactionType.expense,
      ]);
      expect(f.reference, 'FEE11092026171502');
    });

    test('money drawn from the account is a move to Cash', () {
      final d = parse(drawn)!;
      expect([d.kind, d.amount, d.reference], [
        SmsTransactionKind.withdrawal,
        5000.0,
        '12345678',
      ]);
      expect(d.type, TransactionType.transfer);
    });

    test('sent from Equity, with both charges as its fee', () {
      final s = parse(sentOut)!;
      expect([s.kind, s.amount, s.fee, s.reference], [
        SmsTransactionKind.sent,
        1500.0,
        12.0,
        'AB12CD34EF567',
      ]);
      expect(s.counterparty, 'Jane Wanjiku');
    });

    test('received into the Equity account', () {
      final r = parse(receivedIn)!;
      expect([r.kind, r.amount, r.type], [
        SmsTransactionKind.received,
        2000.0,
        TransactionType.income,
      ]);
      expect(r.viaMobileMoney, isNull);
    });

    test('paid in from M-Pesa keeps the M-Pesa code', () {
      final v = parse(viaMpesa)!;
      expect([v.kind, v.amount, v.viaMobileMoney], [
        SmsTransactionKind.received,
        2000.0,
        'UJV0000009',
      ]);
      final p = parse(viaMpesaWithPhone)!;
      expect(p.counterparty, 'John Otieno');
      expect(p.amount, 700.0);
    });

    test('Equity\'s receipts for M-Pesa payments and adverts are ignored', () {
      for (final body in receipts) {
        expect(parse(body), isNull, reason: body);
      }
    });
  });

  group('recording', () {
    test('on the Equity account; a fee is "fees"; drawn money goes to Cash',
        () async {
      final acc = await accountsWith();
      TransactionModel tx(String body) =>
          SmsImportService.toTransaction(parse(body)!, accounts: acc);
      final paid = tx(cardKes);
      expect([paid.accountId, paid.account, paid.source], [
        'equity',
        Account.bank,
        TransactionSource.equity,
      ]);
      expect(tx(fee).categoryId, 'fees');
      final out = tx(drawn);
      expect([out.accountId, out.toAccountId, out.toAccount], [
        'equity',
        'cash',
        Account.cash,
      ]);
      expect(tx(sentOut).fee, 12.0);
      expect(tx(receivedIn).description, 'From John Otieno');
    });

    test('without an Equity account nothing is placed on an account',
        () async {
      final acc = await accountsWith(equity: false);
      final t = SmsImportService.toTransaction(parse(cardKes)!, accounts: acc);
      expect(t.accountId, isNull);
    });
  });

  group('importing', () {
    late FakeSmsSettings settings;
    late List<String> saved;
    late Set<String> existing;

    Future<SmsImportService> service({bool equity = true}) async {
      settings = FakeSmsSettings()..enabled = true;
      saved = [];
      final acc = await accountsWith(equity: equity);
      final s = SmsImportService(
        gateway: FakeSmsGateway(permissionGranted: true),
        settings: settings,
        save: (t, key) async {
          saved.add(key);
          return true;
        },
        accounts: () => acc,
        isSaved: existing.contains,
      );
      await s.start();
      return s;
    }

    RawSms sms(String body) =>
        RawSms(sender: 'Equity Bank', body: body, date: when);

    setUp(() => existing = {});

    test('a KES card payment is saved once', () async {
      final s = await service();
      expect(await s.handle(sms(cardKes)), isNotNull);
      expect(saved, ['equity_CARD223456789012']);
      expect(await s.handle(sms(cardKes)), isNull); // already handled
      expect(saved, hasLength(1));
    });

    test('a USD card payment waits for the user; nothing is guessed',
        () async {
      final s = await service();
      expect(await s.handle(sms(card)), isNull);
      expect(saved, isEmpty);
      expect(s.skipped[SkipReason.foreignCurrency], 1);
    });

    test('no Equity account yet: held, and can be added later', () async {
      final s = await service(equity: false);
      expect(await s.handle(sms(cardKes)), isNull);
      expect(saved, isEmpty);
      expect(s.skipped[SkipReason.bankNoAccount], 1);
      expect(settings.handled, isEmpty);
    });

    test('a top-up from the user\'s own M-Pesa is not counted twice',
        () async {
      existing = {'mpesa_UJV0000009'};
      final s = await service();
      expect(await s.handle(sms(viaMpesa)), isNull);
      expect(saved, isEmpty);
      expect(s.skipped[SkipReason.bankTopUp], 1);
    });

    test('money paid in by someone else via M-Pesa is income on Equity',
        () async {
      final s = await service();
      final t = await s.handle(sms(viaMpesaWithPhone));
      expect(saved, ['equity_UCC0000001']);
      expect([t!.type, t.accountId], [TransactionType.income, 'equity']);
    });
  });

  test('Settings explains each held Equity message', () {
    final notes = equityHeldTexts(foreignCurrency: 2, noAccount: 3, topUps: 1);
    expect(notes, hasLength(3));
    expect(notes[0], startsWith('3 Equity messages were read but not added'));
    expect(notes[1], contains("waiting for that day's exchange rate"));
    expect(notes[2], startsWith('1 top-up from your M-Pesa into Equity'));
    expect(equityHeldTexts(foreignCurrency: 0, noAccount: 0, topUps: 0),
        isEmpty);
  });
}
