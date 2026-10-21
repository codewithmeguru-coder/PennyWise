import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pennywise/app.dart';

import 'fake_auth_service.dart';
import 'fake_budget_repository.dart';
import 'fake_sms.dart';
import 'fake_transaction_repository.dart';

/// Pumps the app with fake auth and data (so neither Firebase Auth nor
/// Firestore is needed) and waits for the streams to settle.
Future<FakeTransactionRepository> pumpApp(
  WidgetTester tester, {
  FakeTransactionRepository? repository,
  FakeBudgetRepository? budgets,
  FakeAuthService? auth,
  FakeSmsGateway? sms,
  FakeSmsSettings? smsSettings,
}) async {
  final repo = repository ?? FakeTransactionRepository(testTransactions());
  final budgetRepo = budgets ?? FakeBudgetRepository();
  await tester.pumpWidget(PennyWiseApp(
    authService:
        auth ?? FakeAuthService(signedInAs: FakeAuthService.testUser),
    repositoryForUser: (_) => repo,
    budgetRepositoryForUser: (_) => budgetRepo,
    smsGateway: sms ?? FakeSmsGateway(),
    smsSettingsForUser: (_) => smsSettings ?? FakeSmsSettings(),
  ));
  await tester.pumpAndSettle();
  return repo;
}

/// Scrolls the open screen until [label] is visible, then taps it.
Future<void> scrollAndTap(WidgetTester tester, String label) async {
  // A focused text field keeps scrolling itself back into view; on a phone
  // the keyboard would be dismissed first anyway.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text(label),
    300,
    // The visible screen's list: routes underneath (e.g. the dashboard
    // behind a form) are still in the tree but can't be hit.
    scrollable: find.byType(Scrollable).hitTestable().first,
  );
  await tester.ensureVisible(find.text(label)); // fully, not just partly
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

/// Scrolls the open screen back to its top, e.g. to read validation errors
/// on the first fields after tapping a button at the bottom of a long form
/// (a lazily built list drops rows that are far off screen).
Future<void> scrollToTop(WidgetTester tester) async {
  await tester.drag(
      find.byType(Scrollable).hitTestable().first, const Offset(0, 3000));
  await tester.pumpAndSettle();
}
