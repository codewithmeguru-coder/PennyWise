import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/security/app_lock_controller.dart';

import 'fake_app_lock.dart';
import 'fake_auth_service.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Everything is in memory: no secure storage, biometrics, Firebase or
// Firestore is touched.

/// A tall test screen (800 x 1000), so the whole keypad fits. Kept as wide
/// as the default test screen: the test font is wider than real text.
void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(2400, 3000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Future<void> typePin(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.widgetWithText(InkWell, d).last);
    await tester.pump();
  }
}

/// Puts App Lock on with PIN 2468 in [store], as if set up earlier.
Future<void> setUpPin(MemoryAppLockStore store, {bool biometrics = false}) async {
  final lock = testAppLock(store: store, biometrics: FakeBiometrics());
  await lock.init();
  await lock.enable('2468');
  if (biometrics) await lock.setBiometrics(true);
}

void main() {
  testWidgets('with App Lock on, the app opens locked and shows no money',
      (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store);
    await pumpApp(tester, appLock: testAppLock(store: store));

    expect(find.text('PennyWise is locked'), findsOneWidget);
    // The dashboard is built underneath but not visible or tappable.
    expect(find.text('Available balance'), findsNothing);
    expect(find.text('Lunch'), findsNothing);
    expect(find.text('Add'), findsNothing);

    await typePin(tester, '2468');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    expect(find.text('PennyWise is locked'), findsNothing);
    expect(find.text('Available balance'), findsOneWidget);
  });

  testWidgets('wrong PINs: tries left, then the pause message', (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store);
    await pumpApp(tester, appLock: testAppLock(store: store));

    await typePin(tester, '1111');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(
        find.text('Wrong PIN. 4 tries left before a pause.'), findsOneWidget);

    for (var i = 0; i < 4; i++) {
      await typePin(tester, '1111');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('Too many wrong PINs. Try again in'),
        findsOneWidget);
    expect(find.text('Available balance'), findsNothing);
  });

  testWidgets('backgrounding past the timeout locks; a short trip does not',
      (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store);
    var mono = Duration.zero;
    final lock = testAppLock(store: store, elapsed: () => mono);
    await pumpApp(tester, appLock: lock);
    await typePin(tester, '2468');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();

    void lifecycle(AppLifecycleState s) =>
        tester.binding.handleAppLifecycleStateChanged(s);

    // Away for 30 s (default timeout is 1 minute): still unlocked.
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    await tester.pump();
    // While away, a cover hides the balances (recent-apps preview).
    expect(find.text('Available balance').hitTestable(), findsNothing);
    mono += const Duration(seconds: 30);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Available balance'), findsOneWidget);

    // Away for 2 minutes: locked.
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    mono += const Duration(minutes: 2);
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('PennyWise is locked'), findsOneWidget);
    expect(find.text('Available balance'), findsNothing);
  });

  testWidgets('a system dialog over the app (inactive) never locks it',
      (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store);
    final lock = testAppLock(store: store);
    await pumpApp(tester, appLock: lock);
    await typePin(tester, '2468');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    await lock.setTimeout(Duration.zero);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('PennyWise is locked'), findsNothing);
  });

  testWidgets('fingerprint unlocks; if it fails, the PIN still works',
      (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store, biometrics: true);
    final bio = FakeBiometrics(succeeds: false);
    await pumpApp(tester,
        appLock: testAppLock(store: store, biometrics: bio));

    // Offered automatically once; it failed.
    expect(bio.prompts, 1);
    expect(find.text('Fingerprint not recognised. Enter your PIN.'),
        findsOneWidget);
    expect(find.byTooltip('Use fingerprint'), findsOneWidget);

    bio.succeeds = true;
    await tester.tap(find.byTooltip('Use fingerprint'));
    await tester.pumpAndSettle();
    expect(find.text('Available balance'), findsOneWidget);
  });

  testWidgets('"Forgot PIN? Sign out" signs out and turns App Lock off, '
      'after confirming', (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store);
    final auth = FakeAuthService(signedInAs: FakeAuthService.testUser);
    final repo = FakeTransactionRepository(testTransactions());
    await pumpApp(tester,
        auth: auth, repository: repo, appLock: testAppLock(store: store));

    await tester.tap(find.text('Forgot PIN? Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out and reset App Lock?'), findsOneWidget);
    // Cancel keeps everything as it was.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('PennyWise is locked'), findsOneWidget);
    expect(auth.currentUser, isNotNull);

    await tester.tap(find.text('Forgot PIN? Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(auth.currentUser, isNull); // signed out of Firebase
    expect(store.saved, isNull); // App Lock cleared on this device
    expect(repo.items, hasLength(2)); // cloud data untouched
    expect(find.text('PennyWise is locked'), findsNothing);
    expect(find.text('Sign in'), findsWidgets); // login screen
  });

  testWidgets('unlocking does not sign the user out', (tester) async {
    phone(tester);
    final store = MemoryAppLockStore();
    await setUpPin(store);
    final auth = FakeAuthService(signedInAs: FakeAuthService.testUser);
    await pumpApp(tester, auth: auth, appLock: testAppLock(store: store));
    await typePin(tester, '2468');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(auth.currentUser, isNotNull);
  });

  group('Settings › App Lock', () {
    Future<AppLockController> openAppLockSettings(WidgetTester tester,
        {AppLockController? lock}) async {
      final controller = lock ?? testAppLock(biometrics: FakeBiometrics());
      await pumpApp(tester, appLock: controller);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('App Lock'));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('turning on: create, mismatch, then confirm', (tester) async {
    phone(tester);
      final lock = await openAppLockSettings(tester);

      await tester.tap(find.text('Use App Lock'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a 4–6 digit PIN'), findsOneWidget);
      await typePin(tester, '123');
      expect(
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
              .onPressed,
          isNull); // too short
      await typePin(tester, '4');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm your PIN'), findsOneWidget);
      await typePin(tester, '9999');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.text('The PINs didn\'t match. Start again.'), findsOneWidget);

      await typePin(tester, '1234');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await typePin(tester, '1234');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(lock.isEnabled, isTrue);
      expect(lock.status, AppLockStatus.unlocked);
      expect(find.text('Change PIN'), findsOneWidget);
      expect(find.text('Immediately'), findsOneWidget);
      expect(find.text('After 1 minute'), findsOneWidget);
      expect(find.text('After 5 minutes'), findsOneWidget);
      expect((await lock.checkPin('1234')).ok, isTrue);
    });

    testWidgets('change PIN needs the current one', (tester) async {
    phone(tester);
      final store = MemoryAppLockStore();
      await setUpPin(store);
      final lock = testAppLock(store: store);
      await pumpApp(tester, appLock: lock);
      await typePin(tester, '2468');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('App Lock'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      await typePin(tester, '0000');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Wrong PIN. 4 tries left.'), findsOneWidget);

      await typePin(tester, '2468');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('New PIN'), findsOneWidget);
      await typePin(tester, '864200');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await typePin(tester, '864200');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect((await lock.checkPin('2468')).ok, isFalse);
      expect((await lock.checkPin('864200')).ok, isTrue);
    });

    testWidgets('turning off needs the PIN; timeout can be changed',
        (tester) async {
    phone(tester);
      final store = MemoryAppLockStore();
      await setUpPin(store);
      final lock = testAppLock(store: store);
      await pumpApp(tester, appLock: lock);
      await typePin(tester, '2468');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('App Lock'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('After 5 minutes'));
      await tester.pumpAndSettle();
      expect(lock.timeout, const Duration(minutes: 5));

      await tester.tap(find.text('Use App Lock'));
      await tester.pumpAndSettle();
      await typePin(tester, '2468');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(lock.isEnabled, isFalse);
      expect(store.saved, isNull);
    });

    testWidgets('biometrics option only when the phone supports it',
        (tester) async {
    phone(tester);
      await openAppLockSettings(tester,
          lock: testAppLock(biometrics: FakeBiometrics(available: false)));
      await tester.tap(find.text('Use App Lock'));
      await tester.pumpAndSettle();
      await typePin(tester, '1234');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await typePin(tester, '1234');
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Not available'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget); // only "Use App Lock"
    });
  });
}
