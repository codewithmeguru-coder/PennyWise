import 'package:flutter/material.dart';

import '../accounts/money_account.dart';
import '../categorization/category_registry.dart';
import '../categorization/category_rule_repository.dart';
import '../data/transaction_store.dart';
import '../security/app_lock_gate.dart';
import '../services/auth_service.dart';
import '../services/avatar_store.dart';
import '../services/photo_picker.dart';
import '../widgets/user_avatar.dart';
import '../maintenance/internal_transfer_fix.dart';
import '../maintenance/ziidi_fix.dart';
import '../sms/fuliza_import.dart';
import '../sms/sms_gateway.dart';
import '../sms/sms_import_service.dart';
import '../models/transaction_model.dart';
import '../privacy/savings_privacy.dart';
import '../theme/app_theme.dart';
import '../theme/appearance.dart';
import '../utils/formatters.dart';
import 'app_lock_settings_screen.dart';
import 'categories_screen.dart';
import 'estimated_amounts_screen.dart';
import 'fuliza_import_screen.dart';
import 'fuliza_report_screen.dart';
import 'move_fix_screen.dart';
import 'ziidi_fix_screen.dart';
import 'learned_categories_screen.dart';

/// App settings: App Lock and the "Automatic Transaction Detection" switch.
///
/// SMS permission is never requested silently: turning the switch on first
/// explains what PennyWise reads and why, and only asks Android for the
/// permission if the user chooses to continue.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.smsService,
    this.categoryRules,
    this.categories,
    this.fulizaImporter,
    this.ziidiFixer,
    this.moveFix,
    this.transactions,
    this.accounts = const [],
    this.user,
    this.avatar,
    this.photoPicker,
    this.onOpenAccounts,
    this.showRepairTools = false,
  });

  /// The one-off repair tools (Fix old Ziidi records, Fix moves between
  /// your accounts) are listed only for profiles that can need them (see
  /// `RepairTools`). Notes that point to a tool still open it.
  final bool showRepairTools;

  final SmsImportService smsService;

  /// Opens Accounts (from notes that need an account added first).
  final VoidCallback? onOpenAccounts;

  /// Categories learned from corrections; null hides that section.
  final CategoryRuleStore? categoryRules;

  /// The user's own categories; null hides "Categories".
  final CategoryRegistry? categories;

  /// The Fuliza history import; null hides its entry.
  final FulizaImporter? fulizaImporter;

  /// Fix old Ziidi records; null hides its entry.
  final ZiidiFixer? ziidiFixer;

  /// Fix moves between the user's SIMs; null hides its entry.
  final MoveFix? moveFix;

  /// Saved transactions, for the Fuliza fee report; null hides its entry.
  final TransactionStore? transactions;

  /// The user's accounts, so the report can tell each Fuliza's SIM.
  final List<MoneyAccount> accounts;

  /// The signed-in user and their own photo; both needed for "Profile".
  final AppUser? user;
  final AvatarStore? avatar;
  final PhotoPicker? photoPicker;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  SmsImportService get _sms => widget.smsService;

  /// Automatic Fuliza import; null while loading. Off by default.
  bool? _autoFuliza;

  Future<void> _setAutoFuliza(bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import Fuliza automatically?'),
          content: const Text(
              'From now on, each new Fuliza loan and repayment message is '
              'saved as it arrives: a loan as money moved from that SIM\'s '
              'Fuliza into its M-Pesa (its access fee counts as spending), a '
              'repayment as money moved back. A message already saved is '
              'never saved again, and one whose SIM or accounts are unknown '
              'is held. Older messages are only brought in from Fuliza '
              'history, after a preview.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Turn on'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _sms.setAutoFulizaImport(on);
    if (mounted) setState(() => _autoFuliza = on);
  }

  @override
  void initState() {
    super.initState();
    _sms.autoFulizaImport().then((on) {
      if (mounted) setState(() => _autoFuliza = on);
    });
    // Android may have closed the app while the photo picker was open
    // (low memory): save the photo chosen then, if there was one.
    if ((widget.avatar, widget.photoPicker) case (final a?, final p?)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final message = await a.recover(p);
        if (message != null && mounted) _showMessage(message);
      });
    }
  }

  Future<void> _changePhoto(AvatarStore avatar, PhotoPicker picker) async {
    final message = await avatar.change(picker);
    if (message != null && mounted) _showMessage(message);
  }

  Future<void> _removePhoto(AvatarStore avatar) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove your photo?'),
        content: const Text('Your Google photo or your initial will show '
            'instead.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final message = await avatar.remove();
    if (message != null && mounted) _showMessage(message);
  }

  Widget _profileCard(AppUser user, AvatarStore avatar, PhotoPicker picker) {
    return ListenableBuilder(
      listenable: avatar,
      builder: (context, _) {
        final name = user.displayName?.trim() ?? '';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                UserAvatar(user: user, radius: 30, customImage: avatar.photo),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isNotEmpty ? name : user.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (avatar.error != null)
                        Text(
                          'Couldn\'t load your photo. ${avatar.error!}',
                          style: TextStyle(
                              fontSize: 12, color: context.colors.textSecondary),
                        ),
                      Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: avatar.isBusy
                                ? null
                                : () => _changePhoto(avatar, picker),
                            child: Text(avatar.photo == null
                                ? 'Add photo'
                                : 'Change photo'),
                          ),
                          if (avatar.photo != null)
                            TextButton(
                              onPressed: avatar.isBusy
                                  ? null
                                  : () => _removePhoto(avatar),
                              child: const Text('Remove photo'),
                            ),
                          if (avatar.isBusy)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _onToggle(bool turnOn) async {
    setState(() => _busy = true);
    try {
      if (turnOn) {
        await _turnOn();
      } else {
        await _sms.disable();
        _showMessage('Automatic detection is off. PennyWise no longer reads '
            'your SMS. You can also remove the SMS permission in Android '
            'Settings.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOn() async {
    if (!_sms.hasPermission) {
      // 1. Explain first.
      final agreed = await showDialog<bool>(
        context: context,
        builder: (_) => const _PermissionExplanationDialog(),
      );
      if (agreed != true || !mounted) return;

      // 2. Then let Android ask.
      final status = await _sms.requestPermission();
      if (!mounted) return;
      switch (status) {
        case SmsPermissionStatus.granted:
          break;
        case SmsPermissionStatus.denied:
          _showMessage('SMS permission was not given, so automatic detection '
              'stays off. You can still add transactions manually.');
          return;
        case SmsPermissionStatus.permanentlyDenied:
          await _showBlockedDialog();
          return;
      }
    }
    await _sms.enable();
    if (!mounted) return;
    // Detection only picks up messages from now on; offer the backlog (for
    // example after reinstalling PennyWise). Duplicates are skipped.
    final importOld = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Also import the last 30 days?'),
        content: const Text(
            'Detection is on and will add new M-Pesa and Airtel Money '
            'transactions from now on. PennyWise can also add the ones from '
            'your messages of the last 30 days. Anything already in '
            'PennyWise is skipped, so nothing is added twice.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (importOld == true) {
      await _scanRecent();
    } else {
      _showMessage('Automatic detection is on. New M-Pesa and Airtel Money '
          'transactions will be added when you open PennyWise.');
    }
  }

  /// Android won't show its dialog again; only the Settings app can help.
  Future<void> _showBlockedDialog() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SMS permission is blocked'),
        content: const Text(
          'Android won\'t ask again. To use automatic detection, open '
          'Settings › Permissions › SMS and choose "Allow".\n\n'
          'If the option is greyed out, the app was installed from a file: '
          'open App info, tap ⋮ (top right), choose "Allow restricted '
          'settings", then try again.\n\n'
          'Everything else in PennyWise, including adding transactions '
          'manually, works without it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    if (open == true) await _sms.openAppSettings();
  }

  Future<void> _scanRecent() async {
    final added = await _sms.scanRecent(days: 30);
    if (!mounted) return;
    final error = _sms.lastError;
    _showMessage(error ??
        (added == 0
            ? 'No new transactions found in the last 30 days.'
            : 'Added $added transaction${added == 1 ? '' : 's'} from the '
                'last 30 days.'));
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: _sms,
        builder: (context, _) {
          final supported = _sms.isSupported;
          final enabled = _sms.isEnabled;
          final permissionMissing = supported && enabled && !_sms.hasPermission;

          final appLock = AppLockScope.maybeOf(context);
          final appearance = AppearanceScope.maybeOf(context);
          final privacy = SavingsPrivacy.maybeOf(context);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if ((widget.user, widget.avatar, widget.photoPicker)
                  case (final user?, final avatar?, final picker?)) ...[
                _profileCard(user, avatar, picker),
                const SizedBox(height: 12),
              ],
              if (appLock != null) ...[
                Card(
                  child: ListTile(
                    leading: Icon(Icons.lock_outline_rounded,
                        color: context.colors.primary),
                    title: const Text(
                      'App Lock',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(appLock.isEnabled
                        ? 'On · ${AppLockSettingsScreen.timeoutLabel(appLock.timeout).toLowerCase()}'
                        : 'Off · protect PennyWise with a PIN'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            AppLockSettingsScreen(controller: appLock))),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (widget.categories case final registry?) ...[
                Card(
                  child: ListTile(
                    leading: Icon(Icons.category_outlined,
                        color: context.colors.primary),
                    title: const Text('Categories'),
                    subtitle: const Text('Add your own, rename or turn them '
                        'off'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CategoriesScreen(
                          registry: registry,
                          transactions: widget.transactions,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (widget.categoryRules case final rules?) ...[
                Card(
                  child: ListTile(
                    leading: Icon(Icons.auto_awesome_outlined,
                        color: context.colors.primary),
                    title: const Text(
                      'Learned categories',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                        'Categories PennyWise remembers from your changes'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            LearnedCategoriesScreen(rules: rules))),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Card(
                child: SwitchListTile(
                  title: const Text(
                    'Automatic Transaction Detection',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(supported
                      ? 'Add M-Pesa and Airtel Money transactions from '
                          'their SMS automatically. PennyWise checks your '
                          "messages when you open it; it doesn't run in the "
                          'background.'
                      : 'Available in the Android app only.'),
                  value: supported && enabled,
                  onChanged: !supported || _busy ? null : _onToggle,
                ),
              ),
              if (permissionMissing) ...[
                const SizedBox(height: 12),
                _Notice(
                  icon: Icons.warning_amber_rounded,
                  color: context.colors.warning,
                  text: 'Detection is on, but PennyWise no longer has SMS '
                      'permission, so nothing is being detected. Allow SMS '
                      'access in Settings, or turn detection off.',
                  actionLabel: 'Open settings',
                  onAction: _sms.openAppSettings,
                ),
              ],
              if (_sms.isActive) ...[
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: const Text('Import last 30 days'),
                        subtitle: const Text(
                            'Add transactions from older M-Pesa / Airtel '
                            'messages. Duplicates are skipped.'),
                        trailing: _sms.isScanning
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : null,
                        onTap: _sms.isScanning ? null : _scanRecent,
                      ),
                      if (widget.ziidiFixer case final fixer?
                          when widget.showRepairTools)
                        ListTile(
                          leading: const Icon(Icons.savings_outlined),
                          title: const Text('Fix old Ziidi records'),
                          subtitle: const Text('See which older records are '
                              'Ziidi savings, then choose whether to fix '
                              'them.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ZiidiFixScreen(fixer: fixer),
                            ),
                          ),
                        ),
                      if (widget.moveFix case final fix?
                          when widget.showRepairTools)
                        ListTile(
                          leading: const Icon(Icons.swap_horiz_rounded),
                          title: const Text(
                            'Fix moves between your accounts',
                          ),
                          subtitle: const Text('See which records are money '
                              'moved between your own SIMs, into Equity or '
                              'withdrawn as cash, then choose whether to fix '
                              'them.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => MoveFixScreen(fix: fix),
                            ),
                          ),
                        ),
                      if (widget.fulizaImporter != null)
                        SwitchListTile(
                          secondary: const Icon(Icons.autorenew_rounded),
                          title: const Text('Import Fuliza automatically'),
                          subtitle: Text(_autoFuliza == true
                              ? 'On: new Fuliza messages are saved as they '
                                  'arrive.'
                              : 'Off: new Fuliza messages wait until you '
                                  'import them from Fuliza history.'),
                          value: _autoFuliza ?? false,
                          onChanged: _autoFuliza == null ? null : _setAutoFuliza,
                        ),
                      if (widget.fulizaImporter case final importer?)
                        ListTile(
                          leading: const Icon(Icons.credit_score_rounded),
                          title: const Text('Fuliza history'),
                          subtitle: const Text('See Fuliza loans and '
                              'repayments, then choose whether to import '
                              'them.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  FulizaImportScreen(
                                importer: importer,
                                accounts: () => widget.accounts,
                                transactions: () =>
                                    widget.transactions?.transactions ??
                                    const [],
                              ),
                            ),
                          ),
                        ),
                      if (widget.transactions case final store?)
                        ListTile(
                          leading: const Icon(Icons.bar_chart_rounded),
                          title: const Text('Fuliza fee report'),
                          subtitle: const Text('Fees, loans, repayments and '
                              'what is owed, per SIM.'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => FulizaReportScreen(
                                  store: store, accounts: widget.accounts),
                            ),
                          ),
                        ),
                      if (_sms.lastScan != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Last checked: '
                              '${Formatters.relativeDate(_sms.lastScan!)} at '
                              '${_time(_sms.lastScan!)}',
                              style: TextStyle(
                                color: context.colors.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              // Each note has a button to where it can be dealt with.
              for (final (text, label, onTap) in _heldNotes(context)) ...[
                const SizedBox(height: 12),
                _Notice(
                  icon: Icons.info_outline_rounded,
                  color: context.colors.textSecondary,
                  text: text,
                  actionLabel: label,
                  onAction: onTap,
                ),
              ],
              if (_sms.lastError != null) ...[
                const SizedBox(height: 12),
                _Notice(
                  icon: Icons.cloud_off_rounded,
                  color: context.colors.expense,
                  text: '${_sms.lastError} PennyWise will try again next '
                      'time you open the app.',
                ),
              ],
              if (appearance != null) ...[
                const SizedBox(height: 12),
                _AppearanceCard(controller: appearance),
              ],
              if (privacy != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: SwitchListTile(
                    key: const Key('hide-savings-switch'),
                    secondary: Icon(
                      Icons.visibility_off_outlined,
                      color: context.colors.primary,
                    ),
                    title: const Text(
                      'Hide savings amounts',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      'Ziidi and other savings show as KSh •••• until you '
                      'tap the eye on Home. They hide again when you leave '
                      'the app.',
                    ),
                    value: privacy.enabled,
                    onChanged: privacy.setEnabled,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              const _HowItWorks(),
            ],
          );
        },
      ),
    );
  }

  /// Held Fuliza messages that are still missing: any already saved (for
  /// example by an earlier Fuliza history import) aren't counted.
  int _heldFuliza(SkipReason reason) {
    final keys = _sms.skippedKeys[reason] ?? const <String>{};
    if (keys.isEmpty) return 0;
    final saved = {
      for (final t in widget.transactions?.transactions ?? const []) t.id,
    };
    return keys.where((k) => !saved.contains(k)).length;
  }

  void _push(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  /// Messages read but not added, and estimated amounts to check: each with
  /// the button that opens where to deal with it.
  List<(String, String?, VoidCallback?)> _heldNotes(BuildContext context) {
    final store = widget.transactions;
    final estimated = store == null
        ? 0
        : EstimatedAmountsScreen.pending(store.transactions).length;
    final active = _sms.isActive;
    int held(SkipReason r) => active ? _heldFuliza(r) : 0;
    final fuliza = widget.fulizaImporter;
    final fix = widget.moveFix;
    final accounts = widget.onOpenAccounts;
    String one(int noAccount, int foreign, int topUps) => equityHeldTexts(
      noAccount: noAccount,
      foreignCurrency: foreign,
      topUps: topUps,
    ).single;
    final unreadable = active ? (_sms.skipped[SkipReason.unreadable] ?? 0) : 0;
    final topUps = active ? _topUpsToFix() : 0;
    return [
      if (estimated > 0 && store != null)
        (
          estimatedText(estimated),
          'Check amounts',
          () => _push(EstimatedAmountsScreen(store: store)),
        ),
      if (held(SkipReason.fulizaWaiting) > 0)
        (
          fulizaHeldText(held(SkipReason.fulizaWaiting), noAccount: false),
          fuliza == null ? null : 'Open Fuliza history',
          fuliza == null
              ? null
              : () => _push(
                  FulizaImportScreen(
                    importer: fuliza,
                    accounts: () => widget.accounts,
                    transactions: () => store?.transactions ?? const [],
                  ),
                ),
        ),
      if (held(SkipReason.fulizaNoAccount) > 0)
        (
          fulizaHeldText(held(SkipReason.fulizaNoAccount), noAccount: true),
          accounts == null ? null : 'Open Accounts',
          accounts,
        ),
      if (held(SkipReason.bankNoAccount) > 0)
        (
          one(held(SkipReason.bankNoAccount), 0, 0),
          accounts == null ? null : 'Open Accounts',
          accounts,
        ),
      if (held(SkipReason.foreignCurrency) > 0)
        (one(0, held(SkipReason.foreignCurrency), 0), null, null),
      if (topUps > 0)
        (
          one(0, 0, topUps),
          fix == null ? null : 'Open Fix moves',
          fix == null ? null : () => _push(MoveFixScreen(fix: fix)),
        ),
      if (unreadable > 0)
        (
          "$unreadable transaction messages are in a format PennyWise can't "
              'read yet. Add them by hand if needed.',
          null,
          null,
        ),
    ];
  }

  /// Top-ups into Equity whose M-Pesa record still counts as spending
  /// (Fix moves between your accounts turns those into moves).
  int _topUpsToFix() {
    final keys = _sms.skippedKeys[SkipReason.bankTopUp] ?? const <String>{};
    if (keys.isEmpty) return 0;
    final byId = {
      for (final t in widget.transactions?.transactions ?? const []) t.id: t,
    };
    return keys.where((k) {
      final code = k.substring(k.indexOf('_') + 1);
      final t = byId['mpesa_$code'] ?? byId['airtel_$code'];
      return t != null && t.type == TransactionType.expense;
    }).length;
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// Why Fuliza messages were read but not saved: read while automatic
/// import was off, or (with it on) their SIM's account isn't set up.
String fulizaHeldText(int count, {required bool noAccount}) {
  final messages = count == 1 ? '1 Fuliza message was' : '$count Fuliza '
      'messages were';
  return noAccount
      ? "$messages read but not added yet: that SIM's M-Pesa or Fuliza "
            "account isn't set up. They'll be added once it is."
      : '$messages read while "Import Fuliza automatically" was off, so '
            "they weren't added. To add them, use Fuliza history; any "
            'already saved are skipped.';
}

/// Card payments saved at an estimated shilling amount, to keep or correct.
String estimatedText(int count) => count == 1
    ? '1 card payment in another currency was added with an estimated '
          'shilling amount. Check it against your statement.'
    : '$count card payments in another currency were added with an '
          'estimated shilling amount. Check them against your statement.';

/// Settings' notes about Equity messages that were read but not added.
List<String> equityHeldTexts({
  required int foreignCurrency,
  required int noAccount,
  required int topUps,
}) {
  String n(int count, String one, String many) =>
      count == 1 ? '1 $one' : '$count $many';
  return [
    if (noAccount > 0)
      '${n(noAccount, 'Equity message was', 'Equity messages were')} read '
          'but not added: add your Equity account first (Accounts › Add, '
          'type Bank, Equity Bank), then use Import last 30 days.',
    if (foreignCurrency > 0)
      '${n(foreignCurrency, 'Equity card payment in another currency is', 'Equity card '
          'payments in another currency are')} waiting for that day\'s '
          "exchange rate. It's added, marked as estimated, the next time "
          'you open PennyWise while online.',
    if (topUps > 0)
      '${n(topUps, 'top-up', 'top-ups')} from your M-Pesa into Equity '
          "weren't added again, because the M-Pesa side is already saved. "
          'Fix moves between your accounts records them as moves.',
  ];
}

/// Light, Dark, or follow the phone. Applies at once and is remembered.
class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.controller});

  final AppearanceController controller;

  @override
  Widget build(BuildContext context) {
    final mode = controller.value;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, color: context.colors.primary),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    'Appearance',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  AppearanceController.label(mode),
                  key: const Key('appearance-current'),
                  style: TextStyle(color: context.colors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System', key: Key('appearance-system')),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light', key: Key('appearance-light')),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark', key: Key('appearance-dark')),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (picked) => controller.choose(picked.single),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown before Android's permission dialog: what is read, and why.
class _PermissionExplanationDialog extends StatelessWidget {
  const _PermissionExplanationDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: Icon(Icons.sms_outlined, color: context.colors.primary),
      title: const Text('Allow PennyWise to read transaction SMS?'),
      content: const SingleChildScrollView(
        child: Text(
          'To add your M-Pesa and Airtel Money transactions automatically, '
          'PennyWise needs permission to read SMS on this phone.\n\n'
          '• Only messages from M-Pesa and Airtel Money are read. All other '
          'SMS are ignored on the phone and never leave it.\n'
          '• From each transaction message, only the amount, type, '
          'merchant/sender, date and transaction code are saved to your '
          'account, plus a copy of that one message with phone and account '
          'numbers masked.\n'
          '• You can turn this off at any time in Settings.\n\n'
          'Android will now ask you to allow SMS access.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: context.colors.textSecondary, height: 1.4);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How it works',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: context.colors.textPrimary,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'When an M-Pesa or Airtel Money message arrives, PennyWise reads '
            'the amount, merchant and transaction code and adds it to your '
            'transactions with a suggested category. Tap it to change '
            'anything.\n\n'
            'Messages are checked while the app is open, and any that arrived '
            'while it was closed are added the next time you open it. Each '
            'transaction code is only ever added once.',
            style: style,
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final Color color;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(color: context.colors.textPrimary)),
                if (actionLabel != null)
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    child: Text(actionLabel!),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
