import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/categorization/category_registry.dart';
import 'package:pennywise/categorization/category_rule.dart';
import 'package:pennywise/categorization/category_suggester.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/category_budget.dart';
import 'package:pennywise/models/custom_category.dart';
import 'package:pennywise/models/monthly_summary.dart';
import 'package:pennywise/models/transaction_category.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/utils/transaction_search.dart';

import 'fake_category_repository.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// The user's own categories: names, the shared lookup every screen uses,
// deactivation, learning, search, limits and the Settings screen. In memory
// only. Built-in categories and stored records are never changed.

const pets = CustomCategory(
  id: 'c_petsabcdef',
  name: 'Pets',
  type: TransactionType.expense,
  icon: 'pets',
);
const church = CustomCategory(
  id: 'c_churchgive',
  name: 'Church',
  type: TransactionType.expense,
  icon: 'church',
  active: false,
);
const rentIn = CustomCategory(
  id: 'c_rentincome',
  name: 'Rent income',
  type: TransactionType.income,
  icon: 'home',
);

TransactionModel spend(String category, double amount, {String? d}) =>
    TransactionModel(
      id: 't${category}_$amount',
      description: d ?? 'Item $amount',
      amount: amount,
      type: TransactionType.expense,
      categoryId: category,
      date: DateTime(2026, 10, 5, 10),
      account: Account.mpesa,
    );

/// A registry over [repo], loaded.
Future<CategoryRegistry> loaded(FakeCategoryRepository repo) async {
  final r = CategoryRegistry(repo);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return r;
}

