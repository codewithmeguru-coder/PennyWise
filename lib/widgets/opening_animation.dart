import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A short logo reveal over the app as it opens: the leaf grows in, then
/// the cover fades away (about 0.8 s in all).
///
/// The app underneath starts at the same time, so sign-in, App Lock and
/// data loading are never delayed, and taps pass straight through. Skipped
/// when the phone asks for fewer animations.
class OpeningAnimation extends StatefulWidget {
  const OpeningAnimation({super.key, required this.child});

  final Widget child;

  static const duration = Duration(milliseconds: 800);

  @override
  State<OpeningAnimation> createState() => _OpeningAnimationState();
}

class _OpeningAnimationState extends State<OpeningAnimation>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: OpeningAnimation.duration,
  );
  var _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_done || _controller.isAnimating) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _done = true;
      return;
    }
    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final c = context.colors;
    // 0–70%: the logo grows in. 65–100%: the cover fades out.
    final grow = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
    );
    final fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.65, 1, curve: Curves.easeIn),
    );
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              key: const Key('opening-animation'),
              opacity: ReverseAnimation(fade),
              child: ColoredBox(
                color: c.background,
                child: Center(
                  child: ScaleTransition(
                    scale: Tween(begin: 0.6, end: 1.0).animate(grow),
                    child: FadeTransition(
                      opacity: grow,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: Image.asset(
                          'assets/brand/logo.png',
                          width: 112,
                          height: 112,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
