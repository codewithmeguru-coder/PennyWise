import 'package:flutter/material.dart';

import '../categorization/category_registry.dart';
import '../data/data_exception.dart';
import '../data/transaction_store.dart';
import '../models/category_icons.dart';
import '../models/custom_category.dart';
import '../models/transaction_category.dart';
import '../models/transaction_model.dart';
import '../theme/app_theme.dart';
import '../widgets/section_header.dart';

/// Settings › Categories: add your own categories, rename them, change
/// their icon, turn them off or on, and delete them. Built-in categories are
/// listed but can't be changed.
///
/// Deleting never leaves a transaction without a category: the ones using
/// it are first moved to a category the user picks (after confirming), and
/// the deleted category is kept, turned off, so budgets and learned rules
/// that mention it still read correctly. It can be turned back on here.
class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key, required this.registry, this.transactions});

  final CategoryRegistry registry;

  /// The user's transactions, to move off a category being deleted. Without
  /// it, only categories no transaction uses can be deleted.
  final TransactionStore? transactions;

  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _open(BuildContext context, [CustomCategory? existing]) async {
    final message = await showDialog<String>(
      context: context,
      builder: (_) => _CategoryDialog(registry: registry, existing: existing),
    );
    if (!context.mounted || message == null) return;
    if (message == _CategoryDialog.deleteRequest && existing != null) {
      await _delete(context, existing);
      return;
    }
    _say(context, message);
  }

  /// Transactions that use [c] (by id; renaming never changes it).
  List<TransactionModel> _using(CustomCategory c) => [
    for (final t in transactions?.transactions ?? const <TransactionModel>[])
      if (t.categoryId == c.id) t,
  ];

  Future<void> _delete(BuildContext context, CustomCategory c) async {
    final used = _using(c);
    final store = transactions;
    if (used.isNotEmpty && store == null) {
      _say(context, 'Transactions use "${c.name}". Turn it off instead.');
      return;
    }
    TransactionCategory? moveTo;
    if (used.isNotEmpty) {
      final choices = [
        for (final o in DefaultCategories.forType(c.type))
          if (o.id != c.id) o,
      ];
      moveTo = await showModalBottomSheet<TransactionCategory>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${used.length} ${used.length == 1 ? 'transaction uses' : 'transactions use'} '
                  '"${c.name}". Move ${used.length == 1 ? 'it' : 'them'} to:',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in choices)
                      ActionChip(
                        key: Key('move-to-${o.id}'),
                        avatar: Icon(o.icon, size: 18),
                        label: Text(o.name),
                        onPressed: () => Navigator.of(context).pop(o),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      if (moveTo == null || !context.mounted) return;
    }
    final target = moveTo;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${c.name}"?'),
        content: Text(
          '${target == null ? 'No transactions use it.' : 'The ${used.length} '
                    '${used.length == 1 ? 'transaction' : 'transactions'} '
                    'using it move to "${target.name}". Only their category '
                    'changes.'}\n\n'
          'It disappears from the categories you can pick. Budgets and '
          'learned rules that mention it keep working, and you can turn it '
          'back on from this list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-delete-category'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    // Move first: if a move fails, the category stays, so nothing is left
    // pointing at a deleted one.
    var moved = 0;
    if (target != null) {
      for (final t in used) {
        try {
          await store!.update(t.withCategory(target.id));
          moved++;
        } on DataException catch (e) {
          if (context.mounted) {
            _say(
              context,
              'Moved $moved of ${used.length}, then: ${e.message} '
              '"${c.name}" was kept; try again.',
            );
          }
          return;
        }
      }
    }
    final problem = await registry.setActive(c.id, false);
    if (!context.mounted) return;
    _say(
      context,
      problem ??
          (moved == 0
              ? '"${c.name}" deleted'
              : '"${c.name}" deleted; $moved moved to "${target!.name}"'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: ListenableBuilder(
        listenable: registry,
        builder: (context, _) => FloatingActionButton.extended(
          // Until the list has loaded, a name already used could get
          // through the duplicate check.
          onPressed: registry.canEdit ? () => _open(context) : null,
          backgroundColor: registry.canEdit
              ? null
              : context.colors.textSecondary.withValues(alpha: 0.3),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add category'),
        ),
      ),
      body: ListenableBuilder(
        listenable: registry,
        builder: (context, _) {
          final mine = registry.categories;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (!registry.isLoaded)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (registry.error != null)
                Card(
                  color: context.colors.warning.withValues(alpha: 0.1),
                  child: ListTile(
                    leading: const Icon(Icons.cloud_off_rounded),
                    title: const Text('Couldn\'t load your categories'),
                    subtitle: Text(
                      '${registry.error!} Built-in categories '
                      'still work. Adding and renaming are off until '
                      'they load.',
                    ),
                    trailing: TextButton(
                      onPressed: registry.retry,
                      child: const Text('Retry'),
                    ),
                  ),
                ),
              if (registry.isLoaded)
                for (final type in [
                  TransactionType.expense,
                  TransactionType.income,
                ])
                  ..._section(context, type, [
                    for (final c in mine)
                      if (c.type == type) c,
                  ]),
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Built-in categories (${DefaultCategories.builtIn.length})',
                ),
                subtitle: const Text('These can\'t be renamed or turned off.'),
                children: [
                  for (final c in DefaultCategories.builtIn)
                    ListTile(
                      dense: true,
                      leading: Icon(c.icon, size: 20),
                      title: Text(c.name),
                      subtitle: Text(c.type.label),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    TransactionType type,
    List<CustomCategory> list,
  ) {
    return [
      SectionHeader(
        title: type == TransactionType.expense
            ? 'Your expense categories'
            : 'Your income categories',
      ),
      if (list.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            type == TransactionType.expense
                ? 'None yet. Tap "Add category" to add one.'
                : 'None yet.',
            style: TextStyle(color: context.colors.textSecondary),
          ),
        )
      else
        Card(
          child: Column(
            children: [
              for (final c in list)
                ListTile(
                  leading: Icon(
                    CategoryIcons.of(c.icon),
                    color: c.active
                        ? context.colors.primary
                        : context.colors.textSecondary,
                  ),
                  title: Text(c.name),
                  subtitle: c.active ? null : const Text('Inactive'),
                  trailing: Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: registry.canEdit ? null : context.colors.divider,
                  ),
                  // Renaming needs the full list too (see canEdit).
                  onTap: registry.canEdit ? () => _open(context, c) : null,
                ),
            ],
          ),
        ),
    ];
  }
}

/// Add (no [existing]) or edit one category. Pops with a message to show
/// (e.g. "Pets added"), or null when cancelled.
class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({required this.registry, this.existing});

  /// Popped by "Delete…": the screen then asks where its transactions go.
  static const deleteRequest = '\u0000delete';

  final CategoryRegistry registry;
  final CustomCategory? existing;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late var _type = widget.existing?.type ?? TransactionType.expense;
  late var _icon = widget.existing?.icon ?? CategoryIcons.fallback;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action, String done) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final problem = await action();
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _saving = false;
        _error = problem;
      });
      return;
    }
    Navigator.of(context).pop(done);
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final name = _name.text.trim();
    final existing = widget.existing;
    if (existing == null) {
      _run(
        () => widget.registry.add(name: name, type: _type, icon: _icon),
        '"$name" added',
      );
    } else {
      _run(
        () => widget.registry.edit(
          existing.id,
          name: name == existing.name ? null : name,
          icon: _icon,
        ),
        'Saved',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return AlertDialog(
      title: Text(existing == null ? 'Add category' : 'Edit category'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _name,
                autofocus: existing == null,
                maxLength: CustomCategory.maxNameLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) =>
                    CustomCategory.validateName(v, exceptId: existing?.id),
              ),
              if (existing == null)
                SegmentedButton<TransactionType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: TransactionType.expense,
                      label: Text('Expense'),
                    ),
                    ButtonSegment(
                      value: TransactionType.income,
                      label: Text('Income'),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                )
              else
                Text(
                  '${existing.type.label} category',
                  style: TextStyle(color: context.colors.textSecondary),
                ),
              const SizedBox(height: 12),
              const Text('Icon'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final MapEntry(key: key, value: icon)
                      in CategoryIcons.all.entries)
                    IconButton(
                      tooltip: key,
                      isSelected: key == _icon,
                      onPressed: () => setState(() => _icon = key),
                      icon: Icon(icon),
                      style: IconButton.styleFrom(
                        backgroundColor: key == _icon
                            ? context.colors.primary.withValues(alpha: 0.15)
                            : null,
                      ),
                    ),
                ],
              ),
              if (existing != null) ...[
                const SizedBox(height: 12),
                Text(
                  existing.active
                      ? 'Turning it off hides it from new transactions and '
                            'suggestions. Past transactions keep it, and '
                            'reports and limits still count them.'
                      : 'It\'s off: past transactions keep it, but it isn\'t '
                            'offered for new ones.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.textSecondary,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: context.colors.expense)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (existing != null)
          TextButton(
            key: const Key('delete-category'),
            onPressed: _saving
                ? null
                : () => Navigator.of(context).pop(_CategoryDialog.deleteRequest),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.expense,
            ),
            child: const Text('Delete…'),
          ),
        if (existing != null)
          TextButton(
            onPressed: _saving
                ? null
                : () => _run(
                    () => widget.registry.setActive(
                      existing.id,
                      !existing.active,
                    ),
                    existing.active
                        ? '"${existing.name}" turned off'
                        : '"${existing.name}" turned back on',
                  ),
            child: Text(existing.active ? 'Turn off' : 'Turn on'),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
