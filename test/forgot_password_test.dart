import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/screens/auth/auth_widgets.dart';
import 'package:pennywise/screens/auth/forgot_password_screen.dart';
import 'package:pennywise/services/auth_service.dart';

import 'fake_auth_service.dart';
import 'test_app.dart';

// "Forgot password?": validation, loading, the one neutral success message
// (never revealing whether an email is registered), friendly errors and the
// 60-second resend wait. No Firebase: FakeAuthService only.

const neutral = 'If a PennyWise account with a password uses';
const googleHint = 'If you use Continue with Google, sign in that way instead.';

Finder sendButton() => find.byType(AuthSubmitButton);
AuthSubmitButton button(WidgetTester tester) =>
    tester.widget<AuthSubmitButton>(sendButton());

Future<void> showReset(
  WidgetTester tester,
  FakeAuthService auth, {
  String email = '',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // A new key each time, so a second screen in one test starts fresh.
      home: ForgotPasswordScreen(
        key: UniqueKey(),
        authService: auth,
        initialEmail: email,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> typeEmail(WidgetTester tester, String email) =>
    tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);

Future<void> tapSend(WidgetTester tester) async {
  await tester.tap(sendButton());
  await tester.pump();
}

void main() {
  group('validation', () {
    test('the email check matches sign-in', () {
      expect(AuthValidators.email(''), 'Enter your email');
      expect(AuthValidators.email('   '), 'Enter your email');
      expect(AuthValidators.email('ann@'), 'Enter a valid email');
      expect(AuthValidators.email('ann example.com'), 'Enter a valid email');
      expect(AuthValidators.email('  ann@example.com  '), isNull);
    });

    testWidgets('an empty or malformed email isn\'t sent', (tester) async {
      final auth = FakeAuthService();
      await showReset(tester, auth);
      await tapSend(tester);
      expect(find.text('Enter your email'), findsOneWidget);
      await typeEmail(tester, 'ann@nowhere');
      await tapSend(tester);
      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(auth.resetRequests, isEmpty);
    });

    testWidgets('spaces around the address are trimmed', (tester) async {
      final auth = FakeAuthService();
      await showReset(tester, auth);
      await typeEmail(tester, '  ann@example.com  ');
      await tapSend(tester);
      await tester.pumpAndSettle();
      expect(auth.resetRequests, ['ann@example.com']);
    });
  });

  group('success never reveals whether an account exists', () {
    Future<String> successText(WidgetTester tester, String email) async {
      final auth = FakeAuthService();
      await showReset(tester, auth, email: email);
      await tapSend(tester);
      await tester.pumpAndSettle();
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((t) => t.contains(neutral) || t == googleHint)
          .join(' | ');
      return texts.replaceAll(email, '<email>');
    }

    testWidgets('a known and an unknown email get exactly the same words', (
      tester,
    ) async {
      final known = await successText(tester, FakeAuthService.testUser.email);
      final unknown = await successText(tester, 'nobody@example.com');
      expect(known, contains(neutral));
      expect(known, contains(googleHint));
      expect(unknown, known);
    });

    test(
      '"no such account" and "disabled" map to success, never a message',
      () {
        expect(
          FirebaseAuthService.resetMessageForCode('user-not-found'),
          isNull,
        );
        expect(
          FirebaseAuthService.resetMessageForCode('user-disabled'),
          isNull,
        );
      },
    );

    test('other Firebase codes map to friendly text, never the raw error', () {
      expect(
        FirebaseAuthService.resetMessageForCode('invalid-email'),
        'That email address doesn\'t look right.',
      );
      expect(
        FirebaseAuthService.resetMessageForCode('missing-email'),
        'Enter your email.',
      );
      expect(
        FirebaseAuthService.resetMessageForCode('network-request-failed'),
        'No internet connection. Check your network and try again.',
      );
      expect(
        FirebaseAuthService.resetMessageForCode('too-many-requests'),
        'Too many attempts. Please wait a moment and try again.',
      );
      expect(
        FirebaseAuthService.resetMessageForCode('internal-error'),
        'Couldn\'t send the reset email. Please try again.',
      );
    });
  });

  group('states', () {
    testWidgets('loading: spinner, field and button off; a double tap sends '
        'once', (tester) async {
      final auth = FakeAuthService()..resetHold = Completer<void>();
      await showReset(tester, auth, email: 'ann@example.com');
      await tapSend(tester);
      expect(button(tester).loading, isTrue);
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Email'))
            .enabled,
        isFalse,
      );
      await tester.tap(sendButton(), warnIfMissed: false);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(auth.resetRequests, hasLength(1));
      auth.resetHold!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining(neutral), findsOneWidget);
    });

    testWidgets('no connection and too many requests: friendly messages, '
        'no success shown, no countdown', (tester) async {
      final auth = FakeAuthService()
        ..nextResetError = const AuthException(
          'No internet connection. Check your network and try again.',
        );
      await showReset(tester, auth, email: 'ann@example.com');
      await tapSend(tester);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'No internet connection. Check your network and try '
          'again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(neutral), findsNothing);
      expect(button(tester).label, 'Send reset link');
      expect(button(tester).onPressed, isNotNull);

      auth.nextResetError = const AuthException(
        'Too many attempts. Please wait a moment and try again.',
      );
      await tapSend(tester);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Too many attempts. Please wait a moment and try '
          'again.',
        ),
        findsOneWidget,
      );
      expect(auth.resetRequests, hasLength(2));
    });

    testWidgets('resend waits 60 seconds, then works', (tester) async {
      final auth = FakeAuthService();
      await showReset(tester, auth, email: 'ann@example.com');
      await tapSend(tester);
      await tester.pump();
      expect(button(tester).label, 'Resend in 60s');
      expect(button(tester).onPressed, isNull);

      await tester.tap(sendButton(), warnIfMissed: false);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump(const Duration(seconds: 30));
      expect(button(tester).label, 'Resend in 30s');
      expect(auth.resetRequests, hasLength(1));

      await tester.pump(const Duration(seconds: 30));
      expect(button(tester).label, 'Resend link');
      expect(button(tester).onPressed, isNotNull);
      await tapSend(tester);
      await tester.pump();
      expect(auth.resetRequests, hasLength(2));
      expect(button(tester).label, 'Resend in 60s');
      // Leave no timer running.
      await tester.pump(const Duration(seconds: 61));
    });
  });

  group('from the sign-in screen', () {
    testWidgets('"Forgot password?" opens it with the typed email; back keeps '
        'it', (tester) async {
      final auth = FakeAuthService();
      await pumpApp(tester, auth: auth);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'ann@example.com',
      );
      await scrollAndTap(tester, 'Forgot password?');
      expect(find.text('Reset your password'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'ann@example.com'),
        findsOneWidget,
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'ann2@example.com',
      );
      await tester.tap(find.text('Back to sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'ann2@example.com'),
        findsOneWidget,
      );
      expect(auth.resetRequests, isEmpty);
    });

    testWidgets('the link is shown on the sign-in screen and enabled', (tester) async {
      final auth = FakeAuthService();
      await pumpApp(tester, auth: auth);
      final link = find.widgetWithText(TextButton, 'Forgot password?');
      expect(tester.widget<TextButton>(link).onPressed, isNotNull);
    });
  });
}
