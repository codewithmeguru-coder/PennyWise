import 'package:flutter/material.dart';

import '../sms/fuliza_import.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

/// Settings › Fuliza history: shows what importing the phone's Fuliza
/// messages would do, imports only on an explicit tap, and can undo exactly
/// what was imported. Works on the signed-in profile only.
class FulizaImportScreen extends StatefulWidget {
  const FulizaImportScreen({super.key, required this.importer});

  final FulizaImporter importer;

  @override
  State<FulizaImportScreen> createState() => _FulizaImportScreenState();
}

class _FulizaImportScreenState extends State<FulizaImportScreen> {
  FulizaPreview? _preview;
  List<String> _imported = const [];
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _preview = null;
    });
    try {
      final preview = await widget.importer.preview();
      final imported = await widget.importer.importedIds();
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _imported = imported;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          'Couldn\'t read your messages. Check that PennyWise may read SMS.');
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _run(Future<FulizaRunResult> Function() job,
      String Function(FulizaRunResult) describe) async {
    if (_working) return;
    setState(() => _working = true);
    final result = await job();
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(describe(result)),
      behavior: SnackBarBehavior.floating,
    ));
    await _load();
  }

  Future<void> _import() async {
    final preview = _preview!;
    final n = preview.eligible.length;
    if (!await _confirm(
        'Import $n Fuliza records?',
        'They are added to this profile only. Nothing already saved is '
            'changed. You can undo this import afterwards.',
        'Import')) {
      return;
    }
    await _run(
      () => widget.importer.importEligible(preview),
      (r) => r.error == null
          ? 'Imported ${r.done}${r.skipped > 0 ? ' (${r.skipped} were already there)' : ''}.'
          : 'Stopped after ${r.done}: ${r.error} The ${r.done} saved can be '
              'undone.',
    );
  }

  Future<void> _undo() async {
    final n = _imported.length;
    if (!await _confirm(
        'Undo the Fuliza import?',
        'This deletes the $n Fuliza records that the import created in this '
            'profile, and nothing else. They won\'t be added again '
            'automatically.',
        'Delete $n')) {
      return;
    }
    await _run(
      widget.importer.undo,
      (r) => r.error == null
          ? 'Removed ${r.done} imported records.'
          : 'Stopped after ${r.done}: ${r.error}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Fuliza history')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ]),
              ),
            )
          : preview == null
              ? const Center(child: CircularProgressIndicator())
              : _body(preview),
    );
  }

  Widget _body(FulizaPreview p) {
    final bySim = p.bySim;
    final eligible = p.eligible.length;
    final review = p.count(FulizaStatus.needsReview);
    final secondary = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: AppColors.textSecondary);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Fuliza messages since ${Formatters.shortDate(FulizaImporter.since)}. '
          'Nothing has been saved yet.',
          style: secondary,
        ),
        const SizedBox(height: 12),
        for (final slot in bySim.keys.toList()..sort())
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SIM ${slot + 1}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('${bySim[slot]!.draws} loans: '
                      '${Formatters.currency(bySim[slot]!.borrowed)} + fees '
                      '${Formatters.currency(bySim[slot]!.fees)}'),
                  Text('${bySim[slot]!.repayments} repayments: '
                      '${Formatters.currency(bySim[slot]!.repaid)}'),
                  Text('Owed from these messages: '
                      '${Formatters.currency(bySim[slot]!.debtChange)}'),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Text('Ready to import: $eligible', key: const Key('fuliza-eligible')),
        Text('Already imported: ${p.count(FulizaStatus.alreadyImported)}'),
        Text('Repeated messages (counted once): '
            '${p.count(FulizaStatus.repeated)}'),
        Text('Need review, SIM or account unknown (not imported): $review'),
        const SizedBox(height: 12),
        Text(
          'Each loan moves money from that SIM\'s Fuliza into its M-Pesa; '
          'only the access fee counts as spending. Each repayment moves money '
          'from M-Pesa back to Fuliza and lowers what you owe. The payments '
          'the loans paid for are already in your transactions. Account '
          'cards only count messages after each account\'s starting date.',
          style: secondary,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _working || eligible == 0 ? null : _import,
          child: Text('Import $eligible'),
        ),
        if (_imported.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _working ? null : _undo,
            child: Text('Undo Fuliza import (${_imported.length})'),
          ),
        ],
        if (_working) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }
}
