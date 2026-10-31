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

  /// Transaction messages PennyWise did not import, by reason, as
  /// {reason: number of distinct messages}. Only codes are kept, never the
  /// message text, and only on this phone.
  Future<Map<SkipReason, int>> skippedCounts();

  /// The codes behind [skippedCounts], leaving out any handled since
  /// (e.g. brought in by Settings › Fuliza history).
  Future<Map<SkipReason, Set<String>>> skippedKeys();

  /// Records that the message with [key] was skipped for [reason]. Recording
  /// the same key twice counts it once.
  Future<void> recordSkipped(SkipReason reason, String key);

  /// Ids of the transactions created by the Fuliza history import in this
  /// profile, so Undo removes exactly those (see `FulizaImporter`).
  Future<List<String>> fulizaImportIds();
  Future<void> setFulizaImportIds(List<String> ids);

  /// Whether Fuliza loans and repayments from new messages are saved
  /// automatically. Off unless the user turns it on in Settings: installing
  /// or opening the app never starts it.
  Future<bool> autoFulizaImport();
  Future<void> setAutoFulizaImport(bool on);
}

/// Why a transaction message was not imported.
enum SkipReason {
  /// Looks like a completed transaction, but its wording isn't one PennyWise
  /// can read yet.
  unreadable,

  /// A Fuliza loan or repayment read while "Import Fuliza automatically"
  /// was off. Not marked as handled, so Settings › Fuliza history can still
  /// bring it in.
  fulizaWaiting,

  /// A Fuliza loan or repayment read with automatic import on, but its
  /// SIM's M-Pesa or Fuliza account isn't set up, so it is held rather
  /// than recorded wrongly.
  fulizaNoAccount,
}

/// [SmsSettings] in SharedPreferences, with keys scoped to one user id.
class SharedPrefsSmsSettings implements SmsSettings {
  SharedPrefsSmsSettings({required String uid}) : _prefix = 'sms_${uid}_';

  final String _prefix;

  /// Only the most recent keys are kept; older SMS are far behind
  /// [lastScan] and won't be read again anyway. Room for a Fuliza history
  /// import on top of the usual messages.
  static const _maxHandledKeys = 2000;

  /// Most recent skipped codes kept per reason.
  static const _maxSkipped = 300;

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

  @override
  Future<List<String>> fulizaImportIds() async =>
      (await _prefs).getStringList('${_prefix}fuliza_import') ?? const [];

  @override
  Future<void> setFulizaImportIds(List<String> ids) async =>
      (await _prefs).setStringList('${_prefix}fuliza_import', ids);

  @override
  Future<bool> autoFulizaImport() async {
    // Only an explicit `true` saved by the switch turns it on; a missing or
    // unreadable value is off.
    try {
      return (await _prefs).get('${_prefix}auto_fuliza') == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> setAutoFulizaImport(bool on) async =>
      (await _prefs).setBool('${_prefix}auto_fuliza', on);

  @override
  Future<Map<SkipReason, int>> skippedCounts() async {
    final prefs = await _prefs;
    return {
      for (final r in SkipReason.values)
        r: (prefs.getStringList('${_prefix}skipped_${r.name}') ?? const [])
            .length,
    };
  }

  @override
  Future<Map<SkipReason, Set<String>>> skippedKeys() async {
    final prefs = await _prefs;
    final handled = await handledKeys();
    return {
      for (final r in SkipReason.values)
        r: {
          for (final k
              in prefs.getStringList('${_prefix}skipped_${r.name}') ?? const [])
            if (!handled.contains(k)) k,
        },
    };
  }

  @override
  Future<void> recordSkipped(SkipReason reason, String key) async {
    final prefs = await _prefs;
    final name = '${_prefix}skipped_${reason.name}';
    final keys = prefs.getStringList(name) ?? <String>[];
    if (keys.contains(key)) return;
    keys.add(key);
    if (keys.length > _maxSkipped) {
      keys.removeRange(0, keys.length - _maxSkipped);
    }
    await prefs.setStringList(name, keys);
  }
}
