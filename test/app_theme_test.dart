import 'package:collabo_ide/src/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('기본/미지정 테마는 라이트', () {
    expect(AppTheme.modeFromName(null), ThemeMode.light);
    expect(AppTheme.modeFromName('unknown'), ThemeMode.light);
    expect(AppTheme.modeFromName('light'), ThemeMode.light);
    expect(AppTheme.modeFromName('dark'), ThemeMode.dark);
    expect(AppTheme.modeFromName('system'), ThemeMode.system);
  });

  test('테마 모드 ↔ 이름 왕복 변환', () {
    for (final m in ThemeMode.values) {
      expect(AppTheme.modeFromName(AppTheme.modeToName(m)), m);
    }
  });

  test('system 은 플랫폼 밝기로 환원된다(Bootstrap)', () {
    expect(AppTheme.bootstrapTheme(ThemeMode.light, Brightness.dark), 'light');
    expect(AppTheme.bootstrapTheme(ThemeMode.dark, Brightness.light), 'dark');
    expect(
        AppTheme.bootstrapTheme(ThemeMode.system, Brightness.dark), 'dark');
    expect(
        AppTheme.bootstrapTheme(ThemeMode.system, Brightness.light), 'light');
  });
}
