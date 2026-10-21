import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/security/app_lock_controller.dart';

import 'fake_app_lock.dart';

/// Hand-driven clocks: [wall] for lockouts, [mono] for the background
/// timeout.
class Clocks {
  DateTime wall = DateTime(2026, 10, 21, 12);
  Duration mono = Duration.zero;

  void pass(Duration d) {
    wall = wall.add(d);
    mono += d;
  }
}

void main() {
  late MemoryAppLockStore store;
  late Clocks clocks;
  late FakeBiometrics bio;
  late FakePrivacy privacy;

  AppLockController make() => testAppLock(
        store: store,
        biometrics: bio,
        privacy: privacy,
        now: () => clocks.wall,
        elapsed: () => clocks.mono,
      );

  /// A controller with App Lock on (PIN 2468), unlocked.
  Future<AppLockController> enabled() async {
    final lock = make();
    await lock.init();
    await lock.enable('2468');
    return lock;
  }

  setUp(() {
    store = MemoryAppLockStore();
    clocks = Clocks();
    bio = FakeBiometrics(available: false);
    privacy = FakePrivacy();
  });

  group('setup and verification', () {
    test('off by default: nothing is locked or stored', () async {
      final lock = make();
      await lock.init();
      expect(lock.status, AppLockStatus.off);
      expect(lock.blocksApp, isFalse);
      expect(store.saved, isNull);
      expect(privacy.hidden, isFalse);
    });

    test('enabling stores only a salted hash, never the PIN', () async {
      final lock = await enabled();
      expect(lock.status, AppLockStatus.unlocked);
      expect(store.saved.toString(), isNot(contains('2468')));
      expect((store.saved!['pin'] as Map).keys,
          containsAll(['salt', 'hash', 'iterations']));
      expect(privacy.hidden, isTrue); // recent-apps preview hidden
    });

    test('a restart always starts locked; the right PIN unlocks', () async {
      await enabled();
      final restarted = make();
      await restarted.init();
      expect(restarted.status, AppLockStatus.locked);
      expect(restarted.blocksApp, isTrue);

      expect((await restarted.unlockWithPin('1111')).ok, isFalse);
      expect(restarted.status, AppLockStatus.locked);
      expect((await restarted.unlockWithPin('2468')).ok, isTrue);
      expect(restarted.status, AppLockStatus.unlocked);
    });

    test('change PIN: the old one stops working', () async {
      final lock = await enabled();
      expect((await lock.checkPin('2468')).ok, isTrue);
      await lock.changePin('975310');

      final restarted = make();
      await restarted.init();
      expect((await restarted.unlockWithPin('2468')).ok, isFalse);
      expect((await restarted.unlockWithPin('975310')).ok, isTrue);
    });

    test('disable clears everything on the device', () async {
      final lock = await enabled();
      await lock.disable();
      expect(lock.status, AppLockStatus.off);
      expect(store.saved, isNull);
      expect(privacy.hidden, isFalse);
    });
  });

  group('wrong PINs and lockouts', () {
    test('5 wrong PINs: 30 s pause, then doubling up to 15 minutes', () {
      expect(AppLockController.lockoutFor(4), Duration.zero);
      expect(AppLockController.lockoutFor(5), const Duration(seconds: 30));
      expect(AppLockController.lockoutFor(6), const Duration(seconds: 60));
      expect(AppLockController.lockoutFor(7), const Duration(minutes: 2));
      expect(AppLockController.lockoutFor(9), const Duration(minutes: 8));
      expect(AppLockController.lockoutFor(10), const Duration(minutes: 15));
      expect(AppLockController.lockoutFor(50), const Duration(minutes: 15));
    });

    test('counts down tries, then refuses even the right PIN until the '
        'pause is over', () async {
      final lock = await enabled();
      for (var left = 4; left >= 1; left--) {
        expect((await lock.checkPin('0000')).triesLeft, left);
      }
      final fifth = await lock.checkPin('0000');
      expect(fifth.wait, const Duration(seconds: 30));

      final blocked = await lock.checkPin('2468');
      expect(blocked.ok, isFalse);
      expect(blocked.wait, const Duration(seconds: 30));

      clocks.pass(const Duration(seconds: 29));
      expect(lock.lockoutRemaining, const Duration(seconds: 1));
      clocks.pass(const Duration(seconds: 1));
      expect(lock.lockoutRemaining, isNull);

      // The next wrong PIN doubles the pause.
      expect((await lock.checkPin('0000')).wait, const Duration(minutes: 1));
      clocks.pass(const Duration(minutes: 1));
      // A correct PIN resets the count.
      expect((await lock.checkPin('2468')).ok, isTrue);
      expect((await lock.checkPin('0000')).triesLeft, 4);
    });

    test('a restart does not skip a lockout', () async {
      final lock = await enabled();
      for (var i = 0; i < 5; i++) {
        await lock.checkPin('0000');
      }
      final restarted = make();
      await restarted.init();
      expect(restarted.status, AppLockStatus.locked);
      expect(restarted.lockoutRemaining, const Duration(seconds: 30));
      expect((await restarted.unlockWithPin('2468')).ok, isFalse);
    });

    test('moving the clock back never makes the wait longer than 15 min',
        () async {
      final lock = await enabled();
      for (var i = 0; i < 5; i++) {
        await lock.checkPin('0000');
      }
      clocks.wall = clocks.wall.subtract(const Duration(days: 2));
      expect(lock.lockoutRemaining, AppLockController.maxLockout);
    });

    test('unreadable storage keeps the app locked (fails closed)', () async {
      await enabled();
      store.failReads = true;
      final restarted = make();
      await restarted.init();
      expect(restarted.status, AppLockStatus.unreadable);
      expect(restarted.blocksApp, isTrue);
      expect((await restarted.unlockWithPin('2468')).ok, isFalse);
    });
  });

  group('auto-lock', () {
    test('locks after the timeout in the background, not before', () async {
      final lock = await enabled(); // default: 1 minute
      lock.handleLifecycle(AppLifecycleState.inactive);
      lock.handleLifecycle(AppLifecycleState.hidden);
      lock.handleLifecycle(AppLifecycleState.paused);
      clocks.pass(const Duration(seconds: 59));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.unlocked);

      lock.handleLifecycle(AppLifecycleState.paused);
      clocks.pass(const Duration(minutes: 1));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.locked);
    });

    test('"Immediately" locks as soon as the app leaves the screen',
        () async {
      final lock = await enabled();
      await lock.setTimeout(Duration.zero);
      lock.handleLifecycle(AppLifecycleState.hidden);
      expect(lock.status, AppLockStatus.locked);
    });

    test('5 minutes', () async {
      final lock = await enabled();
      await lock.setTimeout(const Duration(minutes: 5));
      lock.handleLifecycle(AppLifecycleState.paused);
      clocks.pass(const Duration(minutes: 4));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.unlocked);
      lock.handleLifecycle(AppLifecycleState.paused);
      clocks.pass(const Duration(minutes: 5));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.locked);
    });

    test('system dialogs (inactive only) never lock, even "Immediately"',
        () async {
      final lock = await enabled();
      await lock.setTimeout(Duration.zero);
      lock.handleLifecycle(AppLifecycleState.inactive);
      clocks.pass(const Duration(minutes: 10));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.unlocked);
    });

    test('changing the wall clock does not skip the timeout', () async {
      final lock = await enabled();
      lock.handleLifecycle(AppLifecycleState.paused);
      clocks.mono += const Duration(minutes: 2); // real time passed
      clocks.wall = clocks.wall.subtract(const Duration(hours: 1));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.locked);
    });

    test('nothing happens when App Lock is off', () async {
      final lock = make();
      await lock.init();
      lock.handleLifecycle(AppLifecycleState.paused);
      clocks.pass(const Duration(hours: 1));
      lock.handleLifecycle(AppLifecycleState.resumed);
      expect(lock.status, AppLockStatus.off);
    });

    test('the timeout setting is kept across restarts', () async {
      final lock = await enabled();
      await lock.setTimeout(const Duration(minutes: 5));
      final restarted = make();
      await restarted.init();
      expect(restarted.timeout, const Duration(minutes: 5));
    });
  });

  group('biometrics', () {
    test('not offered when the device has none enrolled', () async {
      final lock = await enabled();
      expect(lock.biometricsAvailable, isFalse);
      expect(await lock.setBiometrics(true), isFalse);
      expect(lock.biometricsEnabled, isFalse);
    });

    test('turning on needs one successful scan', () async {
      bio = FakeBiometrics(succeeds: false);
      final lock = await enabled();
      expect(await lock.setBiometrics(true), isFalse);
      expect(lock.biometricsEnabled, isFalse);

      bio.succeeds = true;
      expect(await lock.setBiometrics(true), isTrue);
      expect(lock.biometricsEnabled, isTrue);
    });

    test('unlocks with a scan; a failed scan leaves the PIN working',
        () async {
      bio = FakeBiometrics();
      final lock = await enabled();
      await lock.setBiometrics(true);
      final restarted = make();
      await restarted.init();

      bio.succeeds = false;
      expect(await restarted.unlockWithBiometrics(), isFalse);
      expect(restarted.status, AppLockStatus.locked);
      expect(restarted.isEnabled, isTrue); // PIN not disabled
      expect((await restarted.unlockWithPin('2468')).ok, isTrue);
    });

    test('if fingerprints are removed later, only the PIN is offered',
        () async {
      bio = FakeBiometrics();
      final lock = await enabled();
      await lock.setBiometrics(true);
      bio.available = false;
      final restarted = make();
      await restarted.init();
      expect(restarted.biometricsEnabled, isFalse);
      expect(await restarted.unlockWithBiometrics(), isFalse);
      expect((await restarted.unlockWithPin('2468')).ok, isTrue);
    });

    test('a successful scan clears wrong-PIN counts', () async {
      bio = FakeBiometrics();
      final lock = await enabled();
      await lock.setBiometrics(true);
      for (var i = 0; i < 5; i++) {
        await lock.checkPin('0000');
      }
      final restarted = make();
      await restarted.init();
      expect(await restarted.unlockWithBiometrics(), isTrue);
      expect(restarted.lockoutRemaining, isNull);
    });
  });

  test('"Forgot PIN" reset clears only the local App Lock', () async {
    final lock = await enabled();
    await lock.resetAfterSignOut();
    expect(lock.status, AppLockStatus.off);
    expect(store.saved, isNull);
  });
}
