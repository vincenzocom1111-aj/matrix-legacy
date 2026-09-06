import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Reader Theme Enum ────────────────────────────────────────────────────────

enum ReaderTheme { light, sepia, slate, oled }

extension ReaderThemeX on ReaderTheme {
  String get label {
    switch (this) {
      case ReaderTheme.light:
        return 'Light';
      case ReaderTheme.sepia:
        return 'Sepia';
      case ReaderTheme.slate:
        return 'Slate';
      case ReaderTheme.oled:
        return 'OLED';
    }
  }

  Color get backgroundColor {
    switch (this) {
      case ReaderTheme.light:
        return const Color(0xFFFBFAF8);
      case ReaderTheme.sepia:
        return const Color(0xFFF4ECD8);
      case ReaderTheme.slate:
        return const Color(0xFF1E293B);
      case ReaderTheme.oled:
        return const Color(0xFF0F172A);
    }
  }

  Color get textColor {
    switch (this) {
      case ReaderTheme.light:
        return const Color(0xFF1A1A1A);
      case ReaderTheme.sepia:
        return const Color(0xFF3B2A1A);
      case ReaderTheme.slate:
        return const Color(0xFFCBD5E1);
      case ReaderTheme.oled:
        return const Color(0xFFE2E8F0);
    }
  }

  Color get subtleTextColor {
    switch (this) {
      case ReaderTheme.light:
        return const Color(0xFF64748B);
      case ReaderTheme.sepia:
        return const Color(0xFF7C6147);
      case ReaderTheme.slate:
        return const Color(0xFF94A3B8);
      case ReaderTheme.oled:
        return const Color(0xFF94A3B8);
    }
  }

  Color get cardColor {
    switch (this) {
      case ReaderTheme.light:
        return Colors.white;
      case ReaderTheme.sepia:
        return const Color(0xFFF9F3E5);
      case ReaderTheme.slate:
        return const Color(0xFF263447);
      case ReaderTheme.oled:
        return const Color(0xFF1A2332);
    }
  }

  Color get borderColor {
    switch (this) {
      case ReaderTheme.light:
        return const Color(0xFFE2E8F0);
      case ReaderTheme.sepia:
        return const Color(0xFFD4C5A9);
      case ReaderTheme.slate:
        return const Color(0xFF334155);
      case ReaderTheme.oled:
        return const Color(0xFF1E2D3D);
    }
  }

  bool get isDark => this == ReaderTheme.slate || this == ReaderTheme.oled;
}

// ─── Preference Helpers ───────────────────────────────────────────────────────

const _kFontSizeKey = 'reader_font_size';
const _kThemeKey = 'reader_theme';

Future<(double, ReaderTheme)> loadReaderSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final fontSize = prefs.getDouble(_kFontSizeKey) ?? 15.0;
  final themeStr = prefs.getString(_kThemeKey) ?? ReaderTheme.light.name;
  final theme = ReaderTheme.values.firstWhere(
    (t) => t.name == themeStr,
    orElse: () => ReaderTheme.light,
  );
  return (fontSize, theme);
}

Future<void> saveReaderSettings(double fontSize, ReaderTheme theme) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setDouble(_kFontSizeKey, fontSize);
  await prefs.setString(_kThemeKey, theme.name);
}

// ─── Reading Settings Sheet ───────────────────────────────────────────────────

class ReadingSettingsSheet extends StatefulWidget {
  const ReadingSettingsSheet({
    super.key,
    required this.fontSize,
    required this.theme,
    required this.onChanged,
  });

  final double fontSize;
  final ReaderTheme theme;
  final void Function(double fontSize, ReaderTheme theme) onChanged;

  @override
  State<ReadingSettingsSheet> createState() => _ReadingSettingsSheetState();
}

class _ReadingSettingsSheetState extends State<ReadingSettingsSheet> {
  late double _fontSize;
  late ReaderTheme _theme;

  static const _fontSizes = [13.0, 15.0, 17.0, 19.0];
  static const _fontLabels = ['S', 'M', 'L', 'XL'];

  @override
  void initState() {
    super.initState();
    _fontSize = widget.fontSize;
    _theme = widget.theme;
  }

  void _update() {
    widget.onChanged(_fontSize, _theme);
    saveReaderSettings(_fontSize, _theme);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Handle bar ────────────────────────────────────────────────────
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            'Reading settings',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),

          // ── Font size ──────────────────────────────────────────────────────
          Text(
            'Text size',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(_fontSizes.length, (i) {
              final selected = _fontSize == _fontSizes[i];
              return GestureDetector(
                onTap: () {
                  setState(() => _fontSize = _fontSizes[i]);
                  _update();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 56,
                  height: 48,
                  decoration: BoxDecoration(
                    color: selected
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected ? cs.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _fontLabels[i],
                    style: TextStyle(
                      fontSize: _fontSizes[i] - 1,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? cs.onPrimaryContainer
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              );
            }),
          ),

          const SizedBox(height: 24),

          // ── Reading theme ──────────────────────────────────────────────────
          Text(
            'Reading theme',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: ReaderTheme.values.map((t) {
              final selected = _theme == t;
              return GestureDetector(
                onTap: () {
                  setState(() => _theme = t);
                  _update();
                },
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: t.backgroundColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? cs.primary : t.borderColor,
                          width: selected ? 3 : 1.5,
                        ),
                        boxShadow: selected
                            ? [
                                BoxShadow(
                                  color: cs.primary.withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: selected
                          ? Icon(
                              Icons.check,
                              color: t.isDark ? Colors.white : cs.primary,
                              size: 22,
                            )
                          : null,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.normal,
                        color: selected ? cs.primary : cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
