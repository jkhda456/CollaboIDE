import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../app/project_session.dart';
import '../app/workspace_controller.dart';
import '../webview/web_view_panel.dart';
import 'browser_panel.dart';
import 'left_nav.dart';
import 'new_project_dialog.dart';
import 'process_panel.dart';
import 'settings_dialog.dart';
import 'tool_activity_dialog.dart';

/// 우측 영역에 올 수 있는 화면. **설정 버튼 위의 항목들이 이 셋 중 하나를 고른다.**
enum AppView { project, browser, processes }

/// 최상위 레이아웃: 좌측 네이티브 메뉴 + 우측 화면 하나.
///
/// ★ **우측에 올 수 있는 화면이 여럿이고, 전부 살아 있다.** 열린 프로젝트마다
/// 패널 하나, 웹 검색 하나, 진행 상태 하나가 [IndexedStack] 안에 나란히 들어간다.
/// 좌측 버튼은 **어느 것을 그릴지만** 고른다 — 화면을 옮겨도 아무것도 닫히지 않고,
/// 다른 프로젝트에서 돌던 생성은 그대로 계속된다.
///
/// 좌측 메뉴에서 **설정 버튼 위는 전부 같은 성격**이다: 누르면 우측이 그 화면으로
/// 바뀐다. 그 아래(설정)만 모달이다 — 설정은 잠깐 열고 닫는 것이라 화면을 차지할
/// 이유가 없다.
class AppLayout extends StatefulWidget {
  const AppLayout({super.key, required this.workspace});

  final WorkspaceController workspace;

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  WorkspaceController get _workspace => widget.workspace;

  bool _wizardShown = false;

  /// 우측 영역이 지금 무엇을 보여 주는지. 좌측 메뉴가 바꾼다.
  AppView _view = AppView.project;

  /// 웹 검색 화면을 **한 번이라도** 띄웠는지.
  ///
  /// 웹뷰는 비싸다(WebView2 는 탭마다 프로세스 하나). 쓰지도 않을 브라우저를 앱
  /// 시작에 만들지 않으려고, 처음 필요해질 때까지 패널 자체를 트리에 넣지 않는다.
  /// 한 번 만든 뒤로는 [IndexedStack] 이 계속 들고 있어 탭이 살아 있다.
  /// (진행 상태 패널은 웹뷰가 없어 싸므로 처음부터 그냥 둔다.)
  bool _browserCreated = false;

  /// 복원을 이미 시작했는지. 알림이 여러 번 오므로 한 번만 돌게 막는다.
  bool _restoreStarted = false;

