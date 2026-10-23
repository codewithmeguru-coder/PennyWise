import 'package:flutter/material.dart';

import '../categorization/category_rule.dart';
import '../categorization/category_rule_repository.dart';
import '../data/data_exception.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';

/// Settings › Learned categories: what PennyWise remembers from the user's
/// corrections, with a way to forget each one. Forgetting only stops future
/// suggestions; it doesn't change any transaction.
class LearnedCategoriesScreen extends StatelessWidget {
  const LearnedCategoriesScreen({super.key, required this.rules});

  final CategoryRuleStore rules;

  Future<void> _forget(BuildContext context, CategoryRule rule) async {
    final name = rule.label ?? 'this merchant';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget $name?'),
        content: const Text('New transactions from it won\'t get this category '
            'automatically. Transactions you already have don\'t change.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await rules.forget(rule.key);
    } on DataException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Learned categories')),
      body: ListenableBuilder(
        listenable: rules,
        builder: (context, _) {
          final list = rules.sorted;
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.auto_awesome_outlined,
              title: 'Nothing learned yet',
              message: 'When you change the category of a transaction PennyWise '
                  'detected from an SMS, it remembers your choice for that '
                  'merchant and uses it for new transactions.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
            itemBuilder: (context, i) {
              final rule = list[i];
              final category = DefaultCategories.byId(rule.categoryId);
              final direction = rule.type == TransactionType.income
                  ? 'Money received'
                  : 'Money paid';
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  child: Icon(category.icon, color: AppColors.primary),
                ),
                title: Text(rule.label ?? rule.key),
                subtitle: Text('$direction → ${category.name}'),
                trailing: IconButton(
                  tooltip: 'Forget',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _forget(context, rule),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
