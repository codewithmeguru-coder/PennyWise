import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/formatters.dart';

/// Where the privacy choices are kept: on this phone. "Hide savings
/// amounts" ([load]/[save]) plus the named flags of "Hide balances"
/// ([balancesKey], [startHiddenKey]). Null = never chosen.
abstract class SavingsPrivacyStore {
  static const balancesKey = 'privacy.hideBalances';
  static const startHiddenKey = 'privacy.startHidden';

  Future<bool?> load();
  Future<void> save(bool hide);
  Future<bool?> loadFlag(String key);
  Future<void> saveFlag(String key, bool value);
}

class SharedPrefsSavingsPrivacyStore implements SavingsPrivacyStore {
  static const key = 'privacy.hideSavings';

  @override
  Future<bool?> load() => loadFlag(key);

  @override
  Future<void> save(bool hide) => saveFlag(key, hide);

  @override
  Future<bool?> loadFlag(String key) async =>
      (await SharedPreferences.getInstance()).getBool(key);

  @override
  Future<void> saveFlag(String key, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(key, value);
}

/// Kept in memory only (tests). Balances start shown here unless a test
/// says otherwise, so amounts read as before.
class MemorySavingsPrivacyStore implements SavingsPrivacyStore {
  MemorySavingsPrivacyStore([
    this.saved,
    bool? hideBalances = false,
    bool? startHidden = false,
  ]) {
    if (hideBalances != null) flags[SavingsPrivacyStore.balancesKey] = hideBalances;
    if (startHidden != null) flags[SavingsPrivacyStore.startHiddenKey] = startHidden;
  }

  bool? saved;
  final Map<String, bool> flags = {};

  @override
  Future<bool?> load() async => saved;

  @override
  Future<void> save(bool hide) async => saved = hide;

  @override
  Future<bool?> loadFlag(String key) async => flags[key];

  @override
  Future<void> saveFlag(String key, bool value) async => flags[key] = value;
}

/// Keeps amounts out of sight, shown as "KSh ••••". Two levels:
/// - Hide balances: the 👁 in the Home header masks every amount on Home,
///   Accounts, Budgets, Transactions and Trends. The choice is saved; with
///   "Start hidden" on, they hide again at each launch and on leaving.
/// - Hide savings: savings (Ziidi) stay masked even while balances show,
///   until the 👁 by Savings is tapped; they hide again on leaving.
/// Only what is drawn changes; no data does. Reports are not masked.
class SavingsPrivacyController extends ChangeNotifier
    with WidgetsBindingObserver {
  SavingsPrivacyController({SavingsPrivacyStore? store})
    : _store = store ?? SharedPrefsSavingsPrivacyStore();

  final SavingsPrivacyStore _store;

  bool _enabled = true;
  bool _revealed = false;
  bool _balancesHidden = true;
  bool _startHidden = true;

  /// The Settings switch: hide savings amounts at all.
  bool get enabled => _enabled;

  /// Whether savings amounts are masked right now.
  bool get hidden => _balancesHidden || (_enabled && !_revealed);

  /// Whether all balances and amounts are masked right now.
  bool get balancesHidden => _balancesHidden;

  /// The Settings switch: hide balances at each launch and on leaving.
  bool get startHidden => _startHidden;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      final saved = await _store.load();
      if (saved != null) _enabled = saved;
      final start =
          await _store.loadFlag(SavingsPrivacyStore.startHiddenKey);
      if (start != null) _startHidden = start;
      final balances =
          await _store.loadFlag(SavingsPrivacyStore.balancesKey);
      // Start hidden wins at launch; otherwise the last choice stays.
      _balancesHidden = _startHidden || (balances ?? true);
    } catch (_) {}
    notifyListeners();
  }

  /// The 👁 in the Home header: mask or show every amount.
  Future<void> toggleBalances() async {
    _balancesHidden = !_balancesHidden;
    if (!_balancesHidden) _revealed = false;
    notifyListeners();
    try {
      await _store.saveFlag(SavingsPrivacyStore.balancesKey, _balancesHidden);
    } catch (_) {}
  }

  Future<void> setStartHidden(bool value) async {
    _startHidden = value;
    notifyListeners();
    try {
      await _store.saveFlag(SavingsPrivacyStore.startHiddenKey, value);
    } catch (_) {}
  }

  Future<void> setEnabled(bool hide) async {
    _enabled = hide;
    _revealed = false;
    notifyListeners();
    try {
      await _store.save(hide);
    } catch (_) {}
  }

  /// The 👁: show or mask again, until the app is next left.
  void toggle() {
    if (!_enabled || _balancesHidden) return;
    _revealed = !_revealed;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    var changed = false;
    if (_revealed) {
      _revealed = false;
      changed = true;
    }
    if (_startHidden && !_balancesHidden &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden)) {
      _balancesHidden = true;
      changed = true;
      _store
          .saveFlag(SavingsPrivacyStore.balancesKey, true)
          .catchError((_) {});
    }
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static const mask = '${Formatters.currencySymbol} ••••';
}

/// Makes the [SavingsPrivacyController] reachable from any screen.
class SavingsPrivacy extends InheritedNotifier<SavingsPrivacyController> {
  const SavingsPrivacy({
    super.key,
    required SavingsPrivacyController controller,
    required super.child,
  }) : super(notifier: controller);

  static SavingsPrivacyController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SavingsPrivacy>()?.notifier;

  /// True while savings amounts must be masked here.
  static bool hidden(BuildContext context) => maybeOf(context)?.hidden ?? false;

  /// [amount] as "KSh 1,234.00", or "KSh ••••" while hidden.
  static String amount(BuildContext context, double amount) =>
      hidden(context) ? SavingsPrivacyController.mask : Formatters.currency(amount);

  /// True while all balances and amounts must be masked here.
  static bool balancesHidden(BuildContext context) =>
      maybeOf(context)?.balancesHidden ?? false;

  /// Any amount: "KSh 1,234.00", or "KSh ••••" while balances are hidden.
  static String money(BuildContext context, double amount) =>
      balancesHidden(context)
          ? SavingsPrivacyController.mask
          : Formatters.currency(amount);
}
