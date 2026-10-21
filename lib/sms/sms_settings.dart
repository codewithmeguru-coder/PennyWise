import 'package:shared_preferences/shared_preferences.dart';

/// Per-device, per-user settings for automatic transaction detection.
///
/// Stored on the phone (not in Firestore) because SMS access is a property
/// of this device: turning it on here shouldn't turn it on for the same
/// account on another phone or on the web.
abstract class SmsSettings {
  Future<bool> isEnabled();
  Future<void> setEnabled(bool enabled);

  /// Messages received after this time haven't been scanned yet.
  /// Null if detection has never run for this user on this device.
  Future<DateTime?> lastScan();
  Future<void> setLastScan(DateTime time);

  /// Dedupe keys this device has already handled (saved, found to be a
  /// duplicate, or deleted afterwards by the user). A cheap first check that
  /// also stops a transaction the user deleted from being re-created by a
  /// later "scan recent messages".
  Future<Set<String>> handledKeys();
  Future<void> addHandledKey(String key);
}

/// [SmsSettings] in SharedPreferences, with keys scoped to one user id.
class SharedPrefsSmsSettings implements SmsSettings {
  SharedPrefsSmsSettings({required String uid}) : _prefix = 'sms_${uid}_';

  final String _prefix;

  /// Only the most recent keys are kept; older SMS are far behind
  /// [lastScan] and won't be read again anyway.
  static const _maxHandledKeys = 500;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<bool> isEnabled() async =>
      (await _prefs).getBool('${_prefix}enabled') ?? false;

  @override
  Future<void> setEnabled(bool enabled) async =>
      (await _prefs).setBool('${_prefix}enabled', enabled);

  @override
  Future<DateTime?> lastScan() async {
    final millis = (await _prefs).getInt('${_prefix}lastScan');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  @override
  Future<void> setLastScan(DateTime time) async =>
      (await _prefs).setInt('${_prefix}lastScan', time.millisecondsSinceEpoch);

  @override
  Future<Set<String>> handledKeys() async =>
      ((await _prefs).getStringList('${_prefix}handled') ?? const []).toSet();

  @override
  Future<void> addHandledKey(String key) async {
    final prefs = await _prefs;
    final keys = prefs.getStringList('${_prefix}handled') ?? <String>[];
    if (keys.contains(key)) return;
    keys.add(key);
    if (keys.length > _maxHandledKeys) {
      keys.removeRange(0, keys.length - _maxHandledKeys);
    }
    await prefs.setStringList('${_prefix}handled', keys);
  }
}
