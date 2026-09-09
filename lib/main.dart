import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/app_localizations.dart';
import 'src/app/workspace_controller.dart';
import 'src/data/app_database.dart';
import 'src/data/sqlite_init.dart';
import 'src/ui/app_layout.dart';
import 'src/ui/app_theme.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 데스크톱 SQLite(FFI) 백엔드 활성화 — 메인 DB/대화 DB 사용 전 1회.
  initSqliteFfi();
  await _restoreWindowSize();
  runApp(const CollaboIdeApp());
}

/// 직전 실행에서 저장한 창 **크기**를 복원한다(위치는 유지하지 않음 — OS 기본).
/// 저장 값이 없거나 읽기에 실패하면 런너 기본 크기로 시작한다.
Future<void> _restoreWindowSize() async {
  if (!_isDesktop) return;
  await windowManager.ensureInitialized();
  Size? size;
  try {
    // 메인 DB 를 잠깐 열어 창 크기만 읽는다(본 로딩은 WorkspaceController.init).
    final db = await AppDatabase.open();
    final v = await db.getSetting(WorkspaceController.windowSizeKey);
    await db.close();
    if (v is Map) {
      final w = (v['w'] as num?)?.toDouble();
      final h = (v['h'] as num?)?.toDouble();
      if (w != null && h != null) {
        // 깨진 값(너무 작은 창)으로 복원되지 않도록 하한을 둔다.
        size = Size(w.clamp(600.0, 16000.0), h.clamp(400.0, 16000.0));
      }
    }
  } catch (_) {
    // 복원 실패는 무시하고 기본 크기로 시작한다.
  }
  final opts = WindowOptions(size: size, center: false);
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

class CollaboIdeApp extends StatefulWidget {
  const CollaboIdeApp({super.key});

  @override
  State<CollaboIdeApp> createState() => _CollaboIdeAppState();
}

class _CollaboIdeAppState extends State<CollaboIdeApp> with WindowListener {
  final WorkspaceController _workspace = WorkspaceController();
  Timer? _sizeSaveDebounce;

  @override
  void initState() {
    super.initState();
    if (_isDesktop) windowManager.addListener(this);
    _workspace.init();
  }

  /// 크기 조절 중 연속 이벤트가 오므로, 멈춘 뒤 한 번만 저장한다.
  @override
  void onWindowResize() {
    _sizeSaveDebounce?.cancel();
    _sizeSaveDebounce = Timer(const Duration(milliseconds: 400), () async {
      // 최대화/전체화면 크기는 저장하지 않는다(다음 실행에서 일반 창으로
      // 그 크기를 쓰면 어색하다 — 마지막 일반 크기를 유지).
      if (await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      final s = await windowManager.getSize();
      await _workspace.saveWindowSize(s.width, s.height);
    });
  }

  @override
  void dispose() {
    if (_isDesktop) windowManager.removeListener(this);
    _sizeSaveDebounce?.cancel();
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