  @override
  void initState() {
    super.initState();
    _workspace.addListener(_onWorkspaceChanged);
    // 도구가 탭을 열면 화면을 웹 검색으로 돌린다 — 웹뷰가 제대로 된 크기를
    // 받아야 페이지가 정상으로 그려지고, 사용자도 무슨 일이 벌어지는지 본다.
    _workspace.onBrowserWanted = _openBrowser;
    // 세션이 만드는 브리지가 네이티브 창을 열어야 할 때 쓰는 통로.
    // 컨트롤러는 위젯을 모르고, 위젯은 세션 수명을 모르므로 여기서 이어 준다.
    _workspace.onOpenSettings = _onOpenSettings;
    _workspace.onOpenActivity = (session, id) =>
        showToolActivity(context, session.bridge!.toolCalls, initialId: id);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onWorkspaceChanged());
  }

  /// 컨트롤러 알림 · 첫 프레임에서 둘 다 불린다.
  ///
  /// ★ **초기화를 기다려야 한다.** `main.dart` 는 `init()` 을 await 하지 않으므로
  /// 첫 프레임이 설정 로드보다 먼저 온다. 예전에는 여기서 곧바로 복원을 불러
  /// **열어 둔 목록이 아직 비어 있는 채로 지나가 버렸다** — 앱을 켜면 프로젝트가
  /// 하나도 안 열려 있던 원인이다.
  void _onWorkspaceChanged() {
    _maybeShowWizard();
    _maybeRestore();
  }

  void _maybeRestore() {
    if (_restoreStarted || !mounted || !_workspace.initialized) return;
    _restoreStarted = true;
    // 알림 도중일 수 있으므로 프레임 밖에서 한다(마법사와 같은 이유).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 새 대화 제목은 l10n 이라 컨트롤러가 직접 못 읽는다(§9-(5) 해소).
      // 복원보다 **먼저** 넣어야 한다 — 대화가 없는 프로젝트가 이 제목을 쓴다.
      _workspace.newConversationTitle =
          AppLocalizations.of(context).conversation;
      unawaited(_workspace.restoreOpenProjects());
    });
  }

  @override
  void dispose() {
    _workspace.removeListener(_onWorkspaceChanged);
    _workspace.onBrowserWanted = null;
    _workspace.onOpenSettings = null;
    _workspace.onOpenActivity = null;
    super.dispose();
  }

  /// 도구가 브라우저 탭을 열었을 때 — 화면을 웹 검색으로 돌린다.
  void _openBrowser() {
    if (!mounted || _view == AppView.browser) return;
    setState(() {
      _view = AppView.browser;
      _browserCreated = true;
    });
  }

  /// 좌측 메뉴 항목은 **토글**이다: 같은 것을 다시 누르면 프로젝트로 돌아온다
  /// (VS Code 활동 막대와 같다).
  void _showView(AppView view) {
    setState(() {
      _view = (_view == view) ? AppView.project : view;
      if (_view == AppView.browser) _browserCreated = true;
    });
  }

  /// 첫 실행(데이터 미준비)이면 초기 설정 마법사를 1회 띄운다.
  ///
  /// 구독은 해제하지 않는다 — 같은 리스너가 복원도 맡고 있다([_onWorkspaceChanged]).
  void _maybeShowWizard() {
    if (_wizardShown || !mounted || !_workspace.needsFirstRunSetup) return;
    _wizardShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showFirstRunWizard(context, _workspace);
    });
  }

  /// 프로젝트를 연다(또는 이미 열려 있으면 그리로 이동). 화면도 그쪽으로 돌린다.
  Future<void> _open(String path) async {
    await _workspace.openProject(path);
    if (mounted) setState(() => _view = AppView.project);
  }

  Future<void> _onNewProject() async {
    final path = await showNewProjectDialog(context,
        initialDir: _workspace.lastWorkspaceDir);
    if (path == null) return;
    await _workspace.setLastWorkspaceDir(p.dirname(path));
    await _open(path);
  }

  Future<void> _onOpenProject() async {
    final path = await getDirectoryPath(
        initialDirectory: _workspace.lastWorkspaceDir,
        confirmButtonText: AppLocalizations.of(context).navOpenProject);
    if (path != null) {
      await _workspace.setLastWorkspaceDir(p.dirname(path));
      await _open(path);
    }
  }

  /// 프로젝트를 닫는다. **작업 중이면 먼저 물어본다** — 닫으면 그 생성은 끊긴다.
  Future<void> _onCloseProject(ProjectSession session) async {
    if (session.isBusy) {
      final l = AppLocalizations.of(context);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.closeBusyProjectTitle),
          content: Text(l.closeBusyProjectBody(session.name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(l.closeProject)),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _workspace.closeProject(session.path);
  }

  /// 설정 창을 연다. [section] 은 웹의 설정 안내 버튼이 넘기는 대상 섹션
  /// ('model'|'tools' 등). 좌측 메뉴의 ⚙ 는 인자 없이 호출해 기본 탭으로 연다.
  void _onOpenSettings([String section = '']) {
    showSettingsDialog(context, _workspace,
        initialTab: settingsTabIndexFor(section));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _workspace,
        builder: (context, _) {
          final sessions = _workspace.sessions;
          return Row(
            children: [
              // 탭 개수 배지만 브라우저를 따로 듣는다. 컨트롤러 알림에 얹으면
              // 페이지 로드 중 상태 변화마다 레이아웃 전체가 다시 그려진다.
              ListenableBuilder(
                listenable: _workspace.browser,
                builder: (context, _) => LeftNav(
                  onNewProject: _onNewProject,
                  onOpenProject: _onOpenProject,
                  onOpenSettings: _onOpenSettings,
                  openProjects: sessions,
                  activeProject: _workspace.projectPath ?? '',
                  projectSelected: _view == AppView.project,
                  onSelectProject: (path) => setState(() {
                    _view = AppView.project;
                    _workspace.activateProject(path);
                  }),
                  onCloseProject: _onCloseProject,
                  runningProcessCount: _workspace.runningProcessCount,
                  processesSelected: _view == AppView.processes,
                  onToggleProcesses: () => _showView(AppView.processes),
                  browserSelected: _view == AppView.browser,
                  browserTabCount: _workspace.browser.tabs.length,
                  onToggleBrowser: () => _showView(AppView.browser),
                ),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: _content(sessions)),
            ],
          );
        },
      ),
    );
  }

  /// 우측 영역. **열린 것을 전부 트리에 둔다** — 갈아 끼우면 그 패널이 dispose 되고,
  /// 웹뷰가 사라지면서 화면 상태(스크롤·열린 파일·펼친 트리)가 통째로 날아간다.
  /// 에이전트 루프는 세션이 들고 있어 여기서 사라지지 않지만, 화면은 다시 만든다.
  Widget _content(List<ProjectSession> sessions) {
    final children = <Widget>[
      _EmptyState(
        onNewProject: _onNewProject,
        onOpenProject: _onOpenProject,
        recentProjects:
            _workspace.recentProjects.map((r) => r.path).toList(),
        onOpenRecent: _open,
        onRemoveRecent: _workspace.removeRecentProject,
      ),
      for (final s in sessions)
        WebViewPanel(
          key: ValueKey(s.path),
          session: s,
          themeMode: _workspace.themeMode,
          langCode: _workspace.langCode,
          visible: _view == AppView.project &&
              s.path == _workspace.projectPath,
        ),
      if (_browserCreated)
        BrowserPanel(workspace: _workspace)
      else
        const SizedBox.shrink(),
      ProcessPanel(
        workspace: _workspace,
        visible: _view == AppView.processes,
      ),
    ];
    // 위 순서와 맞춘 자리. 바꾸면 아래 index 계산도 같이 고쳐야 한다.
    final browserIndex = children.length - 2;
    final processIndex = children.length - 1;

    final int index;
    switch (_view) {
      case AppView.browser:
        // 아직 안 만들었으면 프로젝트를 그대로 둔다(빈 화면이 뜨지 않게).
        index = _browserCreated ? browserIndex : _projectIndex(sessions);
      case AppView.processes:
        index = processIndex;
      case AppView.project:
        index = _projectIndex(sessions);
    }
    return IndexedStack(index: index, children: children);
  }

  /// 활성 프로젝트 패널의 자리(없으면 0 = 빈 화면).
  int _projectIndex(List<ProjectSession> sessions) {
    final i = sessions.indexWhere((s) => s.path == _workspace.projectPath);
    return i < 0 ? 0 : i + 1;
  }
}

