import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pennywise/accounts/money_account.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/data/transaction_store.dart';
import 'package:pennywise/models/ledger.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/reports/fuliza_report.dart';
import 'package:pennywise/screens/fuliza_report_screen.dart';
import 'package:pennywise/services/auth_service.dart';
import 'package:pennywise/theme/app_theme.dart';
import 'package:pennywise/theme/appearance.dart';
import 'package:pennywise/widgets/welcome_greeting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_service.dart';
import 'fake_avatar.dart';
import 'fake_transaction_repository.dart';
import 'test_app.dart';

// Appearance (Light / Dark / System), the Home greeting beside the photo,
// and the Fuliza fee report's month-by-SIM table. Names, codes and amounts
// are made up.

/// A real 1×1 PNG, so it can actually be drawn.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const ann = AppUser(
  uid: 'u-ann',
  email: 'ann@example.com',
  displayName: 'Ann Wanjiru',
);

ThemeMode appMode(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

/// The brightness the screen on show is actually drawn with.
Brightness shown(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(Scaffold).last)).brightness;

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Settings').first);
  await tester.pumpAndSettle();
}

Future<void> pickAppearance(WidgetTester tester, String key) async {
  final button = find.byKey(Key(key));
  await tester.scrollUntilVisible(
    button,
    300,
    scrollable: find.byType(Scrollable).hitTestable().first,
  );
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

TransactionModel loan(String code, DateTime date, double amount, double fee,
        {int sim = 0}) =>
    TransactionModel(
      id: 'mpesa_${code}_FULIZA',
      description: 'Fuliza loan',
      amount: amount,
      type: TransactionType.transfer,
      categoryId: 'transfer',
      date: date,
      source: TransactionSource.mpesa,
      reference: code,
      smsText: '$code Confirmed. Fuliza M-PESA amount is Ksh $amount.',
      toAccount: Account.mpesa,
      fee: fee,
      accountId: 'fuliza-sim${sim + 1}',
      toAccountId: 'mpesa-sim${sim + 1}',
      simSlot: sim,
    );

TransactionModel repay(String code, DateTime date, double amount,
        {int sim = 0}) =>
    TransactionModel(
      id: 'mpesa_$code',
      description: 'Fuliza repayment',
      amount: amount,
      type: TransactionType.debtRepayment,
      categoryId: 'debt_repayment',
      date: date,
      source: TransactionSource.mpesa,
      reference: code,
      smsText:
          '$code Confirmed. Ksh $amount from your M-PESA has been used to '
          'fully pay your outstanding Fuliza M-PESA.',
      account: Account.mpesa,
      accountId: 'mpesa-sim${sim + 1}',
      toAccountId: 'fuliza-sim${sim + 1}',
      simSlot: sim,
    );

final fuliza = [
  loan('UQ1', DateTime(2026, 9, 3, 10), 100, 1.00),
  loan('UQ2', DateTime(2026, 9, 20, 10), 50, 0.50, sim: 1),
  repay('UQ3', DateTime(2026, 9, 25, 10), 101),
  loan('UQ4', DateTime(2026, 10, 2, 10), 30, 0.30),
  loan('UQ5', DateTime(2026, 10, 5, 10), 200, 2.00, sim: 1),
  repay('UQ6', DateTime(2026, 10, 9, 10), 252.50, sim: 1),
];

void main() {
  group('appearance', () {
    testWidgets('starts on System default', (tester) async {
      await pumpApp(tester);
      expect(appMode(tester), ThemeMode.system);
      await openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('appearance-current')),
        300,
        scrollable: find.byType(Scrollable).hitTestable().first,
      );
      expect(find.text('System default'), findsOneWidget);
    });

    testWidgets('System default follows the phone', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpApp(tester);
      expect(shown(tester), Brightness.dark);
    });

    testWidgets('Dark and Light apply at once, whatever the phone uses, and '
        'are saved', (tester) async {
      final store = MemoryAppearanceStore();
      await pumpApp(
        tester,
        appearance: AppearanceController(store: store),
      );
      expect(shown(tester), Brightness.light);
      await openSettings(tester);

      await pickAppearance(tester, 'appearance-dark');
      expect(appMode(tester), ThemeMode.dark);
      expect(shown(tester), Brightness.dark);
      expect(store.saved, ThemeMode.dark);
      expect(find.text('Dark'), findsWidgets);

      // Settings stayed open: nothing was rebuilt from scratch.
      expect(find.text('Settings'), findsOneWidget);

      await pickAppearance(tester, 'appearance-light');
      expect(shown(tester), Brightness.light);
      expect(store.saved, ThemeMode.light);

      await pickAppearance(tester, 'appearance-system');
      expect(store.saved, ThemeMode.system);
    });

    testWidgets('the choice is back after a restart', (tester) async {
      final store = MemoryAppearanceStore(ThemeMode.dark);
      await pumpApp(tester, appearance: AppearanceController(store: store));
      expect(appMode(tester), ThemeMode.dark);
      expect(shown(tester), Brightness.dark);
    });

    test('kept on the phone; anything unreadable means System', () async {
      SharedPreferences.setMockInitialValues({});
      final a = AppearanceController(store: SharedPrefsAppearanceStore());
      await a.init();
      expect(a.value, ThemeMode.system);
      await a.choose(ThemeMode.dark);

      final restarted = AppearanceController(store: SharedPrefsAppearanceStore());
      await restarted.init();
      expect(restarted.value, ThemeMode.dark);

      SharedPreferences.setMockInitialValues({
        SharedPrefsAppearanceStore.key: 'purple',
      });
      final odd = AppearanceController(store: SharedPrefsAppearanceStore());
      await odd.init();
      expect(odd.value, ThemeMode.system);
    });

    test('a store that fails leaves System and still switches', () async {
      final a = AppearanceController(store: _BrokenStore());
      await a.init();
      expect(a.value, ThemeMode.system);
      await a.choose(ThemeMode.dark);
      expect(a.value, ThemeMode.dark);
    });

    test('text and amounts stay readable on both themes\' cards', () {
      for (final p in [AppPalette.light, AppPalette.dark]) {
        for (final bg in [p.surface, p.background]) {
          expect(contrast(p.textPrimary, bg), greaterThan(7));
          expect(contrast(p.textSecondary, bg), greaterThan(4.3));
        }
        expect(contrast(p.onPrimary, p.primary), greaterThan(4.3));
        // White text on the green header cards.
        expect(contrast(Colors.white, p.heroStart), greaterThan(4.3));
        expect(contrast(Colors.white, p.primaryDark), greaterThan(4.3));
      }
      final d = AppPalette.dark;
      for (final c in [
        d.primary,
        d.income,
        d.expense,
        d.warning,
        d.savings,
        d.neutral,
      ]) {
        expect(contrast(c, d.surface), greaterThan(4.5));
      }
    });

    testWidgets('key screens draw in Dark with dark cards and light text', (
      tester,
    ) async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);

      await pumpApp(
        tester,
        auth: FakeAuthService(signedInAs: ann),
        appearance: AppearanceController(
          store: MemoryAppearanceStore(ThemeMode.dark),
        ),
      );
      final dark = AppPalette.dark;
      final greeting = tester.widget<Text>(find.byKey(const Key('home-greeting')));
      expect(greeting.style!.color, dark.textPrimary);
      final card = Theme.of(tester.element(find.byType(Card).first));
      expect(card.cardTheme.color, dark.surface);
      expect(card.scaffoldBackgroundColor, dark.background);

      for (final tab in ['Transactions', 'Budgets', 'Home']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        expect(shown(tester), Brightness.dark);
      }

      // A dialog takes the dark surface too.
      await tester.tap(find.byTooltip('Sign out'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        Theme.of(tester.element(dialog)).dialogTheme.backgroundColor,
        dark.surface,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await openSettings(tester);
      expect(shown(tester), Brightness.dark);
      expect(errors, isEmpty);
    });

    testWidgets('the Fuliza report and its charts draw in both themes', (
      tester,
    ) async {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: FulizaReportScreen(
              store: TransactionStore(FakeTransactionRepository(fuliza)),
              accounts: MoneyAccount.starterSet(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('fuliza-month-table')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);
        final label = tester.widget<Text>(
          find.descendant(
            of: find.byKey(const Key('fuliza-month-table')),
            matching: find.text('Month'),
          ),
        );
        expect(
          label.style!.color,
          theme.extension<AppPalette>()!.textSecondary,
        );
      }
    });
  });

  group('welcome greeting', () {
    test('first name and time of day', () {
      expect(WelcomeGreeting.text(ann, DateTime(2026, 10, 1, 8)),
          'Good morning, Ann');
      expect(WelcomeGreeting.text(ann, DateTime(2026, 10, 1, 13)),
          'Good afternoon, Ann');
      expect(WelcomeGreeting.text(ann, DateTime(2026, 10, 1, 19)),
          'Good evening, Ann');
      const spaced = AppUser(uid: 'x', email: 'x@y.z', displayName: '  Bea  ');
      expect(WelcomeGreeting.firstName(spaced), 'Bea');
    });

    test('no name: "Welcome back", never the email', () {
      for (final name in [null, '', '   ']) {
        final u = AppUser(uid: 'x', email: 'jane@example.com', displayName: name);
        expect(WelcomeGreeting.text(u, DateTime(2026, 10, 1, 8)),
            'Welcome back');
      }
    });

    testWidgets('Home greets by first name beside the uploaded photo', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthService(signedInAs: ann),
        avatars: (_) => FakeAvatarRepository(png),
      );
      final text = tester.widget<Text>(find.byKey(const Key('home-greeting')));
      expect(text.data, endsWith(', Ann'));
      final avatar = tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.byType(CircleAvatar),
        ),
      );
      expect(avatar.foregroundImage, isA<MemoryImage>());
    });

    testWidgets('no uploaded photo: the Google photo, else the initial', (
      tester,
    ) async {
      const google = AppUser(
        uid: 'g',
        email: 'g@example.com',
        displayName: 'Ann Google',
        photoUrl: 'https://example.com/a.png',
      );
      await pumpApp(tester, auth: FakeAuthService(signedInAs: google));
      CircleAvatar homeAvatar() => tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.byType(CircleAvatar),
        ),
      );
      expect(homeAvatar().foregroundImage, isA<NetworkImage>());
      // The initial sits underneath, for when the photo can't load.
      expect(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.text('A'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('email account without a name or photo', (tester) async {
      await pumpApp(tester); // test@example.com, no name
      expect(find.text('Welcome back'), findsOneWidget);
      final avatar = tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.byType(CircleAvatar),
        ),
      );
      expect(avatar.foregroundImage, isNull);
      expect(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.text('T'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a photo that fails to load leaves the initial', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthService(signedInAs: ann),
        avatars: (_) => FakeAvatarRepository()..loadError = _loadError,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.text('A'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('after switching profile, the other person\'s name and photo '
        'are gone', (tester) async {
      final auth = FakeAuthService(signedInAs: ann);
      final photos = {ann.uid: FakeAvatarRepository(png)};
      await pumpApp(
        tester,
        auth: auth,
        avatars: (uid) => photos.putIfAbsent(uid, FakeAvatarRepository.new),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('home-greeting'))).data,
        endsWith(', Ann'),
      );
      await auth.signOut();
      await tester.pumpAndSettle();
      await auth.register(
        name: 'Bea Otieno',
        email: 'bea@example.com',
        password: 'secret12',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('home-greeting'))).data,
        endsWith(', Bea'),
      );
      final avatar = tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byType(WelcomeGreeting),
          matching: find.byType(CircleAvatar),
        ),
      );
      expect(avatar.foregroundImage, isNull);
    });
  });

  group('Fuliza fees by month and SIM', () {
    final accounts = MoneyAccount.starterSet();

    test('fees stay apart from loans and repayments, and match what Home '
        'counts as spending', () {
      final report = FulizaReport.build(fuliza, accounts: accounts);
      final t = report.totals;
      expect(t.fees, closeTo(3.80, 0.001));
      expect(t.borrowed, 380);
      expect(t.repaid, 353.50);

      for (final month in [DateTime(2026, 9), DateTime(2026, 10)]) {
        final inMonth = [
          for (final x in fuliza)
            if (x.date.year == month.year && x.date.month == month.month) x,
        ];
        final ledger = Ledger.of(inMonth);
        final fees = report.monthlyFees[month]!.values.fold(0.0, (a, b) => a + b);
        // Only the fees are spending: loans and repayments are moves.
        expect(ledger.spending, closeTo(fees, 0.001));
        expect(ledger.fees, closeTo(fees, 0.001));
        expect(ledger.income, 0);
      }
      expect(report.monthlyFees[DateTime(2026, 9)], {0: 1.00, 1: 0.50});
      expect(report.monthlyFees[DateTime(2026, 10)], {0: 0.30, 1: 2.00});
    });

    testWidgets('the table: newest month first, a column per SIM, a total', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: FulizaReportScreen(
            store: TransactionStore(FakeTransactionRepository(fuliza)),
            accounts: accounts,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = find.byKey(const Key('fuliza-month-table'));
      await tester.scrollUntilVisible(
        table,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      List<String> texts() => [
        for (final t in tester.widgetList<Text>(
          find.descendant(of: table, matching: find.byType(Text)),
        ))
          t.data!,
      ];
      expect(texts(), [
        'Month', 'SIM 1', 'SIM 2', 'Total', //
        'October 2026', 'KSh 0.30', 'KSh 2.00', 'KSh 2.30',
        'September 2026', 'KSh 1.00', 'KSh 0.50', 'KSh 1.50',
      ]);

      // One SIM: just its fees.
      await tester.scrollUntilVisible(
        find.text('All time'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('SIM 2').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        table,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(texts(), [
        'Month', 'Fees', //
        'October 2026', 'KSh 2.00',
        'September 2026', 'KSh 0.50',
      ]);
    });
  });
}

const _loadError = DataException('No connection.');

class _BrokenStore implements AppearanceStore {
  @override
  Future<ThemeMode?> load() => Future.error(Exception('unreadable'));

  @override
  Future<void> save(ThemeMode mode) => Future.error(Exception('full'));
}
