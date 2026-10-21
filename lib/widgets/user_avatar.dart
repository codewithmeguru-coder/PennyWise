import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// The user's Google profile picture, or the first letter of their name
/// (or email) for email/password accounts.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.user,
    this.radius = 22,
    this.onDark = false,
  });

  final AppUser user;
  final double radius;

  /// True when shown on the green header (white circle instead of tinted).
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final name = user.displayName?.trim() ?? '';
    final label = name.isNotEmpty ? name : user.email;
    final initial = label.isEmpty ? '?' : label.characters.first;
    final photoUrl = user.photoUrl;

    return CircleAvatar(
      radius: radius,
      backgroundColor: onDark
          ? Colors.white
          : AppColors.primary.withValues(alpha: 0.1),
      foregroundImage: photoUrl == null ? null : NetworkImage(photoUrl),
      child: Text(
        initial.toUpperCase(),
        style: TextStyle(
          color: AppColors.primary,
          fontWeight: FontWeight.w700,
          // Larger avatars (the drawer header) get a larger letter.
          fontSize: radius > 22 ? radius * 0.75 : null,
        ),
      ),
    );
  }
}
