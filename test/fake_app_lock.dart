import 'package:pennywise/security/app_lock_controller.dart';
import 'package:pennywise/security/app_lock_store.dart';
import 'package:pennywise/security/device_security.dart';
import 'package:pennywise/security/pin_hasher.dart';

/// In-memory [AppLockStore]. Keeps the JSON form, like secure storage, so a
/// second controller reading it behaves like an app restart.
class MemoryAppLockStore implements AppLockStore {
  Map<String, Object?>? saved;
  bool failReads = false;

  @override
  Future<AppLockConfig?> read() async {
    if (failReads) throw Exception('cannot decrypt');
    final json = saved;
    return json == null
        ? null
        : AppLockConfig.fromJson(Map<String, dynamic>.from(
            // Round-trip nested maps like jsonDecode would.
            json.map((k, v) => MapEntry(k, v is Map ? Map<String, dynamic>.from(v) : v))));
  }

  @override
  Future<void> write(AppLockConfig config) async => saved = config.toJson();

  @override
  Future<void> clear() async => saved = null;
}

class FakeBiometrics implements BiometricAuth {
  FakeBiometrics({this.available = true, this.succeeds = true});

  bool available;
  bool succeeds;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return available && succeeds;
  }
}

class FakePrivacy extends DevicePrivacy {
  FakePrivacy();

  bool? hidden;

  @override
  Future<void> hideRecentsPreview(bool hide) async => hidden = hide;

  @override
  Future<int> androidSdk() async => 36;
}

/// Fast hashing for tests (real PBKDF2, few rounds, no isolate).
const testHasher = PinHasher(iterations: 10, runInBackground: false);

/// A controller with fake storage, biometrics and clocks.
AppLockController testAppLock({
  MemoryAppLockStore? store,
  FakeBiometrics? biometrics,
  FakePrivacy? privacy,
  DateTime Function()? now,
  Duration Function()? elapsed,
}) =>
    AppLockController(
      store: store ?? MemoryAppLockStore(),
      hasher: testHasher,
      biometrics: biometrics ?? FakeBiometrics(available: false),
      privacy: privacy ?? FakePrivacy(),
      now: now,
      elapsed: elapsed,
    );
