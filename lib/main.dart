import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'src/app/workspace_controller.dart';
import 'src/data/sqlite_init.dart';
import 'src/ui/app_layout.dart';
import 'src/ui/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 데스크톱 SQLite(FFI) 백엔드 활성화 — 메인 DB/대화 DB 사용 전 1회.
  initSqliteFfi();
  runApp(const CollaboIdeApp());
}

class CollaboIdeApp extends StatefulWidget {
  const CollaboIdeApp({super.key});

  @override
  State<CollaboIdeApp> createState() => _CollaboIdeAppState();
}

class _CollaboIdeAppState extends State<CollaboIdeApp> {
  final WorkspaceController _workspace = WorkspaceController();

  @override
  void initState() {
    super.initState();
    _workspace.init();
  }

  @override
  void dispose() {
    _workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _workspace,
      builder: (context, _) {
        return MaterialApp(
          title: 'Collabo IDE',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: _workspace.themeMode, // 기본 라이트
          locale: _workspace.locale, // null = 시스템 따름
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppLayout(workspace: _workspace),
        );
      },
    );
  }
}
