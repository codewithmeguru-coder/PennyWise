import 'package:flutter/material.dart';

import '../screens/lock/lock_screen.dart';
import '../theme/app_theme.dart';
import 'app_lock_controller.dart';

/// Gives the screens below (Settings) access to the [AppLockController].
class AppLockScope extends InheritedNotifier<AppLockController> {
  const AppLockScope({
    super.key,
    required AppLockController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppLockController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLockScope>()?.notifier;
}

/// Wraps the whole app (from `MaterialApp.builder`), above every screen,
/// dialog and route.
///
/// While locked, the app underneath stays alive (so you return to where you
/// were) but is not painted, can't be tapped and is hidden from screen
/// readers; the lock screen is all there is. While App Lock is on and
/// PennyWise isn't in the foreground, a plain cover hides balances (e.g. in
/// the recent-apps screen on Android versions without the native option).
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.controller,
    required this.onForgotPin,
    required this.child,
  });

  final AppLockController controller;
  final Future<void> Function() onForgotPin;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _inForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _inForeground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.handleLifecycle(state);
    final inForeground = state == AppLifecycleState.resumed;
    if (inForeground != _inForeground) {
      setState(() => _inForeground = inForeground);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lock = widget.controller;
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        final hide = lock.blocksApp;
        final cover = !hide && lock.isEnabled && !_inForeground;
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: hide,
              child: TickerMode(enabled: !hide, child: widget.child),
            ),
            if (lock.status == AppLockStatus.loading || cover)
              const _PrivacyCover()
            else if (hide)
              // Its own Overlay, because this sits above the app's Navigator
              // (tooltips and ink need one).
              Overlay(
                key: ValueKey(lock.lockCount),
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => LockScreen(
                      controller: lock,
                      onForgotPin: widget.onForgotPin,
                    ),
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Icon(Icons.lock_rounded, size: 48, color: AppColors.primary),
      ),
    );
  }
}
