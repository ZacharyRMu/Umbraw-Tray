import 'package:flutter/material.dart';

/// Umbraw Tray's palette: near-black ground, warm off-white text and a
/// safelight-orange accent.
abstract final class Tone {
  static const bg = Color(0xFF141311);
  static const surface = Color(0xFF1D1B18);
  static const line = Color(0xFF2A2723);
  static const lineSoft = Color(0xFF22201C);
  static const outline = Color(0xFF4A453E);
  static const text = Color(0xFFECE6DC);
  static const muted = Color(0xFFA39B8E);
  static const accent = Color(0xFFE8613C);
  static const bad = Color(0xFFFF8A7A);
}

const monoFamily = 'Menlo';
const monoFallback = [
  'SF Mono',
  'Consolas',
  'Cascadia Mono',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'Noto Sans Mono',
  'monospace',
];

TextStyle mono({double size = 13, Color color = Tone.text, FontWeight? weight}) =>
    TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: 1.3,
    );

/// Small uppercase section label: SOURCES, DESTINATION, ...
TextStyle labelStyle() => mono(size: 11, color: Tone.muted)
    .copyWith(letterSpacing: 1.3);

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Tone.accent,
    onPrimary: Tone.bg,
    secondary: Tone.accent,
    onSecondary: Tone.bg,
    surface: Tone.surface,
    onSurface: Tone.text,
    onSurfaceVariant: Tone.muted,
    error: Tone.bad,
    onError: Tone.bg,
    outline: Tone.outline,
    outlineVariant: Tone.line,
  );

  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  const minSize = Size(64, 44);
  const padding = EdgeInsets.symmetric(horizontal: 18);
  const textStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Tone.bg,
    fontFamily: 'Inter',
    dividerColor: Tone.line,
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontSize: 14, color: Tone.text),
      bodySmall: TextStyle(fontSize: 12, color: Tone.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Tone.accent,
        foregroundColor: Tone.bg,
        disabledBackgroundColor: Tone.line,
        disabledForegroundColor: Tone.muted,
        minimumSize: minSize,
        padding: padding,
        shape: shape,
        textStyle: textStyle,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Tone.text,
        disabledForegroundColor: Tone.muted,
        side: const BorderSide(color: Tone.outline),
        minimumSize: minSize,
        padding: padding,
        shape: shape,
        textStyle: textStyle,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Tone.text,
        backgroundColor: Tone.line,
        minimumSize: minSize,
        padding: padding,
        shape: shape,
        textStyle: textStyle,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? Tone.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Tone.bg),
      side: const BorderSide(color: Tone.outline, width: 1.5),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: Tone.line),
      textStyle: TextStyle(color: Tone.text, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Tone.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
