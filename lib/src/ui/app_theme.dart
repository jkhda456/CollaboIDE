import 'package:flutter/material.dart';

/// 앱 테마 정의(라이트/다크). 기본값은 라이트.
class AppTheme {
  static const Color _seed = Color(0xFF4C8BF5);

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      );

  /// 설정에 저장하는 문자열 ↔ [ThemeMode] 변환. 알 수 없으면 라이트.
  static ThemeMode modeFromName(String? name) => switch (name) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      };

  static String modeToName(ThemeMode mode) => switch (mode) {
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
      };

  /// 웹뷰(Bootstrap)의 `data-bs-theme` 값. system 은 플랫폼 밝기로 환원.
  static String bootstrapTheme(ThemeMode mode, Brightness platform) =>
      switch (mode) {
        ThemeMode.dark => 'dark',
        ThemeMode.light => 'light',
        ThemeMode.system => platform == Brightness.dark ? 'dark' : 'light',
      };
}