/// 열린 프로젝트가 하나도 없을 때 보이는 화면.
///
/// **최근 프로젝트 목록이 여기 있다.** 좌측 메뉴에 두면 닫은 프로젝트가 목록
/// 아래로 "내려간" 것처럼 보여, 열린 것과 닫힌 것을 구분할 수 없다(§left_nav).
/// 다시 열 일은 대개 아무것도 안 열려 있을 때 생기므로 이 자리가 맞다.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onNewProject,
    required this.onOpenProject,
    this.recentProjects = const [],
    this.onOpenRecent,
    this.onRemoveRecent,
  });

  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;

  /// 최근 프로젝트 경로(MRU 순서).
  final List<String> recentProjects;
  final ValueChanged<String>? onOpenRecent;

  /// 최근 목록에서만 제거(실제 폴더는 삭제하지 않음).
  final ValueChanged<String>? onRemoveRecent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final recent = recentProjects.take(LeftNav.maxRecent).toList();
    return Container(
      color: theme.colorScheme.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(l.noProjectTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onNewProject,
              icon: const Icon(Icons.create_new_folder),
              label: Text(l.startNewProject),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onOpenProject,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(l.navOpenProject),
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 28),
              SizedBox(
                width: 380,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l.recentProjectsTitle,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              for (final path in recent)
                SizedBox(
                  width: 380,
                  child: ListTile(
                    dense: true,
                    leading: ProjectMonogram(path: path, dimmed: true),
                    title: Text(projectBasename(path),
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(path,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
                    onTap: () => onOpenRecent?.call(path),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: l.remove,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onRemoveRecent?.call(path),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
