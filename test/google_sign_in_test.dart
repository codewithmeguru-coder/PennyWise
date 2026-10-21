import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_auth_service.dart';
import 'test_app.dart';

void main() {
  testWidgets('login and sign-up screens both offer Google, next to email',
      (tester) async {
    await pumpApp(tester, auth: FakeAuthService());

    expect(find.text('Sign in'), findsOneWidget); // email option still there
    await tester.scrollUntilVisible(find.text('Continue with Google'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Continue with Google'), findsOneWidget);

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    expect(find.text('Create account'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Continue with Google'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('Google sign-in from the login screen opens the dashboard',
      (tester) async {
    final auth = FakeAuthService();
    await pumpApp(tester, auth: auth);

    await scrollAndTap(tester, 'Continue with Google');

    expect(auth.googleCalls, 1);
    expect(find.text('Total balance'), findsOneWidget);
    expect(find.text('Welcome back'), findsNothing);
  });

  testWidgets('Google sign-in from sign-up closes it and opens the dashboard',
      (tester) async {
    await pumpApp(tester, auth: FakeAuthService());

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    await scrollAndTap(tester, 'Continue with Google');

    expect(find.text('Create your account'), findsNothing);
    expect(find.text('Total balance'), findsOneWidget);
  });

  testWidgets('closing the Google picker is not an error', (tester) async {
    final auth = FakeAuthService()..googleOutcome = FakeGoogleOutcome.cancel;
    await pumpApp(tester, auth: auth);

    await scrollAndTap(tester, 'Continue with Google');

    expect(auth.googleCalls, 1);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    // The button is usable again.
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('a failed Google sign-in shows a friendly error',
      (tester) async {
    final auth = FakeAuthService()..googleOutcome = FakeGoogleOutcome.error;
    await pumpApp(tester, auth: auth);

    await scrollAndTap(tester, 'Continue with Google');

    expect(
        find.text('Google sign-in failed. Check your connection and try again.'),
        findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('the sign-out dialog shows the Google name and email',
      (tester) async {
    await pumpApp(tester,
        auth: FakeAuthService(signedInAs: FakeAuthService.googleUser));

    await tester.tap(find.byTooltip('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Ann Google'), findsOneWidget);
    expect(find.text('ann@gmail.com'), findsOneWidget);
  });
}
