import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/data_exception.dart';
import '../data/transaction_store.dart';
import '../models/transaction_model.dart';
import '../sms/estimated_amount.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';
import '../widgets/empty_state.dart';

/// Card payments made in another currency and saved at that day's market
/// rate: keep each estimate, or type the KES amount from the statement.
/// Only the amount and its note change.
class EstimatedAmountsScreen extends StatelessWidget {
  const EstimatedAmountsScreen({super.key, required this.store});

  final TransactionStore store;

  static List<TransactionModel> pending(List<TransactionModel> all) =>
      all.where(EstimatedAmount.isEstimated).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  Future<void> _save(
    BuildContext context,
    TransactionModel t,
    double amount, {
    required bool corrected,
  }) async {
    try {
      await store.update(
        EstimatedAmount.withAmount(
          t,
          amount,
          EstimatedAmount.checkedNote(t, corrected: corrected),
        ),
      );
    } on DataException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _correct(BuildContext context, TransactionModel t) async {
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _AmountDialog(transaction: t),
    );
    if (amount == null || !context.mounted) return;
    await _save(context, t, amount, corrected: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Estimated amounts')),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final list = pending(store.transactions);
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.check_circle_outline_rounded,
              title: 'All amounts checked',
              message:
                  'Card payments in another currency appear here with an '
                  'estimated shilling amount until you keep or correct it.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(
                'These were paid in another currency. The shilling amount '
                "uses that day's market rate; Equity's card rate and fee "
                'usually differ a little. Check your statement.',
                style: TextStyle(color: context.colors.textSecondary),
              ),
              const SizedBox(height: 12),
              for (final t in list)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.description,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${EstimatedAmount.foreignAmount(t) ?? ''} · '
                          '${Formatters.shortDate(t.date)}',
                          style: TextStyle(color: context.colors.textSecondary),
                        ),
                        Text(
                          'About ${Formatters.currency(t.amount)}',
                          key: Key('estimate-${t.id}'),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        // Wraps on narrow screens rather than overflowing.
                        Wrap(
                          alignment: WrapAlignment.end,
                          children: [
                            TextButton(
                              key: Key('keep-${t.id}'),
                              onPressed: () => _save(
                                context,
                                t,
                                t.amount,
                                corrected: false,
                              ),
                              child: const Text('Keep estimate'),
                            ),
                            TextButton(
                              key: Key('correct-${t.id}'),
                              onPressed: () => _correct(context, t),
                              child: const Text('Enter amount'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// "Amount from your statement": owns its text field, so it is disposed
/// only when the dialog is gone.
class _AmountDialog extends StatefulWidget {
  const _AmountDialog({required this.transaction});

  final TransactionModel transaction;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final _field = TextEditingController(
    text: widget.transaction.amount.toStringAsFixed(2),
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transaction;
    return AlertDialog(
      title: const Text('Amount from your statement'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${EstimatedAmount.foreignAmount(t) ?? ''} to ${t.description}',
            style: TextStyle(color: context.colors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('estimated-amount-field'),
            controller: _field,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
            ],
            decoration: const InputDecoration(prefixText: 'KSh '),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final v = double.tryParse(_field.text);
            if (v != null && v > 0) Navigator.of(context).pop(v);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
