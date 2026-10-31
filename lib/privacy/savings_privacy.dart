import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/formatters.dart';

/// Where "Hide savings amounts" is kept: on this phone, on by default.
abstract class SavingsPrivacyStore {
  Future<bool?> load();
  Future<void> save(bool hide);
}

class SharedPrefsSavingsPrivacyStore implements SavingsPrivacyStore {
  static const key = 'privacy.hideSavings';

  @override
  Future<bool?> load() async =>
      (await SharedPreferences.getInstance()).getBool(key);

  @override
  Future<void> save(bool hide) async =>
      (await SharedPreferences.getInstance()).setBool(key, hide);
}

/// Kept in memory only (tests).
class MemorySavingsPrivacyStore implements SavingsPrivacyStore {
  MemorySavingsPrivacyStore([this.saved]);

  bool? saved;

  @override
  Future<bool?> load() async => saved;

  @override
  Future<void> save(bool hide) async => saved = hide;
}

/// Keeps savings (Ziidi) amounts out of sight: shown as "KSh ••••" until
/// the 👁 on Home is tapped. They hide again whenever the app goes to the
/// background or restarts. Only what is drawn changes; no data does.
class SavingsPrivacyController extends ChangeNotifier
    with WidgetsBindingObserver {
  SavingsPrivacyController({SavingsPrivacyStore? store})
    : _store = store ?? SharedPrefsSavingsPrivacyStore();

  final SavingsPrivacyStore _store;

  bool _enabled = true;
  bool _revealed = false;

  /// The Settings switch: hide savings amounts at all.
  bool get enabled => _enabled;

  /// Whether savings amounts are masked right now.
  bool get hidden => _enabled && !_revealed;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      final saved = await _store.load();
      if (saved != null && saved != _enabled) {
        _enabled = saved;
        notifyListeners();
      }
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
    if (!_enabled) return;
    _revealed = !_revealed;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _revealed) {
      _revealed = false;
      notifyListeners();
    }
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
}
