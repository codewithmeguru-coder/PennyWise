import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_categorizer.dart';
import 'package:pennywise/sms/sms_import_service.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_transaction.dart';

/// Sample messages in the providers' formats. Codes, names and numbers are
/// made up; no real transactions are needed.
final smsDate = DateTime(2026, 10, 6, 13, 20);

SmsTransaction? mpesa(String body) =>
    SmsParser.parse(sender: 'MPESA', body: body, date: smsDate);

SmsTransaction? airtel(String body) =>
    SmsParser.parse(sender: 'AirtelMoney', body: body, date: smsDate);

void main() {
  group('M-Pesa', () {
    test('Buy Goods payment (the example from the brief)', () {
      final t = mpesa('TJ6AB1CD2E Confirmed. Ksh500.00 paid to NAIVAS. on '
          '6/10/26 at 1:20 PM.New M-PESA balance is Ksh2,700.00. Transaction '
          'cost, Ksh0.00. Amount you can transact within the day is '
          '499,500.00.')!;

      expect(t.amount, 500);
      expect(t.type, TransactionType.expense);
      expect(t.kind, SmsTransactionKind.payment);
      expect(t.counterparty, 'Naivas');
      expect(t.source, TransactionSource.mpesa);
      expect(t.reference, 'TJ6AB1CD2E');
      expect(t.date, smsDate); // the SMS timestamp
      expect(t.fee, 0);
      expect(t.dedupeKey, 'mpesa_TJ6AB1CD2E');
      expect(SmsCategorizer.categorize(t), 'shopping');
    });

    test('money sent to a person, with phone number and fee', () {
      final t = mpesa('TJ6AB1CD2F Confirmed. Ksh1,500.00 sent to JOHN DOE '
          '0712345678 on 6/10/26 at 2:15 PM. New M-PESA balance is '
          'Ksh3,200.00. Transaction cost, Ksh23.00.')!;

      expect(t.amount, 1500);
      expect(t.kind, SmsTransactionKind.sent);
      expect(t.counterparty, 'John Doe');
      expect(t.phone, '0712345678');
      expect(t.fee, 23);
      expect(SmsCategorizer.categorize(t), 'uncategorized');
    });

    test('Paybill payment with account number', () {
      final t = mpesa('TJ6AB1CD2G Confirmed. Ksh2,000.00 sent to KPLC PREPAID '
          'for account 54321098765 on 6/10/26 at 9:01 AM New M-PESA balance '
          'is Ksh1,200.00. Transaction cost, Ksh0.00.')!;

      expect(t.kind, SmsTransactionKind.payment);
      expect(t.counterparty, 'Kplc Prepaid');
      expect(t.account, '54321098765');
      expect(SmsCategorizer.categorize(t), 'bills');
    });

    test('money received from a person is income', () {
      final t = mpesa('TJ6AB1CD2H Confirmed.You have received Ksh2,500.00 '
          'from JANE WANJIKU 0722000111 on 6/10/26 at 4:30 PM  New M-PESA '
          'balance is Ksh5,700.00.')!;

      expect(t.amount, 2500);
      expect(t.type, TransactionType.income);
      expect(t.counterparty, 'Jane Wanjiku');
      expect(SmsCategorizer.categorize(t), 'money_received');
    });

    test('salary from an employer is categorised as salary', () {
      final t = mpesa('TJ6AB1CD2I Confirmed.You have received Ksh45,000.00 '
          'from ACME LTD SALARY on 30/9/26 at 8:00 AM New M-PESA balance is '
          'Ksh50,700.00.')!;

      expect(t.type, TransactionType.income);
      expect(SmsCategorizer.categorize(t), 'salary');
    });

    test('withdrawal at an agent', () {
      final t = mpesa('TJ6AB1CD2J Confirmed.on 6/10/26 at 10:00 AMWithdraw '
          'Ksh3,000.00 from 123456 - MAMA MBOGA AGENCIES New M-PESA balance '
          'is Ksh700.00. Transaction cost, Ksh53.00.')!;

      expect(t.kind, SmsTransactionKind.withdrawal);
      expect(t.amount, 3000);
      // Moving money from M-Pesa into cash, not spending it.
      expect(t.type, TransactionType.transfer);
      expect(t.counterparty, 'Mama Mboga Agencies');
      // A transfer since Phase 2, so its category is the fixed "transfer".
      expect(SmsCategorizer.categorize(t), 'transfer');

      final model = SmsImportService.toTransaction(t);
      expect(model.description, 'Cash withdrawal');
      expect(model.categoryId, 'transfer');
      expect(model.account, Account.mpesa);
      expect(model.toAccount, Account.cash);
      expect(model.fee, 53);
      expect(model.note, 'Agent: Mama Mboga Agencies');
    });

    test('cash deposit at an agent', () {
      final t = mpesa('TJ6AB1CD2K Confirmed. On 6/10/26 at 11:00 AM Give '
          'Ksh5,000.00 cash to CITY AGENTS New M-PESA balance is '
          'Ksh5,700.00.')!;

      expect(t.kind, SmsTransactionKind.deposit);
      // Moving cash into M-Pesa, not income.
      expect(t.type, TransactionType.transfer);
      expect(SmsCategorizer.categorize(t), 'transfer');

      final model = SmsImportService.toTransaction(t);
      expect(model.account, Account.cash);
      expect(model.toAccount, Account.mpesa);
      expect(model.fee, isNull);
    });

    test('airtime purchase', () {
      final t = mpesa('TJ6AB1CD2L confirmed.You bought Ksh100.00 of airtime on '
          '6/10/26 at 8:00 AM.New M-PESA balance is Ksh600.00.')!;

      expect(t.kind, SmsTransactionKind.airtime);
      expect(t.amount, 100);
      expect(SmsCategorizer.categorize(t), 'airtime_data');
    });

    test('Uber and a restaurant get Transport and Food', () {
      final uber = mpesa('TJ6AB1CD2M Confirmed. Ksh450.00 paid to UBER BV. on '
          '6/10/26 at 7:12 PM.New M-PESA balance is Ksh150.00.')!;
      final food = mpesa('TJ6AB1CD2N Confirmed. Ksh820.00 paid to JAVA HOUSE '
          'ABC PLACE. on 6/10/26 at 1:00 PM.New M-PESA balance is Ksh9.00.')!;
      final rent = mpesa('TJ6AB1CD2O Confirmed. Ksh25,000.00 sent to SUNRISE '
          'APARTMENTS RENT for account B12 on 1/10/26 at 9:00 AM New M-PESA '
          'balance is Ksh1,000.00.')!;
      final school = mpesa('TJ6AB1CD2P Confirmed. Ksh30,000.00 sent to '
          'STRATHMORE UNIVERSITY for account 99887 on 1/10/26 at 9:00 AM New '
          'M-PESA balance is Ksh1,000.00.')!;

      expect(SmsCategorizer.categorize(uber), 'transport');
      expect(SmsCategorizer.categorize(food), 'food');
      expect(SmsCategorizer.categorize(rent), 'housing');
      expect(SmsCategorizer.categorize(school), 'education');
    });

    test('unknown merchant is Uncategorized', () {
      final t = mpesa('TJ6AB1CD2Q Confirmed. Ksh300.00 paid to ZEBRA '
          'ENTERPRISES. on 6/10/26 at 1:00 PM.New M-PESA balance is Ksh9.00.')!;
      expect(SmsCategorizer.categorize(t), 'uncategorized');
    });

    test('ignores failed transactions, promotions and OTPs', () {
      expect(mpesa('Failed. Insufficient funds in your M-PESA account to '
          'send Ksh5,000.00.'), isNull);
      expect(mpesa('TJ6AB1CD2R Failed. You entered the wrong PIN.'), isNull);
      expect(mpesa('Get 50% bonus on Ksh100 airtime this weekend! Dial '
          '*544#.'), isNull);
      expect(mpesa('Your M-PESA verification code is 123456. Do not share.'),
          isNull);
    });
  });

  group('Airtel Money', () {
    test('money sent', () {
      final t = airtel('Trans. ID: MP261006.1415.A12345. You have sent Ksh '
          '500.00 to 0733123456 PETER OTIENO on 06/10/2026 14:15. Your bal '
          'is Ksh 1,200.00. Cost Ksh 0.00')!;

      expect(t.source, TransactionSource.airtel);
      expect(t.reference, 'MP261006.1415.A12345');
      expect(t.amount, 500);
      expect(t.kind, SmsTransactionKind.sent);
      expect(t.counterparty, 'Peter Otieno');
      expect(t.dedupeKey, 'airtel_MP261006.1415.A12345');
    });

    test('money received', () {
      final t = airtel('TID: CI261006.0930.B67890 You have received KES '
          '1,000.00 from 0733999888 MARY AKINYI on 06/10/2026 09:30. New bal '
          'Ksh 2,200.00')!;

      expect(t.type, TransactionType.income);
      expect(t.amount, 1000);
      expect(t.counterparty, 'Mary Akinyi');
      expect(SmsCategorizer.categorize(t), 'money_received');
    });

    test('merchant payment', () {
      final t = airtel('Trans ID: PP261006.1200.C11111. Paid Ksh 300.00 to '
          'QUICKMART KILIMANI on 06/10/2026 12:00. Your bal is Ksh 900.00')!;

      expect(t.kind, SmsTransactionKind.payment);
      expect(t.counterparty, 'Quickmart Kilimani');
      expect(SmsCategorizer.categorize(t), 'shopping');
    });

    test('ignores promotions with no transaction id', () {
      expect(airtel('Buy 1GB for Ksh 50 today only! Dial *544#'), isNull);
    });
  });

  group('sender filter', () {
    test('only M-Pesa and Airtel Money senders are processed', () {
      const body = 'TJ6AB1CD2E Confirmed. Ksh500.00 paid to NAIVAS. on '
          '6/10/26 at 1:20 PM.New M-PESA balance is Ksh2,700.00.';

      expect(SmsParser.parse(sender: 'M-PESA', body: body, date: smsDate),
          isNotNull);
      // A look-alike message from an ordinary number is NOT trusted:
      // anyone can type this text and send it.
      expect(SmsParser.parse(sender: '+254712345678', body: body, date: smsDate),
          isNull);
      expect(SmsParser.parse(sender: 'Safaricom', body: body, date: smsDate),
          isNull);
    });
  });

  group('privacy', () {
    test('phone and account numbers are masked in the stored text', () {
      expect(SmsParser.maskDigits('to JOHN 0712345678 acct 54321098765'),
          'to JOHN 07*****678 acct 54******765');
    });

    test('the saved transaction has only what PennyWise needs', () {
      final t = mpesa('TJ6AB1CD2F Confirmed. Ksh1,500.00 sent to JOHN DOE '
          '0712345678 on 6/10/26 at 2:15 PM. New M-PESA balance is '
          'Ksh3,200.00. Transaction cost, Ksh23.00.')!;
      final model = SmsImportService.toTransaction(t);

      expect(model.description, 'John Doe');
      expect(model.amount, 1500);
      expect(model.source, TransactionSource.mpesa);
      expect(model.reference, 'TJ6AB1CD2F');
      // The charge is a number now, so it counts in the totals.
      expect(model.fee, 23);
      expect(model.note, isNull);
      expect(model.type, TransactionType.expense);
      expect(model.account, Account.mpesa);
      expect(model.smsText, isNot(contains('0712345678')));
      expect(model.smsText, contains('07*****678'));
    });
  });

  group('savings products', () {
    test('money sent to Ziidi is a savings contribution, not spending', () {
      final t = mpesa('TJ6AB1CD3A Confirmed. Ksh1,000.00 sent to ZIIDI on '
          '12/10/26 at 8:15 PM. New M-PESA balance is Ksh1,200.00. '
          'Transaction cost, Ksh0.00.')!;
      final model = SmsImportService.toTransaction(t);

      expect(model.type, TransactionType.savingsContribution);
      expect(model.categoryId, 'savings');
      expect(model.account, Account.mpesa);
      expect(model.fee, isNull); // a KSh 0.00 charge isn't stored
    });

    test('money received from Ziidi is a savings withdrawal, not income', () {
      final t = mpesa('TJ6AB1CD3B Confirmed.You have received Ksh2,000.00 '
          'from ZIIDI on 13/10/26 at 9:00 AM. New M-PESA balance is '
          'Ksh3,200.00.')!;
      final model = SmsImportService.toTransaction(t);

      expect(model.type, TransactionType.savingsWithdrawal);
      expect(model.categoryId, 'savings_withdrawal');
    });

    test('a Ziidi advert at the end of a payment SMS changes nothing', () {
      final t = mpesa('TJ6AB1CD3C Confirmed. Ksh250.00 paid to NAIVAS. on '
          '13/10/26 at 1:20 PM.New M-PESA balance is Ksh2,950.00. '
          'Transaction cost, Ksh0.00. Invest & earn daily interest with '
          'ZIIDI on https://example.com')!;

      expect(t.type, TransactionType.expense);
      expect(SmsImportService.toTransaction(t).categoryId, 'shopping');
    });
  });
}
