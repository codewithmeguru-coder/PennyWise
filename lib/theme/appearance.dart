import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the Light / Dark / System choice is kept. It belongs to this phone,
/// not to a profile, and survives restarts and app updates.
abstract class AppearanceStore {
  Future<ThemeMode?> load();
  Future<void> save(ThemeMode mode);
}

class SharedPrefsAppearanceStore implements AppearanceStore {
  static const key = 'appearance.themeMode';

  @override
  Future<ThemeMode?> load() async {
    final name = (await SharedPreferences.getInstance()).getString(key);
    return ThemeMode.values.where((m) => m.name == name).firstOrNull;
  }

  @override
  Future<void> save(ThemeMode mode) async =>
      (await SharedPreferences.getInstance()).setString(key, mode.name);
}

/// Kept in memory only (tests).
class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.saved]);

  ThemeMode? saved;

  @override
  Future<ThemeMode?> load() async => saved;

  @override
  Future<void> save(ThemeMode mode) async => saved = mode;
}

/// The app's [ThemeMode]: follows the phone until the user picks Light or
/// Dark in Settings.
class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController({AppearanceStore? store})
    : _store = store ?? SharedPrefsAppearanceStore(),
      super(ThemeMode.system);

  final AppearanceStore _store;

  /// Reads the saved choice. Anything unreadable leaves System Default.
  Future<void> init() async {
    try {
      final saved = await _store.load();
      if (saved != null) value = saved;
    } catch (_) {}
  }

  /// Applies [mode] at once, then saves it.
  Future<void> choose(ThemeMode mode) async {
    value = mode;
    try {
      await _store.save(mode);
    } catch (_) {}
  }

  static String label(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'System default',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}

/// Makes the [AppearanceController] reachable from Settings.
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
