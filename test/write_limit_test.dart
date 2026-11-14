import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/write_limit.dart';

// The app's side of the daily write and edit limits: the count it writes
// must be the one the Firestore rules expect, and at the limit it writes
// nothing.

void main() {
  final noon = DateTime.utc(2026, 11, 1, 12);
  Map<String, dynamic> at(DateTime t, int count) =>
      {'at': Timestamp.fromDate(t), 'count': count, 'lastPath': 'x'};

  test('the first claim, or none yet today, is 1', () {
    expect(WriteLimit.nextCount(null, noon), 1);
    expect(WriteLimit.nextCount(at(DateTime.utc(2026, 10, 31, 23, 59), 1499), noon), 1);
  });

  test('later the same UTC day it goes up by one', () {
    expect(WriteLimit.nextCount(at(DateTime.utc(2026, 11, 1, 0, 1), 41), noon), 42);
  });

  test('days are UTC days, as in the rules (Nairobi is UTC+3)', () {
    // 01:30 in Nairobi on 2 Nov is still 1 Nov in UTC.
    final nairobiEarly = DateTime.utc(2026, 11, 1, 22, 30);
    expect(WriteLimit.nextCount(at(DateTime.utc(2026, 11, 1, 8), 7), nairobiEarly), 8);
  });

  test('matches the rules\' limits', () {
    expect(WriteLimit.daily, 1500);
    expect(WriteLimit.edits, 3000);
  });

  group('an edit claim', () {
    Map<String, dynamic> claim(Map<String, dynamic>? data, String path) =>
        WriteLimit.claimFields(data, noon, path, WriteLimit.edits,
            WriteLimit.editsReachedMessage);

    test('goes up by one, names the document and is stamped by the server',
        () {
      final w = claim(at(DateTime.utc(2026, 11, 1, 9), 41), 'transactions/t1');
      expect(w, {
        'at': FieldValue.serverTimestamp(),
        'count': 42,
        'lastPath': 'transactions/t1',
      });
    });

    test('the 3,000th today is allowed', () {
      expect(claim(at(DateTime.utc(2026, 11, 1, 9), 2999), 'profile')['count'],
          3000);
    });

    test('the 3,001st today is refused with a message the user can read', () {
      expect(
        () => claim(at(DateTime.utc(2026, 11, 1, 9), 3000), 'budgets/2026-11'),
        throwsA(isA<DataException>().having(
            (e) => e.message, 'message', WriteLimit.editsReachedMessage)),
      );
    });

    test('a full counter from yesterday starts again at 1', () {
      expect(
          claim(at(DateTime.utc(2026, 10, 31, 20), 3000), 'accounts/a')['count'],
          1);
    });
  });

  test('the two limits are separate: 1,500 new records, 3,000 edits', () {
    final today = at(DateTime.utc(2026, 11, 1, 9), 1500);
    // 1,500 is the end for new records ...
    expect(
      () => WriteLimit.claimFields(today, noon, 'transactions/t2',
          WriteLimit.daily, WriteLimit.reachedMessage),
      throwsA(isA<DataException>().having(
          (e) => e.message, 'message', WriteLimit.reachedMessage)),
    );
    // ... but not for edits.
    expect(
        WriteLimit.claimFields(today, noon, 'transactions/t1', WriteLimit.edits,
            WriteLimit.editsReachedMessage)['count'],
        1501);
  });
}
