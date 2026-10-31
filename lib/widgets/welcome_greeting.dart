import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/avatar_store.dart';
import '../theme/app_theme.dart';
import 'user_avatar.dart';

/// "Good evening, Ann" beside the user's photo, for the top of Home.
///
/// The photo is the one uploaded in Settings, else the Google photo, else
/// the first letter (see [UserAvatar]). While the uploaded photo loads, or
/// if it can't, the Google photo or letter shows instead. Without a name
/// it says "Welcome back".
class WelcomeGreeting extends StatelessWidget {
  const WelcomeGreeting({
    super.key,
    required this.user,
    this.avatar,
    this.now,
    this.subtitle,
  });

  final AppUser user;

  /// The signed-in user's own uploaded photo, if any.
  final AvatarStore? avatar;

  /// The clock, so tests can pick the time of day.
  final DateTime Function()? now;

  /// Shown under the greeting (Home: the month on show).
  final Widget? subtitle;

  /// The first word of the profile name, or null when there is none.
  static String? firstName(AppUser user) {
    final name = user.displayName?.trim() ?? '';
    if (name.isEmpty) return null;
    return name.split(RegExp(r'\s+')).first;
  }

  static String partOfDay(DateTime time) => time.hour < 12
      ? 'Good morning'
      : time.hour < 17
      ? 'Good afternoon'
      : 'Good evening';

  static String text(AppUser user, DateTime time) => switch (firstName(user)) {
    final name? => '${partOfDay(time)}, $name',
    null => 'Welcome back',
  };

  @override
  Widget build(BuildContext context) {
    final store = avatar;
    return Row(
      children: [
        if (store == null)
          UserAvatar(user: user, radius: 16)
        else
          ListenableBuilder(
            listenable: store,
            builder: (context, _) =>
                UserAvatar(user: user, radius: 16, customImage: store.photo),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                text(user, (now ?? DateTime.now)()),
                key: const Key('home-greeting'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: context.colors.textPrimary,
                ),
              ),
              ?subtitle,
            ],
          ),
        ),
      ],
    );
  }
}
