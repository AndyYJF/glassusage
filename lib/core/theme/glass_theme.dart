import 'package:flutter/material.dart';

import '../../domain/models/usage_models.dart';

class GlassTheme extends ThemeExtension<GlassTheme> {
  final bool isDark;
  final double refraction;
  final Color accent;
  final Color accent2;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color glassTint;
  final Color glassTint2;
  final Color glassBorder;
  final Color glassBorderSoft;
  final Color hiTop;
  final Color hiBottom;
  final Color hiSide;
  final Color textPrimary;
  final Color textDim;
  final Color textFaint;
  final List<Color> backdropFallbackGradient;

  const GlassTheme({
    required this.isDark,
    required this.refraction,
    required this.accent,
    required this.accent2,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.glassTint,
    required this.glassTint2,
    required this.glassBorder,
    required this.glassBorderSoft,
    required this.hiTop,
    required this.hiBottom,
    required this.hiSide,
    required this.textPrimary,
    required this.textDim,
    required this.textFaint,
    required this.backdropFallbackGradient,
  });

  factory GlassTheme.dark({double refraction = 0.62}) {
    final r = refraction.clamp(0.0, 1.0);
    return GlassTheme(
      isDark: true,
      refraction: r,
      accent: const Color.fromRGBO(10, 132, 255, 1.0),
      accent2: const Color.fromRGBO(175, 82, 222, 1.0),
      success: const Color.fromRGBO(48, 209, 88, 1.0),
      warning: const Color.fromRGBO(255, 214, 10, 1.0),
      danger: const Color.fromRGBO(255, 69, 58, 1.0),
      info: const Color.fromRGBO(100, 210, 255, 1.0),
      glassTint: Color.fromRGBO(255, 255, 255, 0.055 + 0.03 * r),
      glassTint2: Color.fromRGBO(255, 255, 255, 0.035 + 0.02 * r),
      glassBorder: Color.fromRGBO(255, 255, 255, 0.14 + 0.08 * r),
      glassBorderSoft: const Color.fromRGBO(255, 255, 255, 0.10),
      hiTop: Color.fromRGBO(255, 255, 255, 0.30 + 0.25 * r),
      hiBottom: const Color.fromRGBO(255, 255, 255, 0.12),
      hiSide: const Color.fromRGBO(255, 255, 255, 0.10),
      textPrimary: const Color.fromRGBO(245, 246, 252, 1.0),
      textDim: const Color.fromRGBO(245, 246, 252, 0.66),
      textFaint: const Color.fromRGBO(245, 246, 252, 0.40),
      backdropFallbackGradient: const [
        Color(0xFF0B0D1A),
        Color(0xFF131635),
        Color(0xFF1D1430),
      ],
    );
  }

  factory GlassTheme.light({double refraction = 0.62}) {
    final r = refraction.clamp(0.0, 1.0);
    return GlassTheme(
      isDark: false,
      refraction: r,
      accent: const Color.fromRGBO(10, 132, 255, 1.0),
      accent2: const Color.fromRGBO(175, 82, 222, 1.0),
      success: const Color.fromRGBO(40, 185, 78, 1.0),
      warning: const Color.fromRGBO(230, 168, 0, 1.0),
      danger: const Color.fromRGBO(235, 55, 48, 1.0),
      info: const Color.fromRGBO(32, 148, 220, 1.0),
      glassTint: Color.fromRGBO(255, 255, 255, 0.45 + 0.15 * r),
      glassTint2: Color.fromRGBO(255, 255, 255, 0.32 + 0.10 * r),
      glassBorder: const Color.fromRGBO(255, 255, 255, 0.65),
      glassBorderSoft: const Color.fromRGBO(255, 255, 255, 0.42),
      hiTop: const Color.fromRGBO(255, 255, 255, 0.90),
      hiBottom: const Color.fromRGBO(255, 255, 255, 0.35),
      hiSide: const Color.fromRGBO(255, 255, 255, 0.40),
      textPrimary: const Color.fromRGBO(22, 26, 45, 1.0),
      textDim: const Color.fromRGBO(22, 26, 45, 0.66),
      textFaint: const Color.fromRGBO(22, 26, 45, 0.42),
      backdropFallbackGradient: const [
        Color(0xFFEEF1FB),
        Color(0xFFE6ECFF),
        Color(0xFFF4ECFF),
      ],
    );
  }