void main() {
  tearDown(DefaultCategories.clearCustom);

  group('built-in categories', () {
    test(
      'all 29 are unchanged, and are the whole list without custom ones',
      () {
        expect(DefaultCategories.builtIn, hasLength(29));
        expect(
          DefaultCategories.all.map((c) => c.id),
          DefaultCategories.builtIn.map((c) => c.id),
        );
        expect(DefaultCategories.byId('food').name, 'Food');
        expect(
          DefaultCategories.byId('airtime_data').name,
          'Airtime, Data & Minutes',
        );
        expect(
          DefaultCategories.builtIn.every((c) => !c.isCustom && c.active),
          isTrue,
        );
        expect(DefaultCategories.byId('nope'), DefaultCategories.unknown);
      },
    );
  });

  group('ids and names', () {
    test('new ids fit the rules, never look built-in, and are random', () {
      final ids = {for (var i = 0; i < 200; i++) CustomCategory.newId()};
      expect(ids, hasLength(200));
      for (final id in ids) {
        expect(CustomCategory.validId.hasMatch(id), isTrue, reason: id);
        expect(CategoryBudget.validId.hasMatch(id), isTrue, reason: id);
        expect(DefaultCategories.builtIn.any((c) => c.id == id), isFalse);
      }
    });

    test('duplicates are refused across built-in and custom, expense and '
        'income, ignoring capitals and outer spaces', () {
      DefaultCategories.useCustom([pets.toCategory(), church.toCategory()]);
      expect(CustomCategory.validateName('Food'), contains('already exists'));
      expect(
        CustomCategory.validateName('  fOOd  '),
        'A category called "Food" already exists',
      );
      expect(CustomCategory.validateName('salary'), contains('"Salary"'));
      expect(CustomCategory.validateName('PETS'), contains('"Pets"'));
      expect(
        CustomCategory.validateName('church'),
        contains('"Church"'),
        reason: 'inactive names stay taken',
      );
      expect(CustomCategory.validateName('Vet bills'), isNull);
    });

    test('empty, too long and reserved names are refused', () {
      expect(CustomCategory.validateName(''), 'Enter a name');
      expect(CustomCategory.validateName('   '), 'Enter a name');
      expect(CustomCategory.validateName(null), 'Enter a name');
      expect(CustomCategory.validateName('x' * 31), contains('30'));
      expect(CustomCategory.validateName('x' * 30), isNull);
      expect(
        CustomCategory.validateName('Uncategorized'),
        anyOf(contains('reserved'), contains('already exists')),
      );
      expect(CustomCategory.validateName('unknown'), contains('reserved'));
    });

    test('renaming a category to itself (other capitals) is allowed', () {
      DefaultCategories.useCustom([pets.toCategory()]);
      expect(CustomCategory.validateName('pets', exceptId: pets.id), isNull);
      expect(
        CustomCategory.validateName('Food', exceptId: pets.id),
        contains('already exists'),
      );
    });
  });

  group('the shared lookup', () {
    test('custom categories come after the built-in ones, by id', () async {
      final r = await loaded(FakeCategoryRepository([pets, church, rentIn]));
      expect(DefaultCategories.byId(pets.id).name, 'Pets');
      expect(DefaultCategories.byId(pets.id).isCustom, isTrue);
      final expense = DefaultCategories.forType(TransactionType.expense);
      expect(expense.last.id, pets.id);
      expect(
        expense.take(expense.length - 1).every((c) => !c.isCustom),
        isTrue,
      );
      expect(
        DefaultCategories.forType(TransactionType.income).last.id,
        rentIn.id,
      );
      r.dispose();
    });

    test('a turned-off category still names old records but isn\'t '
        'offered, unless the record being edited uses it', () async {
      final r = await loaded(FakeCategoryRepository([church]));
      expect(DefaultCategories.byId(church.id).name, 'Church');
      expect(DefaultCategories.isInactive(church.id), isTrue);
      expect(
        DefaultCategories.forType(TransactionType.expense).map((c) => c.id),
        isNot(contains(church.id)),
      );
      expect(
        DefaultCategories.forType(
          TransactionType.expense,
          keep: church.id,
        ).map((c) => c.id),
        contains(church.id),
      );
      expect(
        DefaultCategories.forType(TransactionType.refund).map((c) => c.id),
        isNot(contains(church.id)),
      );
      r.dispose();
    });

    test('signing out clears them: another profile never sees them', () async {
      final first = await loaded(FakeCategoryRepository([pets]));
      expect(DefaultCategories.byId(pets.id).name, 'Pets');
      first.dispose();
      expect(DefaultCategories.custom, isEmpty);
      expect(DefaultCategories.byId(pets.id), DefaultCategories.unknown);
      final second = await loaded(FakeCategoryRepository([rentIn]));
      expect(DefaultCategories.byId(pets.id), DefaultCategories.unknown);
      expect(DefaultCategories.byId(rentIn.id).name, 'Rent income');
      second.dispose();
    });

    test('if they can\'t load, built-in categories still work', () async {
      final repo = FakeCategoryRepository()
        ..loadError = const DataException('No connection.');
      final r = await loaded(repo);
      expect(r.error, 'No connection.');
      expect(DefaultCategories.byId('food').name, 'Food');
      expect(
        DefaultCategories.forType(TransactionType.expense),
        hasLength(greaterThan(10)),
      );
      r.dispose();
    });
  });

  group('adding, renaming, turning off', () {
    test(
      'add saves a new id; a bad or duplicate name writes nothing',
      () async {
        final repo = FakeCategoryRepository([pets]);
        final r = await loaded(repo);
        expect(
          await r.add(name: ' pets ', type: TransactionType.expense),
          contains('already exists'),
        );
        expect(
          await r.add(name: 'Food', type: TransactionType.income),
          contains('already exists'),
        );
        expect(
          await r.add(name: 'X', type: TransactionType.transfer),
          'Choose expense or income',
        );
        expect(repo.writes, isEmpty);

        expect(
          await r.add(
            name: '  Vet  ',
            type: TransactionType.expense,
            icon: 'medical',
          ),
          isNull,
        );
        await Future<void>.delayed(Duration.zero);
        final vet = repo.byName('Vet')!;
        expect(CustomCategory.validId.hasMatch(vet.id), isTrue);
        expect(vet.icon, 'medical');
        expect(DefaultCategories.byId(vet.id).name, 'Vet');
        r.dispose();
      },
    );

    test('a failed save says why and changes nothing', () async {
      final repo = FakeCategoryRepository()
        ..writeError = const DataException('Couldn\'t save.');
      final r = await loaded(repo);
      expect(
        await r.add(name: 'Vet', type: TransactionType.expense),
        'Couldn\'t save.',
      );
      expect(repo.items, isEmpty);
      r.dispose();
    });

    test('there is a cap of 50', () async {
      final repo = FakeCategoryRepository([
        for (var i = 0; i < 50; i++)
          CustomCategory(
            id: 'c_${String.fromCharCodes([97 + i ~/ 26, 97 + i % 26])}aaaaaa',
            name: 'Cat $i',
            type: TransactionType.expense,
          ),
      ]);
      final r = await loaded(repo);
      expect(
        await r.add(name: 'One more', type: TransactionType.expense),
        contains('50'),
      );
      r.dispose();
    });

    test('renaming keeps the id; past records show the new name in lists, '
        'search and reports; nothing on them changes', () async {
      final repo = FakeCategoryRepository([pets]);
      final r = await loaded(repo);
      final records = [spend(pets.id, 300, d: 'Vet visit'), spend('food', 100)];
      final before = MonthlySummary.calculate(
        transactions: records,
        month: DateTime(2026, 10),
      );
      expect(TransactionSearch.matches(records.first, 'pets'), isTrue);

      expect(await r.edit(pets.id, name: 'Pet care'), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(repo.items.single.id, pets.id);
      expect(repo.items.single.type, TransactionType.expense);
      expect(records.first.categoryId, pets.id); // the record is untouched
      expect(DefaultCategories.byId(pets.id).name, 'Pet care');
      expect(TransactionSearch.matches(records.first, 'pet care'), isTrue);
      expect(TransactionSearch.matches(records.first, 'pets'), isFalse);
      final after = MonthlySummary.calculate(
        transactions: records,
        month: DateTime(2026, 10),
      );
      expect(after.expenses, before.expenses);
      expect(
        after.byCategory.map((c) => '${c.categoryId}=${c.amount}'),
        before.byCategory.map((c) => '${c.categoryId}=${c.amount}'),
      );
      expect(await r.edit(pets.id, name: 'food'), contains('already exists'));
      r.dispose();
    });

    test('turning off and back on changes only the flag', () async {
      final repo = FakeCategoryRepository([pets]);
      final r = await loaded(repo);
      expect(await r.setActive(pets.id, false), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(repo.writes.single, 'update ${pets.id} Pets pets false');
      expect(DefaultCategories.isInactive(pets.id), isTrue);
      expect(DefaultCategories.byId(pets.id).name, 'Pets');
      expect(await r.setActive(pets.id, true), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(DefaultCategories.isInactive(pets.id), isFalse);
      r.dispose();
    });

    test('a turned-off category still counts in reports', () async {
      final r = await loaded(FakeCategoryRepository([church]));
      final s = MonthlySummary.calculate(
        transactions: [spend(church.id, 500), spend('food', 100)],
        month: DateTime(2026, 10),
      );
      expect(s.expenses, 600);
      expect(s.byCategory.first.categoryId, church.id);
      r.dispose();
    });
  });

  group('learning and suggestions', () {
    final sms = SmsParser.parse(
      sender: 'MPESA',
      body:
          'UAB1CD2EF3 Confirmed. Ksh500.00 paid to MAMA PIMA. on 1/10/26 '
          'at 9:00 AM.New M-PESA balance is Ksh0.00. Transaction cost, '
          'Ksh0.00.',
      date: DateTime(2026, 10, 1, 9),
    )!;
    final key = CategoryRule.keyFor(sms)!;

    test('a learned rule can point to a custom category', () async {
      final r = await loaded(FakeCategoryRepository([pets]));
      final s = CategorySuggester(
        rules: {
          key: CategoryRule(
            key: key,
            categoryId: pets.id,
            type: TransactionType.expense,
          ),
        },
      ).forSms(sms);
      expect(s.categoryId, pets.id);
      r.dispose();
    });

    test(
      'a rule for a turned-off category is skipped, not suggested',
      () async {
        final r = await loaded(FakeCategoryRepository([church]));
        final s = CategorySuggester(
          rules: {
            key: CategoryRule(
              key: key,
              categoryId: church.id,
              type: TransactionType.expense,
            ),
          },
        ).forSms(sms);
        expect(s.categoryId, isNot(church.id));
        expect(s.categoryId, const CategorySuggester().forSms(sms).categoryId);
        r.dispose();
      },
    );
  });

  group('category limits', () {
    test('active custom expense categories can get a limit; turned-off and '
        'income ones aren\'t offered or copied', () async {
      final r = await loaded(FakeCategoryRepository([pets, church, rentIn]));
      expect(CategoryBudget.canHaveLimit(pets.id), isTrue);
      final offered = CategoryBudget.budgetable.map((c) => c.id);
      expect(offered, contains(pets.id));
      expect(offered, isNot(contains(church.id)));
      expect(offered, isNot(contains(rentIn.id)));
      expect(CategoryBudget.toCopy({pets.id: 100, church.id: 200}, {}), {
        pets.id: 100,
      });
      r.dispose();
    });

    test('a turned-off category keeps its existing limit', () async {
      final r = await loaded(FakeCategoryRepository([church]));
      final s = MonthlySummary.calculate(
        transactions: [spend(church.id, 500)],
        month: DateTime(2026, 10),
      );
      final cats = CategoryBudgetSummary.of(s, {church.id: 400});
      expect(cats.rows.single.categoryId, church.id);
      expect(cats.rows.single.limit, 400);
      expect(cats.overCount, 1);
      r.dispose();
    });
  });

  group('loading and errors', () {
    test('adding and renaming wait until the list has loaded', () async {
      final repo = FakeCategoryRepository([pets])..hold = Completer<void>();
      final r = CategoryRegistry(repo);
      await Future<void>.delayed(Duration.zero);
      expect(r.isLoaded, isFalse);
      expect(r.canEdit, isFalse);
      // "Pets" isn't known yet, so a duplicate could slip through: refused.
      expect(
        await r.add(name: 'Pets', type: TransactionType.expense),
        CategoryRegistry.notReady,
      );
      expect(
        await r.edit(pets.id, name: 'Pet care'),
        CategoryRegistry.notReady,
      );
      expect(repo.writes, isEmpty);

      repo.hold!.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(r.canEdit, isTrue);
      expect(
        await r.add(name: 'Pets', type: TransactionType.expense),
        contains('already exists'),
      );
      r.dispose();
    });

    test('after a load error they stay off until Retry succeeds', () async {
      final repo = FakeCategoryRepository([pets])
        ..loadError = const DataException('No connection.');
      final r = await loaded(repo);
      expect(r.error, 'No connection.');
      expect(r.canEdit, isFalse);
      expect(
        await r.add(name: 'Vet', type: TransactionType.expense),
        CategoryRegistry.notReady,
      );

      repo.loadError = null;
      r.retry();
      expect(r.isLoaded, isFalse);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(r.error, isNull);
      expect(r.canEdit, isTrue);
      expect(DefaultCategories.byId(pets.id).name, 'Pets');
      r.dispose();
    });

    test('an error after loading turns editing off again', () async {
      final repo = FakeCategoryRepository([pets]);
      final r = await loaded(repo);
      expect(r.canEdit, isTrue);
      repo.failLater(const DataException('Connection lost.'));
      await Future<void>.delayed(Duration.zero);
      expect(r.error, 'Connection lost.');
      expect(r.canEdit, isFalse);
      expect(
        await r.edit(pets.id, name: 'Pet care'),
        CategoryRegistry.notReady,
      );
      // What was loaded still names records.
      expect(DefaultCategories.byId(pets.id).name, 'Pets');
      r.dispose();
    });
  });

  group('screens', () {
    void phone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
    }

    Future<void> openCategories(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Categories'));
      await tester.pumpAndSettle();
    }

    testWidgets('add a category, refuse a duplicate, rename, turn off', (
      tester,
    ) async {
      phone(tester);
      final repo = FakeCategoryRepository();
      await pumpApp(tester, categories: repo);
      await openCategories(tester);

      await tester.tap(find.text('Add category'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        ' food ',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.text('A category called "Food" already exists'),
        findsOneWidget,
      );
      expect(repo.writes, isEmpty);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Pets',
      );
      await tester.tap(find.byTooltip('pets'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.byName('Pets')!.icon, 'pets');
      expect(find.text('Pets'), findsOneWidget);

      await tester.tap(find.text('Pets'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Pet care',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.items.single.name, 'Pet care');
      final id = repo.items.single.id;

      await tester.tap(find.text('Pet care'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn off'));
      await tester.pumpAndSettle();
      expect(repo.items.single.active, isFalse);
      expect(repo.items.single.id, id);
      expect(find.text('Inactive'), findsOneWidget);
    });

    FloatingActionButton addButton(WidgetTester tester) =>
        tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));

    testWidgets('while loading: a spinner, and Add category is off', (
      tester,
    ) async {
      phone(tester);
      final repo = FakeCategoryRepository([pets])..hold = Completer<void>();
      await pumpApp(tester, categories: repo);
      // The spinner never settles, so pump by time instead of settling.
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Categories'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(addButton(tester).onPressed, isNull);
      expect(find.text('Pets'), findsNothing);

      repo.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(addButton(tester).onPressed, isNotNull);
      expect(find.text('Pets'), findsOneWidget);
    });

    testWidgets('a load error: message, Add and rename off, Retry fixes it', (
      tester,
    ) async {
      phone(tester);
      final repo = FakeCategoryRepository([pets])
        ..loadError = const DataException('No connection.');
      await pumpApp(tester, categories: repo);
      await openCategories(tester);
      expect(find.text("Couldn't load your categories"), findsOneWidget);
      expect(
        find.textContaining('Adding and renaming are off'),
        findsOneWidget,
      );
      expect(addButton(tester).onPressed, isNull);
      await tester.tap(find.text('Add category'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      repo.loadError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load your categories"), findsNothing);
      expect(addButton(tester).onPressed, isNotNull);
      expect(find.text('Pets'), findsOneWidget);
    });

    testWidgets('an error after loading turns renaming off', (tester) async {
      phone(tester);
      final repo = FakeCategoryRepository([pets]);
      await pumpApp(tester, categories: repo);
      await openCategories(tester);
      repo.failLater(const DataException('Connection lost.'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load your categories"), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Pets'), matching: find.byType(ListTile)),
      );
      expect(tile.onTap, isNull);
      await tester.tap(find.text('Pets'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(addButton(tester).onPressed, isNull);
    });

    testWidgets('the transaction form offers active custom categories only', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository(),
        categories: FakeCategoryRepository([pets, church]),
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Pets'),
        200,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      expect(find.text('Pets'), findsOneWidget);
      expect(find.text('Church', skipOffstage: false), findsNothing);
    });

    testWidgets('an old record in a turned-off category still shows its name', (
      tester,
    ) async {
      phone(tester);
      await pumpApp(
        tester,
        repository: FakeTransactionRepository([
          spend(church.id, 250, d: 'Sunday offering').withId('old1'),
        ]),
        categories: FakeCategoryRepository([church]),
      );
      await showRecent(tester);
      expect(find.textContaining('Church'), findsWidgets);
    });

    testWidgets('signing out clears the user\'s categories', (tester) async {
      // Default test window: the login screen it ends on is laid out for it.
      await pumpApp(tester, categories: FakeCategoryRepository([pets]));
      expect(DefaultCategories.byId(pets.id).name, 'Pets');
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Sign out').last);
      await tester.pumpAndSettle();
      expect(DefaultCategories.custom, isEmpty);
    });
  });
}
