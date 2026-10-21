import 'package:flutter/material.dart';

import '../security/pin_hasher.dart';
import '../theme/app_theme.dart';

/// Masked PIN: one filled dot per digit entered, empty ones up to the
/// minimum length. The digits themselves are never shown.
class PinDots extends StatelessWidget {
  const PinDots({super.key, required this.length, this.error = false});

  final int length;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final slots = length < PinHasher.minLength ? PinHasher.minLength : length;
    final color = error ? AppColors.expense : AppColors.primary;
    return Semantics(
      label: '$length digits entered',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < slots; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < length ? color : Colors.transparent,
                border: Border.all(color: color, width: 2),
              ),
            ),
        ],
      ),
    );
  }
}

/// Numeric keypad: 1–9, then [bottomLeft] (e.g. the fingerprint button), 0
/// and delete.
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.bottomLeft,
    this.enabled = true,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onDelete;
  final Widget? bottomLeft;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    Widget key(String digit) => _PadButton(
          label: digit,
          onTap: enabled ? () => onDigit(digit) : null,
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [for (final d in row) key(d)],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            SizedBox(width: 72, height: 72, child: bottomLeft),
            key('0'),
            SizedBox(
              width: 72,
              height: 72,
              child: IconButton(
                tooltip: 'Delete',
                onPressed: enabled ? onDelete : null,
                icon: const Icon(Icons.backspace_outlined),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PadButton extends StatelessWidget {
  const _PadButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        width: 72,
        height: 72,
        child: Material(
          color: AppColors.primary.withValues(alpha: 0.08),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: onTap == null
                      ? AppColors.textSecondary
                      : AppColors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Try again in 1 min 20 s".
String formatWait(Duration wait) {
  final seconds = wait.inSeconds + (wait.inMilliseconds % 1000 > 0 ? 1 : 0);
  final m = seconds ~/ 60;
  final s = seconds % 60;
  if (m == 0) return '$s s';
  return s == 0 ? '$m min' : '$m min $s s';
}