  static Color sourceColor(String source, [double opacity = 1.0]) {
    final base = switch (source) {
      SourceIds.claude => const Color.fromRGBO(217, 119, 87, 1.0),
      SourceIds.codex => const Color.fromRGBO(118, 208, 174, 1.0),
      SourceIds.cursor => const Color.fromRGBO(138, 143, 255, 1.0),
      SourceIds.antigravity => const Color.fromRGBO(236, 141, 200, 1.0),
      SourceIds.opencode => const Color.fromRGBO(255, 176, 82, 1.0),
      SourceIds.hermes => const Color.fromRGBO(120, 190, 255, 1.0),
      SourceIds.openclaw => const Color.fromRGBO(190, 150, 255, 1.0),
      SourceIds.pi => const Color.fromRGBO(94, 184, 138, 1.0),
      SourceIds.kimi => const Color.fromRGBO(232, 96, 80, 1.0),
      SourceIds.dsh => const Color.fromRGBO(77, 163, 255, 1.0),
      _ => const Color.fromRGBO(122, 162, 255, 1.0),
    };
    return opacity == 1.0 ? base : base.withValues(alpha: opacity);
  }

  static Color statusColor(HealthStatus status) {
    return switch (status) {
      HealthStatus.live => const Color.fromRGBO(48, 209, 88, 1.0),
      HealthStatus.polling => const Color.fromRGBO(100, 210, 255, 1.0),
      HealthStatus.missing => const Color.fromRGBO(142, 142, 147, 0.7),
      HealthStatus.error => const Color.fromRGBO(255, 69, 58, 1.0),
      HealthStatus.disabled => const Color.fromRGBO(142, 142, 147, 0.45),
    };
  }

  static const List<FontFeature> tabularNums = [FontFeature.tabularFigures()];

  static GlassTheme of(BuildContext context) =>
      Theme.of(context).extension<GlassTheme>() ?? GlassTheme.dark();

  static TextStyle tabularStyle({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      fontFeatures: tabularNums,
    );
  }

  static ThemeData buildThemeData({required bool isDark, double refraction = 0.62}) {
    final g = isDark
        ? GlassTheme.dark(refraction: refraction)
        : GlassTheme.light(refraction: refraction);
    return g.toThemeData();
  }

  Color get accentBlue => accent;
  Color get accentTeal => info;
  Color get accentPurple => accent2;
  Color get accentPink => const Color(0xFFFF375F);
  Color get accentAmber => warning;
  Color get glassSurface => glassTint;
  Color get glassElevated =>
      isDark ? const Color.fromRGBO(255, 255, 255, 0.11) : const Color.fromRGBO(255, 255, 255, 0.68);
  Color get glassHover =>
      isDark ? const Color.fromRGBO(255, 255, 255, 0.09) : const Color.fromRGBO(0, 0, 0, 0.05);
  Color get glassBorderStrong => glassBorder;
  Color get specularHighlight => hiTop;
  Color get textSecondary => textDim;
  Color get textTertiary => textFaint;
  Color get bgCanvas => backdropFallbackGradient.first;

  ThemeData toThemeData() {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: 'Segoe UI Variable Display',
      fontFamilyFallback: const ['Segoe UI', 'Microsoft YaHei UI', 'sans-serif'],
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: brightness,
      ).copyWith(
        primary: accent,
        secondary: accent2,
        surface: Colors.transparent,
        onSurface: textPrimary,
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: textPrimary, fontSize: 14),
        bodyMedium: TextStyle(color: textPrimary, fontSize: 13),
        bodySmall: TextStyle(color: textDim, fontSize: 12),
      ),
      extensions: [this],
    );
  }

  @override
  GlassTheme copyWith({
    bool? isDark,
    double? refraction,
  }) {
    final nextDark = isDark ?? this.isDark;
    final nextRef = refraction ?? this.refraction;
    return nextDark
        ? GlassTheme.dark(refraction: nextRef)
        : GlassTheme.light(refraction: nextRef);
  }

  @override
  GlassTheme lerp(ThemeExtension<GlassTheme>? other, double t) {
    if (other is! GlassTheme) return this;
    return t < 0.5 ? this : other;
  }
}

extension GlassThemeContext on BuildContext {
  GlassTheme get glass =>
      Theme.of(this).extension<GlassTheme>() ?? GlassTheme.dark();
}

