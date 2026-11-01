import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth_service.dart';
import 'test_app.dart';

// New passwords need at least 8 characters (matching the Firebase password
// policy to be switched on). Signing in with an existing password is not
// affected.

void main() {
  testWidgets('a 7-character password is refused when registering', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await pumpApp(tester, auth: auth);
    await scrollAndTap(tester, 'Create an account');
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Ann');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'ann@example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'abc1234');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'), 'abc1234');
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 8 characters'), findsOneWidget);
    expect(auth.currentUser, isNull); // nothing was created
  });

  testWidgets('signing in with an existing shorter password still works', (
    tester,
  ) async {
    final auth = FakeAuthService();
    await pumpApp(tester, auth: auth);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'old@example.com');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'), 'abc123');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(auth.currentUser, isNotNull);
  });
}
