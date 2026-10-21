import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../sms/sms_import_service.dart';
import '../theme/app_theme.dart';
import 'user_avatar.dart';

/// The side menu opened from the ☰ button on the main screens.
///
/// It only navigates: each item closes the drawer and calls back into
/// `HomeShell`, which owns the tabs, the Settings route and sign-out.
class AppDrawer extends StatelessWidget {
  const AppDrawer({
    super.key,
    required this.user,
    required this.currentTab,
    required this.smsService,
    required this.onSelectTab,
    required this.onOpenSettings,
    required this.onSignOut,
  });

  final AppUser user;

  /// Index of the bottom-navigation tab that's showing (0 Home,
  /// 1 Transactions, 2 Budgets), so its item is highlighted.
  final int currentTab;

  /// Only read, to show whether automatic detection is on.
  final SmsImportService smsService;

  final ValueChanged<int> onSelectTab;
  final VoidCallback onOpenSettings;
  final VoidCallback onSignOut;

  /// Closes the drawer first, then runs [action], so the new screen or
  /// dialog doesn't open underneath it.
  void _closeThen(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.background,
      child: Column(
        children: [
          _ProfileHeader(user: user),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                _DrawerItem(
                  icon: Icons.home_rounded,
                  label: 'Dashboard',
                  selected: currentTab == 0,
                  onTap: () => _closeThen(context, () => onSelectTab(0)),
                ),
                _DrawerItem(
                  icon: Icons.receipt_long_rounded,
                  label: 'Transactions',
                  selected: currentTab == 1,
                  onTap: () => _closeThen(context, () => onSelectTab(1)),
                ),
                // The Budgets tab is where the monthly report lives: income,
                // expenses, budget used and spending by category.
                _DrawerItem(
                  icon: Icons.bar_chart_rounded,
                  label: 'Reports & Budgets',
                  selected: currentTab == 2,
                  onTap: () => _closeThen(context, () => onSelectTab(2)),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(height: 1),
                ),
                _DrawerItem(
                  icon: Icons.settings_rounded,
                  label: 'Settings',
                  onTap: () => _closeThen(context, onOpenSettings),
                ),
                ListenableBuilder(
                  listenable: smsService,
                  builder: (context, _) => _DrawerItem(
                    icon: Icons.sms_rounded,
                    label: 'Automatic Detection',
                    trailing: _StatusPill(
                      text: !smsService.isSupported
                          ? 'Android'
                          : smsService.isActive
                              ? 'On'
                              : 'Off',
                      active: smsService.isActive,
                    ),
                    onTap: () => _closeThen(context, onOpenSettings),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _DrawerItem(
                icon: Icons.logout_rounded,
                label: 'Log out',
                color: AppColors.expense,
                onTap: () => _closeThen(context, onSignOut),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Green header with the signed-in user's picture, name and email, in the
/// same style as the dashboard's balance card.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final name = user.displayName?.trim() ?? '';
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UserAvatar(user: user, radius: 30, onDark: true),
              const SizedBox(height: 14),
              Text(
                name.isNotEmpty ? name : 'PennyWise user',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                user.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.trailing,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final Widget? trailing;

  /// Overrides the icon/text colour (e.g. red for Log out).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground =
        color ?? (selected ? AppColors.primary : AppColors.textPrimary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        onTap: onTap,
        selected: selected,
        selectedTileColor: AppColors.primary.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(icon, color: foreground),
        title: Text(
          label,
          style: TextStyle(
            color: foreground,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
        trailing: trailing,
      ),
    );
  }
}

/// Small "On" / "Off" label next to Automatic Detection.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.active});

  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.primary : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
