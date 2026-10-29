import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// The user's own photo ([customImage]) if they added one, else their
/// Google profile picture, else the first letter of their name (or email).
/// A photo that can't be shown leaves the letter visible.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.user,
    this.radius = 22,
    this.onDark = false,
    this.customImage,
  });

  final AppUser user;

  /// The photo the user added in Settings › Profile (JPEG, PNG or WebP).
  final Uint8List? customImage;
  final double radius;

  /// True when shown on the green header (white circle instead of tinted).
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final name = user.displayName?.trim() ?? '';
    final label = name.isNotEmpty ? name : user.email;
    final initial = label.isEmpty ? '?' : label.characters.first;
    final photoUrl = user.photoUrl;
    final ImageProvider? image = customImage != null
        ? MemoryImage(customImage!)
        : photoUrl == null
            ? null
            : NetworkImage(photoUrl);

    return CircleAvatar(
      radius: radius,
      backgroundColor: onDark
          ? Colors.white
          : context.colors.primary.withValues(alpha: 0.1),
      foregroundImage: image,
      // A broken or unreachable photo: the letter underneath stays visible.
      onForegroundImageError: image == null ? null : (_, _) {},
      child: Text(
        initial.toUpperCase(),
        style: TextStyle(
          color: context.colors.primary,
          fontWeight: FontWeight.w700,
          // Larger avatars (the drawer header) get a larger letter.
          fontSize: radius > 22 ? radius * 0.75 : null,
        ),
      ),
    );
  }
}
