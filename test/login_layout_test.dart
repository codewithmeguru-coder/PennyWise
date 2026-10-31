import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/theme/appearance.dart';

import 'fake_auth_service.dart';
import 'test_app.dart';

// The sign-in screens fit narrow and normal phones, in light and dark,
// with nothing cut off (any overflow fails the test).

const widths = {
  'very narrow (280)': Size(280, 560),
  'small phone (320)': Size(320, 568),
  'normal phone (393)': Size(393, 873),
};

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final entry in widths.entries) {
      testWidgets('sign in and register fit: ${entry.key}, ${mode.name}', (
        tester,
      ) async {
        tester.view.physicalSize = entry.value * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await pumpApp(
          tester,
          auth: FakeAuthService(), // signed out
          appearance: AppearanceController(
            store: MemoryAppearanceStore(mode),
          ),
        );
        expect(tester.takeException(), isNull);

        // Every control can be reached and tapped (the form scrolls).
        final scroll = find.byType(Scrollable).first;
        final google = find.text('Continue with Google');
        await tester.scrollUntilVisible(google, 100, scrollable: scroll);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getRect(google).right,
            lessThanOrEqualTo(entry.value.width));

        final register = find.text('Create an account');
        await tester.scrollUntilVisible(register, 100, scrollable: scroll);
        await tester.pumpAndSettle();
        await tester.tap(register);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Already have an account?'),
          100,
          scrollable: find.byType(Scrollable).hitTestable().first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
