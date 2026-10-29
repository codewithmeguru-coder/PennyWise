import 'package:flutter/material.dart';

/// Central place for PennyWise colours and the app-wide [ThemeData].
///
/// Widgets read colours with `context.colors` (an [AppPalette]), so every
/// screen follows the Light / Dark / System choice in Settings. Material
/// parts (buttons, dialogs, fields) follow the [ColorScheme].
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.primary,
    required this.onPrimary,
    required this.heroStart,
    required this.primaryDark,
    required this.background,
    required this.surface,
    required this.income,
    required this.expense,
    required this.neutral,
    required this.savings,
    required this.warning,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
  });

  final Color primary; // PennyWise green

  /// Text and icons on [primary] (buttons, the lock badge).
  final Color onPrimary;

  /// The green header cards ([heroStart] to [primaryDark]) carry white
  /// text in both themes.
  final Color heroStart;
  final Color primaryDark;
  final Color background;
  final Color surface;

  final Color income;
  final Color expense;

  /// Transfers between your own accounts: neither earned nor spent.
  final Color neutral;

  /// Money moved into or out of savings.
  final Color savings;

  /// Budget status: nearing the limit (always paired with an icon + label).
  final Color warning;

  final Color textPrimary;
  final Color textSecondary;
  final Color divider;

  static const AppPalette light = AppPalette(
    primary: Color(0xFF1B8A5A),
    onPrimary: Colors.white,
    heroStart: Color(0xFF1B8A5A),
    primaryDark: Color(0xFF12693F),
    background: Color(0xFFF6F8F7),
    surface: Colors.white,
    income: Color(0xFF1B8A5A),
    expense: Color(0xFFD64545),
    neutral: Color(0xFF5B6B8C),
    savings: Color(0xFF2F7DB5),
    warning: Color(0xFFD98E04),
    textPrimary: Color(0xFF1C2421),
    textSecondary: Color(0xFF6B7772),
    divider: Color(0xFFE3E8E5),
  );

  /// Lighter accents so text and chart lines stay readable on dark cards.
  static const AppPalette dark = AppPalette(
    primary: Color(0xFF2FA872),
    onPrimary: Color(0xFF0F1513),
    heroStart: Color(0xFF1B7A52),
    primaryDark: Color(0xFF15734A),
    background: Color(0xFF0F1513),
    surface: Color(0xFF1A2220),
    income: Color(0xFF4CC38A),
    expense: Color(0xFFFF7B72),
    neutral: Color(0xFF9EADCC),
    savings: Color(0xFF6CB4EA),
    warning: Color(0xFFF5B841),
    textPrimary: Color(0xFFE6ECE9),
    textSecondary: Color(0xFFA3B0AA),
    divider: Color(0xFF2E3935),
  );

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      primary: mix(primary, other.primary),
      onPrimary: mix(onPrimary, other.onPrimary),
      heroStart: mix(heroStart, other.heroStart),
      primaryDark: mix(primaryDark, other.primaryDark),
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      income: mix(income, other.income),
      expense: mix(expense, other.expense),
      neutral: mix(neutral, other.neutral),
      savings: mix(savings, other.savings),
      warning: mix(warning, other.warning),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      divider: mix(divider, other.divider),
    );
  }
}

extension AppColorsOf on BuildContext {
  /// The current theme's colours (light when none is set, as in tests that
  /// pump a bare widget).
  AppPalette get colors =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}

class AppTheme {
  AppTheme._();

  static ThemeData get light => _build(AppPalette.light, Brightness.light);
  static ThemeData get dark => _build(AppPalette.dark, Brightness.dark);

  static ThemeData _build(AppPalette c, Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: c.primary,
      primary: c.primary,
      onPrimary: c.onPrimary,
      surface: c.surface,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      outlineVariant: c.divider,
      error: c.expense,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      extensions: [c],
      scaffoldBackgroundColor: c.background,
      dividerColor: c.divider,
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: c.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.divider),
        ),
      ),
      dialogTheme: DialogThemeData(backgroundColor: c.surface),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        modalBackgroundColor: c.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        indicatorColor: c.primary.withValues(alpha: 0.15),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.primary, width: 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: c.onPrimary,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
