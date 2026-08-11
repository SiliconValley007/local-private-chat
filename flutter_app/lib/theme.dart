import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Corner radii used across the app, so every surface feels part of one family.
class AppRadius {
  const AppRadius._();

  static const double card = 20;
  static const double bubble = 22;
  static const double field = 16;
  static const double sheet = 28;
  static const double pill = 999;
}

/// Brand colours that aren't part of the Material scheme.
class AppColors {
  const AppColors._();

  static const Color brand = Color(0xFF0E7C66);
  static const Color brandDeep = Color(0xFF0A5D4C);
  static const Color accent = Color(0xFF3DDC97);
  static const Color online = Color(0xFF22C55E);
  static const Color unread = Color(0xFF0E7C66);

  /// Outgoing bubble, incoming bubble, and the chat canvas behind them.
  static const Color bubbleMine = Color(0xFFD5F2E5);
  static const Color bubbleMineEdge = Color(0xFFB9E8D4);
  static const Color bubblePeer = Colors.white;
  static const Color chatCanvas = Color(0xFFEFF4F2);

  static Color chatCanvasFor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF0D1714)
      : chatCanvas;

  static Color bubbleMineFor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF174D40)
      : bubbleMine;

  static Color bubblePeerFor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF1A2421)
      : bubblePeer;
}

/// Soft, low-contrast elevation. Material's default shadows are too heavy here.
List<BoxShadow> softShadow({
  Color color = Colors.black,
  double opacity = 0.05,
  double blur = 14,
  Offset offset = const Offset(0, 4),
}) {
  return [
    BoxShadow(
      color: color.withValues(alpha: opacity),
      blurRadius: blur,
      offset: offset,
    ),
  ];
}

/// Page background used by the auth, gate and onboarding-style screens.
LinearGradient appBackgroundGradient(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      scheme.primary.withValues(alpha: 0.10),
      dark ? const Color(0xFF0D1513) : const Color(0xFFF6F9F8),
      AppColors.accent.withValues(alpha: 0.10),
    ],
  );
}

ThemeData buildAppTheme({Brightness brightness = Brightness.light}) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xFF4DD6B2) : AppColors.brand,
    tertiary: AppColors.accent,
    surface: dark ? const Color(0xFF151E1B) : Colors.white,
  );

  final text = GoogleFonts.plusJakartaSansTextTheme(
    dark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
  ).apply(
    bodyColor: base.onSurface,
    displayColor: base.onSurface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: base,
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    brightness: brightness,
    scaffoldBackgroundColor: dark
        ? const Color(0xFF0D1513)
        : const Color(0xFFF6F9F8),
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: base.surface,
      surfaceTintColor: base.surface,
      foregroundColor: base.onSurface,
      titleTextStyle: text.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: base.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: base.surface,
      surfaceTintColor: base.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
      titleTextStyle: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      subtitleTextStyle: text.bodySmall?.copyWith(
        color: base.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF202B27) : const Color(0xFFF1F5F3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide(color: base.primary, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide(color: base.error, width: 1.2),
      ),
      helperStyle: text.bodySmall?.copyWith(color: base.onSurfaceVariant),
      labelStyle: text.bodyMedium?.copyWith(color: base.onSurfaceVariant),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        textStyle: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        side: BorderSide(color: base.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: base.primary,
      foregroundColor: base.onPrimary,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: base.surface,
      surfaceTintColor: base.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark
          ? const Color(0xFF2A3E38)
          : const Color(0xFF15302A),
      contentTextStyle: text.bodyMedium?.copyWith(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: base.surface,
      surfaceTintColor: base.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: base.outlineVariant.withValues(alpha: 0.5),
      thickness: 1,
      space: 1,
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      side: BorderSide(color: base.outlineVariant),
      backgroundColor: base.surface,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: base.primary,
      linearMinHeight: 3,
    ),
  );
}
