import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../app/workspace_controller.dart';
import '../webview/web_view_panel.dart';
import 'left_nav.dart';
import 'new_project_dialog.dart';
import 'process_monitor_dialog.dart';
import 'settings_dialog.dart';

/// 최상위 레이아웃: 좌측 네이티브 메뉴 + 웹뷰 영역.
///
/// 좌측 메뉴만 네이티브 Flutter 위젯이며, 나머지(가운데 대화 + 우측 트리/뷰어)는
/// 단일 웹뷰 안에서 렌더링된다.
class AppLayout extends StatefulWidget {
  const AppLayout({super.key, required this.workspace});

  final WorkspaceController workspace;

  @override
  State<AppLayout> createState() => _AppLayoutState();
}

class _AppLayoutState extends State<AppLayout> {
  WorkspaceController get _workspace => widget.workspace;

  bool _wizardShown = false;

  @override
  void initState() {
    super.initState();
    _workspace.addListener(_maybeShowWizard);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowWizard());
  }

  @override
  void dispose() {
    _workspace.removeListener(_maybeShowWizard);
    super.dispose();
  }

  /// 첫 실행(데이터 미준비)이면 초기 설정 마법사를 1회 띄운다.
  void _maybeShowWizard() {
    if (_wizardShown || !mounted || !_workspace.needsFirstRunSetup) return;
    _wizardShown = true;
    _workspace.removeListener(_maybeShowWizard);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showFirstRunWizard(context, _workspace);
    });
  }

  Future<void> _onNewProject() async {
    final path = await showNewProjectDialog(context,
        initialDir: _workspace.lastWorkspaceDir);
    if (path == null) return;
    await _workspace.setLastWorkspaceDir(p.dirname(path));
    await _workspace.openProject(path);
  }

  Future<void> _onOpenProject() async {
    final path = await getDirectoryPath(
        initialDirectory: _workspace.lastWorkspaceDir,
        confirmButtonText: AppLocalizations.of(context).navOpenProject);
    if (path != null) {
      await _workspace.setLastWorkspaceDir(p.dirname(path));
      await _workspace.openProject(path);
    }
  }

  void _onOpenSettings() {
    showSettingsDialog(context, _workspace);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: _workspace,
        builder: (context, _) {
          return Row(
            children: [
              LeftNav(
                onNewProject: _onNewProject,
                onOpenProject: _onOpenProject,
                onOpenSettings: _onOpenSettings,
                recentProjects:
                    _workspace.recentProjects.map((r) => r.path).toList(),
                onOpenRecent: _workspace.openProject,
                onRemoveRecent: _workspace.removeRecentProject,
                runningProcessCount:
                    _workspace.backgroundProcesses.runningCount,
                onOpenProcesses: () => showProcessMonitor(context, _workspace),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: _workspace.hasProject
                    ? WebViewPanel(
                        workspace: _workspace,
                        projectPath: _workspace.projectPath,
                        themeMode: _workspace.themeMode,
                        langCode: _workspace.langCode,
                      )
                    : _EmptyState(
                        onNewProject: _onNewProject,
                        onOpenProject: _onOpenProject,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 프로젝트가 없을 때 웹뷰 대신 보이는 빈 화면(가운데 새 프로젝트 시작 버튼).
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onNewProject, required this.onOpenProject});

  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    return Container(
      color: theme.colorScheme.surface,
      alignment: Alignment.center,
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
        ],
      ),
    );
  }
}
