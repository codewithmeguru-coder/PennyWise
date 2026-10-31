import 'package:flutter/material.dart';

import '../services/account_deletion.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// Settings › Delete account.
///
/// Permanent, so it asks three times: tick "I understand", type DELETE,
/// then confirm it's really you (password, or the same Google account).
/// Only then is everything deleted. If it stops halfway, opening this
/// screen again finishes it.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({
    super.key,
    required this.deletion,
    this.email,
    this.transactionCount,
  });

  final AccountDeletion deletion;
  final String? email;
  final int? transactionCount;

  static const confirmWord = 'DELETE';

  /// What is deleted, as shown before anything happens.
  static List<String> whatIsDeleted(int? transactions) => [
    'Your sign-in account${transactions == null ? '' : ''}',
    transactions == null
        ? 'All your transactions'
        : 'All $transactions of your transactions',
    'Your accounts, starting balances and balance history',
    'Budgets and category limits',
    'Your own categories and learned categories',
    'Your profile and profile photo',
    'PennyWise settings and App Lock on this phone',
  ];

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final _word = TextEditingController();
  final _password = TextEditingController();
  bool _understood = false;
  bool _busy = false;
  bool _pending = false;
  bool _done = false;
  String? _step;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.deletion.pending().then((p) {
      if (mounted && p) setState(() => _pending = true);
    });
  }

  @override
  void dispose() {
    _word.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _google => widget.deletion.auth.signsInWithGoogle;

  bool get _ready =>
      !_busy &&
      !_done &&
      (_pending ||
          (_understood &&
              _word.text.trim() == DeleteAccountScreen.confirmWord &&
              (_google || _password.text.isNotEmpty)));

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
      _step = 'Confirming it\'s you';
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await widget.deletion.auth.reauthenticate(
        password: _google ? null : _password.text,
      );
      if (!ok) {
        setState(() {
          _busy = false;
          _step = null;
        });
        return;
      }
      if (!mounted) return;
      // Confirmed it's them; nothing is running while they decide.
      setState(() => _step = null);
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete everything now?'),
          content: const Text(
            'This is the last step. Your account and all its data will be '
            'deleted and can\'t be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep my account'),
            ),
            TextButton(
              key: const Key('delete-final'),
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: context.colors.expense,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (sure != true) {
        setState(() {
          _busy = false;
          _step = null;
        });
        return;
      }
      await widget.deletion.run(
        onStep: (s) {
          if (mounted) setState(() => _step = s);
        },
      );
      if (mounted) {
        setState(() {
          _step = null;
          _done = true;
        });
      }
      // Signed out now: the app shows the sign-in screen. The app-wide
      // messenger shows this there.
      messenger.showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 8),
          content: Text('Your PennyWise account and data were deleted.'),
        ),
      );
    } on AuthException catch (e) {
      _fail(e.message);
    } on DeletionException catch (e) {
      _fail(e.message);
      _pending = true;
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _step = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      appBar: AppBar(title: const Text('Delete account')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (_pending)
            Card(
              key: const Key('deletion-pending'),
              color: c.warning.withValues(alpha: 0.12),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'A deletion you started didn\'t finish. Confirm it\'s you '
                  'below to finish it.',
                ),
              ),
            ),
          Text(
            'Deleting your account is permanent. It can\'t be undone, and '
            'PennyWise can\'t recover anything afterwards.',
            style: TextStyle(fontWeight: FontWeight.w600, color: c.expense),
          ),
          const SizedBox(height: 12),
          Text('This deletes${widget.email == null ? '' : ' for ${widget.email}'}:'),
          const SizedBox(height: 4),
          for (final line in DeleteAccountScreen.whatIsDeleted(
            widget.transactionCount,
          ))
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: Text('• $line'),
            ),
          const SizedBox(height: 8),
          Text(
            'Not affected: the SMS messages on your phone, and your Google '
            'account itself.',
            style: TextStyle(color: c.textSecondary),
          ),
          if (!_pending) ...[
            const SizedBox(height: 16),
            CheckboxListTile(
              key: const Key('delete-understood'),
              contentPadding: EdgeInsets.zero,
              value: _understood,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _understood = v ?? false),
              title: const Text('I understand this can\'t be undone'),
            ),
            TextField(
              key: const Key('delete-word'),
              controller: _word,
              enabled: !_busy,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Type ${DeleteAccountScreen.confirmWord} to confirm',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 12),
          if (!_google)
            TextField(
              key: const Key('delete-password'),
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Your password',
              ),
              onChanged: (_) => setState(() {}),
            )
          else
            Text(
              'You\'ll pick your Google account again to confirm it\'s you.',
              style: TextStyle(color: c.textSecondary),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const Key('delete-error'),
              style: TextStyle(color: c.expense),
            ),
          ],
          if (_step != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text('$_step…')),
              ],
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('delete-start'),
            style: FilledButton.styleFrom(
              backgroundColor: c.expense,
              foregroundColor: Colors.white,
            ),
            onPressed: _ready ? _delete : null,
            child: Text(_pending ? 'Finish deleting' : 'Delete my account'),
          ),
        ],
      ),
    );
  }
}
