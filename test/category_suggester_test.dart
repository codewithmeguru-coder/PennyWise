import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/categorization/category_suggester.dart';
import 'package:pennywise/categorization/merchant_key.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_categorizer.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_transaction.dart';

// Sample messages follow the real M-Pesa shapes; codes, names and numbers
// are made up.
final date = DateTime(2026, 10, 9, 17, 5);

SmsTransaction mpesa(String body) =>
    SmsParser.parse(sender: 'MPESA', body: body, date: date)!;

Suggestion suggest(String body) => const CategorySuggester().forSms(mpesa(body));

String paidTo(String name, {String amount = '250.00'}) =>
    'TJ9AB1CD2E Confirmed. Ksh$amount paid to $name. on 9/10/26 at 5:05 PM.'
    'New M-PESA balance is Ksh1,200.00. Transaction cost, Ksh0.00.';

String paybill(String name, String account) =>
    'TJ9AB1CD2F Confirmed. Ksh1,500.00 sent to $name for account $account '
    'on 9/10/26 at 5:05 PM New M-PESA balance is Ksh900.00. Transaction '
    'cost, Ksh15.00.';

void main() {
  group('high confidence: clear from the message or a known business', () {
    test('Safaricom Offers is airtime & data', () {
      final s = suggest(paidTo('SAFARICOM OFFERS'));
      expect(s.categoryId, 'airtime_data');
      expect(s.confidence, Confidence.high);
    });

    test('supermarkets, utilities, subscriptions, transport', () {
      expect(suggest(paidTo('NAIVAS WESTLANDS')).categoryId, 'shopping');
      expect(suggest(paybill('KPLC PREPAID', '54123456789')).categoryId,
          'bills');
      expect(suggest(paybill('DSTV', '1234567')).categoryId, 'subscriptions');
      expect(suggest(paidTo('UBER KENYA')).confidence, Confidence.high);
    });

    test('the longest known phrase wins', () {
      final s = suggest(paybill('KENYA POWER AND LIGHTING', '123456789'));
      expect(s.categoryId, 'bills');
      expect(s.reason, contains('KENYA POWER'));
    });

    test('money received from a person', () {
      final s = suggest('TJ9AB1CD2G Confirmed.You have received Ksh500.00 '
          'from JANE DOE 0712345678 on 9/10/26 at 5:05 PM New M-PESA '
          'balance is Ksh1,700.00.');
      expect(s.categoryId, 'money_received');
      expect(s.confidence, Confidence.high);
    });

    test('salary from the sender name', () {
      final s = suggest('TJ9AB1CD2H Confirmed.You have received Ksh50,000.00 '
          'from ACME LTD SALARY on 30/9/26 at 9:00 AM New M-PESA balance is '
          'Ksh51,000.00.');
      expect(s.categoryId, 'salary');
      expect(s.confidence, Confidence.high);
    });
  });

  group('medium confidence: a keyword', () {
    test('generic words are never high', () {
      for (final name in ['MAMA PIMA SHOP', 'TOTAL HOTEL', 'BLUE WATER']) {
        final s = suggest(paidTo(name));
        expect(s.confidence, isNot(Confidence.high), reason: name);
      }
    });

    test('a keyword gives its category with medium confidence', () {
      final s = suggest(paidTo('GLORIA BEAUTY SALON'));
      expect(s.categoryId, 'personal_care');
      expect(s.confidence, Confidence.medium);
      expect(s.reason, startsWith('Name contains'));
    });

    test('whole words only: "SPAR" is not "SPA"', () {
      expect(suggest(paidTo('SPAR SUPERMARKET')).categoryId, 'shopping');
    });
  });

  group('low confidence: left for review, never guessed', () {
    test('money sent to a person', () {
      final s = suggest('TJ9AB1CD2J Confirmed. Ksh1,000.00 sent to JOHN '
          'KAMAU 0722334455 on 9/10/26 at 5:05 PM. New M-PESA balance is '
          'Ksh200.00. Transaction cost, Ksh13.00.');
      expect(s.categoryId, CategorySuggester.uncategorized);
      expect(s.confidence, Confidence.low);
      expect(s.reason, contains('person'));
    });

    test('a person whose name contains a keyword is still not guessed', () {
      final s = suggest('TJ9AB1CD2K Confirmed. Ksh700.00 sent to SCHOOL '
          'MWANGI 0722334455 on 9/10/26 at 5:05 PM. New M-PESA balance is '
          'Ksh200.00. Transaction cost, Ksh7.00.');
      expect(s.confidence, Confidence.low);
    });

    test('bank Paybills are never transfers and stay in review', () {
      for (final name in ['IM BANK C2B', 'EQUITY PAYBILL ACCOUNT',
          'KCB PAYBILL', 'NCBA BANK']) {
        final s = suggest(paybill(name, '0123456789'));
        expect(s.categoryId, CategorySuggester.uncategorized, reason: name);
        expect(s.confidence, Confidence.low, reason: name);
        expect(s.reason, contains('bank'), reason: name);
        expect(mpesa(paybill(name, '0123456789')).type,
            TransactionType.expense);
      }
    });

    test('money received from a business: purpose unknown, left for review',
        () {
      final s = suggest('TJ9AB1CD2L Confirmed.You have received Ksh110,000.00 '
          'from EQUITY BULK ACCOUNT on 9/10/26 at 5:05 PM New M-PESA balance '
          'is Ksh110,200.00.');
      expect(s.categoryId, CategorySuggester.uncategorizedIncome);
      expect(s.confidence, Confidence.low);
    });

    test('an unknown business', () {
      final s = suggest(paidTo('OKAVA KENYA LTD'));
      expect(s.confidence, Confidence.low);
      expect(SmsCategorizer.categorize(mpesa(paidTo('OKAVA KENYA LTD'))),
          'uncategorized');
    });
  });

  group('savings and transfers come from the message type', () {
    test('Ziidi, both directions, any amount', () {
      final small = mpesa('TJ9AB1CD2M Confirmed. Ksh1.00 sent to ZIIDI on '
          '9/10/26 at 5:05 PM New M-PESA balance is Ksh99.00. Transaction '
          'cost, Ksh0.00.');
      final big = mpesa('TJ9AB1CD2N Confirmed. Ksh40,400.00 sent to ZIIDI on '
          '9/10/26 at 5:05 PM New M-PESA balance is Ksh99.00. Transaction '
          'cost, Ksh0.00.');
      final out = mpesa('TJ9AB1CD2P Confirmed.You have received Ksh1,000.00 '
          'from ZIIDI on 9/10/26 at 5:05 PM. New M-PESA balance is '
          'Ksh1,099.00.');
      expect(small.type, TransactionType.savingsContribution);
      expect(big.type, TransactionType.savingsContribution);
      expect(out.type, TransactionType.savingsWithdrawal);
      expect(const CategorySuggester().forSms(small).categoryId, 'savings');
    });

    test('a KSh 1 payment to anyone else is not savings', () {
      expect(mpesa(paidTo('KIOSK ONE', amount: '1.00')).type,
          TransactionType.expense);
    });

    test('"Ziidi Sacco" is not the Ziidi fund (exact name only)', () {
      final t = mpesa(paybill('ZIIDI SACCO', '12345'));
      expect(t.isSavingsProduct, isFalse);
      expect(t.type, TransactionType.expense);
    });

    test('a Ziidi advert in a payment message changes nothing', () {
      final t = mpesa(paidTo('NAIVAS').replaceFirst('Transaction cost',
          'Invest & earn daily interest with ZIIDI. Transaction cost'));
      expect(t.type, TransactionType.expense);
      expect(const CategorySuggester().forSms(t).categoryId, 'shopping');
    });
  });

  group('typed descriptions (Add form)', () {
    test('suggests, but never above medium', () {
      final s = const CategorySuggester().forDescription('Naivas groceries');
      expect(s!.categoryId, 'shopping');
      expect(s.confidence, Confidence.medium);
      expect(const CategorySuggester().forDescription('lunch with Tom'),
          isNull);
    });
  });

  test('merchant keys', () {
    expect(MerchantKey.normalize(' Naivas  Westlands. '), 'NAIVAS WESTLANDS');
    expect(MerchantKey.compact('M-Shwari'), 'MSHWARI');
    expect(MerchantKey.containsPhrase('KFC JUNCTION', 'KFC'), isTrue);
    expect(MerchantKey.containsPhrase('KFCX JUNCTION', 'KFC'), isFalse);
  });
}
