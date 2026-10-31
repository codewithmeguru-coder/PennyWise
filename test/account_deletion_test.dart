import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/screens/delete_account_screen.dart';
import 'package:pennywise/services/account_deletion.dart';
import 'package:pennywise/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_service.dart';

// Deleting the signed-in user's account: everything they own, this phone's
// settings for them, then their sign-in. In memory only: no real account
// or data is touched.

/// One user's data, in memory. [failOn] makes that step fail once.
class FakeUserData implements UserDataStore {
  FakeUserData() {
    for (final c in AccountDeletion.collections) {
      docs[c] = 450; // more than one batch
    }
  }

  final docs = <String, int>{};
  bool marker = false, photo = true, profile = true;
  String? failOn;
  final log = <String>[];

  void _maybeFail(String step) {
    if (failOn == step) {
      failOn = null;
      throw const DataException('No connection.');
    }
  }

  @override
  Future<bool> deletionPending() async => marker;

  @override
  Future<void> markDeletion() async {
    _maybeFail('mark');
    log.add('mark');
    marker = true;
  }

  @override
  Future<int> deleteSome(String collection, {int batch = 200}) async {
    _maybeFail(collection);
    // Records that are otherwise kept can only go once the request exists
    // (as the Firestore rules require).
    if (!marker) throw const DataException('Permission denied.');
    final n = docs[collection]! < batch ? docs[collection]! : batch;
    docs[collection] = docs[collection]! - n;
    return n;
  }

  @override
  Future<void> deleteDoc(String path) async {
    _maybeFail(path);
    if (path == AccountDeletion.photo) photo = false;
  }

  @override
  Future<void> clearMarker() async {
    log.add('clear');
    marker = false;
  }

  @override
  Future<void> deleteProfile() async {
    _maybeFail('profile');
    profile = false;
  }

  bool get allGone =>
      docs.values.every((n) => n == 0) && !photo && !profile && !marker;
}

void main() {
  late FakeUserData data;
  late FakeAuthService auth;
  late int localCleared;

  AccountDeletion make() => AccountDeletion(
    data: data,
    auth: auth,
    clearLocal: () async => localCleared++,
  );

  setUp(() {
    data = FakeUserData();
    auth = FakeAuthService(signedInAs: FakeAuthService.testUser);
    localCleared = 0;
  });

  group('deleting', () {
    test('everything the user owns, this phone\'s settings, then the sign-in',
        () async {
      await make().run();
      expect(data.allGone, isTrue);
      // The request comes first and goes only after all the data.
      expect(data.log, ['mark', 'clear']);
      expect(localCleared, 1);
      expect(auth.signInDeleted, isTrue);
    });

    test('the profile photo is removed too (no other file storage is used)',
        () async {
      await make().run();
      expect(data.photo, isFalse);
    });

    test('stopped halfway: the request stays, nothing on the phone or the '
        'sign-in is touched; running again finishes', () async {
      data.failOn = 'accounts';
      await expectLater(make().run(), throwsA(isA<DeletionException>()));
      expect(data.marker, isTrue);
      expect(await make().pending(), isTrue);
      expect(data.docs['transactions'], 0); // earlier steps are done
      expect(data.docs['accounts'], 450);
      expect(localCleared, 0);
      expect(auth.signInDeleted, isFalse);

      await make().run();
      expect(data.allGone, isTrue);
      expect(auth.signInDeleted, isTrue);
    });

    test('the sign-in could not be deleted: the data is gone, and trying '
        'again removes the sign-in', () async {
      auth.nextDeleteError = const AuthException('Confirm it\'s you again.');
      await expectLater(
        make().run(),
        throwsA(
          isA<DeletionException>().having(
            (e) => e.message,
            'message',
            contains('Your data is deleted'),
          ),
        ),
      );
      expect(data.allGone, isTrue);
      expect(auth.signInDeleted, isFalse);
      await make().run();
      expect(auth.signInDeleted, isTrue);
    });
  });

  test('this phone: only the deleted user\'s saved settings are removed',
      () async {
    SharedPreferences.setMockInitialValues({
      'sms_u1_enabled': true,
      'move_fix_u1_log': 'x',
      'sms_u2_enabled': true,
      'appearance.themeMode': 'dark',
    });
    expect(await LocalUserData.clear('u1'), 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'sms_u2_enabled', 'appearance.themeMode'});
  });

  group('the screen', () {
    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: DeleteAccountScreen(
            deletion: make(),
            email: 'test@example.com',
            transactionCount: 1234,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(
      find.byKey(const Key('delete-start')),
    );

    Future<void> fill(WidgetTester tester, {String password = 'secret12'}) async {
      await tester.tap(find.byKey(const Key('delete-understood')));
      await tester.enterText(find.byKey(const Key('delete-word')), 'DELETE');
      await tester.enterText(find.byKey(const Key('delete-password')), password);
      await tester.pumpAndSettle();
    }

    testWidgets('says it is permanent and lists what goes', (tester) async {
      await show(tester);
      expect(find.textContaining('permanent'), findsOneWidget);
      expect(find.text('• All 1234 of your transactions'), findsOneWidget);
      expect(find.textContaining('profile photo'), findsOneWidget);
    });

    testWidgets('locked until ticked, DELETE typed and the password given',
        (tester) async {
      await show(tester);
      expect(button(tester).onPressed, isNull);
      await tester.tap(find.byKey(const Key('delete-understood')));
      await tester.enterText(find.byKey(const Key('delete-word')), 'delete');
      await tester.enterText(
        find.byKey(const Key('delete-password')),
        'secret12',
      );
      await tester.pumpAndSettle();
      expect(button(tester).onPressed, isNull); // must be DELETE
      await tester.enterText(find.byKey(const Key('delete-word')), 'DELETE');
      await tester.pumpAndSettle();
      expect(button(tester).onPressed, isNotNull);
    });

    testWidgets('a wrong password deletes nothing and says why', (tester) async {
      await show(tester);
      await fill(tester, password: 'wrong');
      await tester.tap(find.byKey(const Key('delete-start')));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(data.log, isEmpty);
      expect(auth.signInDeleted, isFalse);
    });

    testWidgets('a different Google account deletes nothing', (tester) async {
      auth
        ..signsInWithGoogle = true
        ..googleReauth = null;
      await show(tester);
      await tester.tap(find.byKey(const Key('delete-understood')));
      await tester.enterText(find.byKey(const Key('delete-word')), 'DELETE');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-start')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-error')), findsOneWidget);
      expect(data.log, isEmpty);
    });

    testWidgets('"Keep my account" at the last step deletes nothing', (
      tester,
    ) async {
      await show(tester);
      await fill(tester);
      await tester.tap(find.byKey(const Key('delete-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep my account'));
      await tester.pumpAndSettle();
      expect(data.log, isEmpty);
    });

    testWidgets('confirmed: everything is deleted', (tester) async {
      await show(tester);
      await fill(tester);
      await tester.tap(find.byKey(const Key('delete-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-final')));
      await tester.pumpAndSettle();
      expect(data.allGone, isTrue);
      expect(auth.signInDeleted, isTrue);
    });

    testWidgets('a deletion that stopped halfway is offered to finish', (
      tester,
    ) async {
      data.marker = true;
      await show(tester);
      expect(find.byKey(const Key('deletion-pending')), findsOneWidget);
      expect(find.text('Finish deleting'), findsOneWidget);
    });
  });
}
