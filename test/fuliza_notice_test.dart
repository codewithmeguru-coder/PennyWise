import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/screens/settings_screen.dart';

// Settings' note about Fuliza messages that were read but not saved: it
// names the real reason.

void main() {
  test('read while automatic import was off: says so and points to Fuliza '
      'history', () {
    final text = fulizaHeldText(106, noAccount: false);
    expect(text, startsWith('106 Fuliza messages were read while'));
    expect(text, contains('"Import Fuliza automatically" was off'));
    expect(text, contains('Fuliza history'));
    expect(text, isNot(contains('loan accounts are available')));
  });

  test('automatic import on: the SIM\'s accounts are missing', () {
    final text = fulizaHeldText(1, noAccount: true);
    expect(text, startsWith('1 Fuliza message was read but not added yet'));
    expect(text, contains("account isn't set up"));
  });
}
