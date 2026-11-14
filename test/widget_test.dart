import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/services/auth_service.dart';

import 'fake_auth_service.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

void main() {
  testWidgets('Dashboard shows balance and recent transactions',
      (WidgetTester tester) async {
    await pumpApp(tester);

    expect(find.text('Available balance'), findsOneWidget);
    expect(find.text('KSh 64,150.00'), findsOneWidget); // 65,000 - 850
    await showRecent(tester);
    expect(find.text('Recent transactions'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
  });

  testWidgets('Bottom navigation switches to the Transactions tab',
      (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Expenses'), findsWidgets);
    // The list is lazily built, so scroll the row into view first.
    await tester.scrollUntilVisible(
      find.text('Monthly salary'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Monthly salary'), findsWidgets);
  });

  testWidgets('Add form validates empty input', (WidgetTester tester) async {
    await pumpApp(tester, repository: FakeTransactionRepository());

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    // The button sits below the fold of the default test window.
    await scrollAndTap(tester, 'Save transaction');

    // The form is taller than the test window: go back up to the first
    // fields to read their errors.
    await scrollToTop(tester);
    expect(find.text('Enter an amount', skipOffstage: false), findsOneWidget);
    expect(find.text('Enter a description', skipOffstage: false),
        findsOneWidget);
    expect(find.text('Choose a category', skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('New users see an empty dashboard, not sample data',
      (WidgetTester tester) async {
    await pumpApp(tester, repository: FakeTransactionRepository());

    await showRecent(tester);
    expect(find.text('No transactions yet'), findsOneWidget);
    expect(find.text('KSh 0.00'), findsWidgets);
  });

  testWidgets('Adding a transaction saves it and shows it',
      (WidgetTester tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'), '1250.50');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'), 'Groceries');
    await scrollAndTap(tester, 'Shopping');
    await scrollAndTap(tester, 'Save transaction');

    expect(repo.items, hasLength(1));
    final saved = repo.items.single;
    expect(saved.description, 'Groceries');
    expect(saved.amount, 1250.5);
    expect(saved.categoryId, 'shopping');
    await showRecent(tester);
    expect(find.text('Groceries'), findsOneWidget);
  });

  testWidgets('A failed save (offline) says so, saves nothing, and "Try '
      'again" saves what was entered', (WidgetTester tester) async {
    final repo = await pumpApp(tester, repository: FakeTransactionRepository());
    repo.failWrites = 2;

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'), '300');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'), 'Taxi');
    await scrollAndTap(tester, 'Transport');
    await scrollAndTap(tester, 'Save transaction');

    // No false "Added": the failure, with a retry, and nothing saved.
    expect(repo.items, isEmpty);
    expect(find.textContaining('Added'), findsNothing);
    expect(find.text('Not saved. ${FakeTransactionRepository.offline}'),
        findsOneWidget);

    // Still offline: says so again, still offering to retry.
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.items, isEmpty);
    expect(find.text('Try again'), findsOneWidget);

    // Back online: the same entry is saved, without typing it again.
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.items.single.description, 'Taxi');
    expect(repo.items.single.amount, 300);
    expect(find.text('Added "Taxi"'), findsOneWidget);
  });

  testWidgets('A failed edit keeps the old values and can be retried',
      (WidgetTester tester) async {
    final repo = await pumpApp(tester);
    repo.failWrites = 1;

    await scrollAndTap(tester, 'Lunch');
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'), 'Team lunch');
    await scrollAndTap(tester, 'Save changes');

    expect(repo.items.firstWhere((t) => t.id == 't1').description, 'Lunch');
    expect(find.text('Saved changes'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(repo.items.firstWhere((t) => t.id == 't1').description,
        'Team lunch');
    expect(find.text('Saved changes'), findsOneWidget);
  });

  testWidgets('Amount allows at most 2 decimal places',
      (WidgetTester tester) async {
    await pumpApp(tester, repository: FakeTransactionRepository());

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'), '10.999');
    await scrollAndTap(tester, 'Save transaction');
    await scrollToTop(tester);

    expect(find.text('Use at most 2 decimal places', skipOffstage: false),
        findsOneWidget);
  });

  testWidgets('Tapping a transaction edits it', (WidgetTester tester) async {
    final repo = await pumpApp(tester);

    await scrollAndTap(tester, 'Lunch');
    await tester.pumpAndSettle();
    expect(find.text('Edit transaction'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'), 'Team lunch');
    await scrollAndTap(tester, 'Save changes');

    expect(repo.items.firstWhere((t) => t.id == 't1').description,
        'Team lunch');
    expect(find.text('Team lunch'), findsOneWidget);
  });

  testWidgets('Deleting a transaction removes it',
      (WidgetTester tester) async {
    final repo = await pumpApp(tester);

    await scrollAndTap(tester, 'Lunch');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(repo.items.map((t) => t.id), isNot(contains('t1')));
    await showRecent(tester);
    expect(find.text('Lunch'), findsNothing);
  });

  testWidgets('A load error shows a message and a retry button',
      (WidgetTester tester) async {
    final repo = FakeTransactionRepository(testTransactions())
      ..loadError = const DataException('Can\'t reach the server.');
    await pumpApp(tester, repository: repo);

    await showRecent(tester);
    expect(find.text('Can\'t reach the server.'), findsOneWidget);

    repo.loadError = null;
    // The monthly overview offers a Retry too; this is the list's.
    await tester.ensureVisible(find.text('Retry').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry').last);
    await tester.pumpAndSettle();

    await showRecent(tester);
    expect(find.text('Lunch'), findsOneWidget);
  });

  testWidgets('Signed-out users see the login screen',
      (WidgetTester tester) async {
    await pumpApp(tester, auth: FakeAuthService());

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Available balance'), findsNothing);
  });

  testWidgets('Login validates empty input', (WidgetTester tester) async {
    await pumpApp(tester, auth: FakeAuthService());

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
  });

  testWidgets('Signing in shows the dashboard', (WidgetTester tester) async {
    await pumpApp(tester, auth: FakeAuthService());

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'me@example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'secret123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Available balance'), findsOneWidget);
  });

  testWidgets('Login shows a friendly error on failure',
      (WidgetTester tester) async {
    final auth = FakeAuthService()
      ..nextError = const AuthException('Incorrect email or password.');
    await pumpApp(tester, auth: auth);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'me@example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'wrong');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect email or password.'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('Registering signs in and closes the register screen',
      (WidgetTester tester) async {
    await pumpApp(tester, auth: FakeAuthService());

    await scrollAndTap(tester, 'Create an account'); // below "Forgot password?"
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Ann');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'ann@example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'secret123');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'), 'secret12');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text("Passwords don't match"), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'), 'secret123');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your account'), findsNothing);
    expect(find.text('Available balance'), findsOneWidget);
  });

  testWidgets('Sign out returns to the login screen',
      (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back'), findsOneWidget);
  });
}
