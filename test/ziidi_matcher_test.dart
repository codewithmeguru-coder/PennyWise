import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/maintenance/ziidi_matcher.dart';

// Masked copies of the real message shapes found in the backup (codes,
// amounts and dates made up; long digit runs masked like PennyWise stores
// them).
const sentSmall = 'UIEHK3T4AS Confirmed. Ksh1.00 sent to ZIIDI on 9/10/26 at '
    '5:05 PM New M-PESA balance is Ksh52.00. Transaction cost, Ksh0.00.Amount '
    'you can transact within the day is 49*****.00. Pay your water/KPLC bill '
    'conveniently using M-PESA APP or use Paybill option on Lipa Na M-PESA.';
const sentBig = 'UIEHK3T4AT Confirmed. Ksh40,400.00 sent to ZIIDI on 1/10/26 '
    'at 9:12 AM New M-PESA balance is Ksh1,052.00. Transaction cost, Ksh0.00.';
const received = 'UIEHK3T4AR Confirmed.You have received Ksh1,000.00 from '
    'ZIIDI on 3/10/26 1:15 PM. New M-PESA balance is Ksh1,600.00. Separate '
    'personal and business funds through Pochi la Biashara on *334#.';
const advertOnly = 'UIEHK3T4AU Confirmed.You have received Ksh500.00 from '
    'AMOS KIPKURUI 07*****678 on 3/10/26 at 2:00 PM New M-PESA balance is '
    'Ksh2,100.00. Invest & earn daily interest with ZIIDI on https://example';

final created = DateTime.utc(2026, 10, 9, 14, 5, 1);

StoredSmsRecord record(
  String sms, {
  String type = 'expense',
  String code = 'UIEHK3T4AS',
  String? id,
  String source = 'mpesa',
  DateTime? updatedAt,
  bool reclassified = false,
}) =>
    StoredSmsRecord(
      id: id ?? 'mpesa_$code',
      type: type,
      source: source,
      reference: code,
      smsText: sms,
      createdAt: created,
      updatedAt: updatedAt ?? created,
      hasReclassifiedFrom: reclassified,
    );

void main() {
  test('exact sentences match, both directions, any amount', () {
    expect(ZiidiMatcher.directionOf(sentSmall), ZiidiDirection.sent);
    expect(ZiidiMatcher.directionOf(sentBig), ZiidiDirection.sent);
    expect(ZiidiMatcher.directionOf(received), ZiidiDirection.received);
  });

  test('an advert-only mention never matches', () {
    expect(ZiidiMatcher.directionOf(advertOnly), isNull);
    final check = ZiidiMatcher.check(record(advertOnly, type: 'income'));
    expect(check.isZiidi, isFalse);
    expect(check.change, isFalse);
    expect(check.reason, 'Ziidi only mentioned in an advert');
  });

  test('other names and KSh 1 payments elsewhere never match', () {
    expect(
        ZiidiMatcher.directionOf(sentSmall.replaceFirst('ZIIDI', 'ZIIDI SACCO')),
        isNull);
    expect(ZiidiMatcher.directionOf(sentSmall.replaceFirst('ZIIDI', 'KIOSK')),
        isNull);
    expect(
        ZiidiMatcher.directionOf(
            sentSmall.replaceFirst('sent to ZIIDI', 'paid to ZIIDI SHOP')),
        isNull);
  });

  test('an untouched SMS import is changed to savings', () {
    final out = ZiidiMatcher.check(record(sentSmall));
    expect(out.change, isTrue);
    expect(out.newType, 'savings_contribution');
    expect(out.newCategory, 'savings');

    final back = ZiidiMatcher.check(
        record(received, type: 'income', code: 'UIEHK3T4AR'));
    expect(back.change, isTrue);
    expect(back.newType, 'savings_withdrawal');
    expect(back.newCategory, 'savings_withdrawal');
  });

  test('records edited by the user are skipped', () {
    final check = ZiidiMatcher.check(record(sentSmall,
        updatedAt: created.add(const Duration(days: 2))));
    expect(check.isZiidi, isTrue);
    expect(check.change, isFalse);
    expect(check.reason, 'Edited by you after import');
  });

  test('already savings, or already fixed: skipped (a second run is a no-op)',
      () {
    expect(
        ZiidiMatcher.check(record(sentSmall, type: 'savings_contribution'))
            .change,
        isFalse);
    expect(ZiidiMatcher.check(record(sentSmall, reclassified: true)).change,
        isFalse);
  });

  test('manual entries and odd ids are never changed', () {
    expect(ZiidiMatcher.check(record(sentSmall, source: 'manual')).change,
        isFalse);
    expect(ZiidiMatcher.check(record(sentSmall, id: 'abc123')).change, isFalse);
  });

  test('a Ziidi send stored as income is reported, not changed', () {
    final check = ZiidiMatcher.check(record(sentSmall, type: 'income'));
    expect(check.change, isFalse);
    expect(check.reason, 'Already recorded as income');
  });

  test('the same SMS in two accounts is decided per record, independently',
      () {
    // Same code, different account paths: each is its own record.
    final a = ZiidiMatcher.check(record(sentSmall));
    final b = ZiidiMatcher.check(record(sentSmall));
    expect(a.change && b.change, isTrue);
  });
}
