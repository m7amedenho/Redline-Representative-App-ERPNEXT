import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Central color palette for Red ERP. Change values here to re-theme the app.
class AppColors {
  AppColors._();

  static const Color black = Color(0xFF0D0D0D);
  static const Color white = Color(0xFFFFFFFF);
  static const Color lightGray = Color(0xFFF5F5F5);
  static const Color midGray = Color(0xFF7A7A7A);
  static const Color accent = Color(0xFFD62828);
  static const Color success = Color(0xFF1E7A3C);
}

class AppRadius {
  AppRadius._();

  static const double card = 20.0;
  static const double button = 18.0;
  static const double field = 16.0;
}

class AppTheme {
  AppTheme._();

  static ThemeData get theme {
    final base = ThemeData(useMaterial3: true, brightness: Brightness.light);

    final textTheme = GoogleFonts.ibmPlexSansArabicTextTheme(
      base.textTheme,
    ).apply(bodyColor: AppColors.black, displayColor: AppColors.black);

    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.light,
        ).copyWith(
          primary: AppColors.accent,
          onPrimary: AppColors.white,
          secondary: AppColors.black,
          onSecondary: AppColors.white,
          surface: AppColors.white,
          onSurface: AppColors.black,
          error: AppColors.accent,
        );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.white,
      textTheme: textTheme,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.white,
        foregroundColor: AppColors.black,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: GoogleFonts.ibmPlexSansArabic(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.black,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.white,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: AppColors.white,
          disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.5),
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          textStyle: GoogleFonts.ibmPlexSansArabic(
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
          elevation: 0,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.midGray,
          textStyle: GoogleFonts.ibmPlexSansArabic(fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.lightGray,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
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
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.2),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.field),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        hintStyle: GoogleFonts.ibmPlexSansArabic(color: AppColors.midGray),
        labelStyle: GoogleFonts.ibmPlexSansArabic(color: AppColors.midGray),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: AppColors.white,
        selectedItemColor: AppColors.accent,
        unselectedItemColor: AppColors.midGray,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
        selectedLabelStyle: GoogleFonts.ibmPlexSansArabic(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: GoogleFonts.ibmPlexSansArabic(fontSize: 12),
        elevation: 8,
      ),
    );
  }
}
