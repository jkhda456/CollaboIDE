import 'package:collabo_core/collabo_core.dart' show NetworkEvent;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/app_localizations.dart';
import '../app/project_session.dart';
import '../app/workspace_controller.dart';
import '../platform/platform_features.dart';
import '../sandbox/project_sandbox.dart';
import 'adaptive.dart';
import 'ime_terminal_view.dart';

/// 샌드박스 화면 — 열린 프로젝트마다 하나씩 있는 collaboCore 머신을 보고 만진다.
///
/// 진행 상태·웹 검색과 같은 **화면**이다(좌측 메뉴가 토글). 머신 상태·마운트를 보여
/// 주고, 시작·다시 시작·중지, 그리고 **root 셸 터미널**과 네트워크 접근 기록을 연다.
///
/// > 터미널은 xterm.dart 의 `TerminalView` 다 — 입력과 출력이 한 화면에서 맞물리는
/// > 진짜 TTY(커서·지우기·대체 화면·Ctrl 키·IME·선택/복사·스크롤백). 모델은
/// > [ProjectSandbox.console] 에 있어 화면을 옮겨도 남고, 스스로 다시 그린다 —
/// > 세션·컨트롤러 알림에 얹지 않는다(출력마다 앱 전체가 다시 그려진다).
class SandboxPanel extends StatefulWidget {
  const SandboxPanel({super.key, required this.workspace, this.visible = true});

  final WorkspaceController workspace;

  /// 지금 보이는지. 안 보이면 터미널 위젯을 트리에서 뺀다(IndexedStack 에 계속 남아
  /// 있으므로) — 안 보이는 패널은 크기를 엉뚱하게 재서 머신에 0×0 을 보낼 수 있다.
  final bool visible;

  @override
  State<SandboxPanel> createState() => _SandboxPanelState();
}

class _SandboxPanelState extends State<SandboxPanel> with SingleTickerProviderStateMixin {
  String? _selectedPath;

  /// 좁은 화면에서 상세를 보고 있는가(목록 → 상세 한 장씩 — [MasterDetail]).
  bool _showDetail = false;
  final FocusNode _terminalFocus = FocusNode(debugLabel: 'sandbox-terminal');
  // initState 에서 만든다 — `late final` 로 늦게 만들면 한 번도 안 그린 채(프로젝트 없음)
  // dispose 에서 처음 만들어지며 비활성 트리를 조회해 터진다.
  late final TabController _tabs;

  WorkspaceController get workspace => widget.workspace;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _terminalFocus.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// 시작하면 곧바로 칠 수 있게 터미널로 초점을 옮긴다.
  Future<void> _startAndFocus(ProjectSandbox box) async {
    await box.start();
    if (mounted && box.isRunning) _terminalFocus.requestFocus();
  }

  /// 목록에서 시스템 머신을 고른 상태([_selectedPath] 에 넣는 값 — 프로젝트 경로와 안 겹친다).
  static const String _systemKey = '::system';

  ProjectSession? _selected(List<ProjectSession> sessions) {
    if (sessions.isEmpty) return null;
    for (final s in sessions) {
      if (s.path == _selectedPath) return s;
    }
    // 고른 적이 없으면 지금 보고 있는 프로젝트부터.
    for (final s in sessions) {
      if (s.path == workspace.projectPath) return s;
    }
    return sessions.first;
  }

  String _stateLabel(AppLocalizations l, ProjectSandbox? box) {
    switch (box?.state ?? SandboxState.idle) {
      case SandboxState.idle:
        return l.sandboxIdle;
      case SandboxState.starting:
        return l.sandboxStarting;
      case SandboxState.running:
        return l.sandboxRunning;
      case SandboxState.failed:
        return l.sandboxFailed(box?.error ?? '');
    }
  }

  Future<void> _stop(ProjectSandbox box) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.sandboxStopTitle),
        content: Text(l.sandboxStopBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.sandboxStop)),
        ],
      ),
    );
    if (ok == true) await box.stop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        final sessions = workspace.sessions;
        // 시스템 머신은 **앱에 하나 고정**이고 목록 맨 위에 늘 있다.
        final systemBox = workspace.systemSandbox();
        final sel = _selectedPath == _systemKey ? null : _selected(sessions);
        final systemSelected = systemBox != null && (sel == null || _selectedPath == _systemKey);
        // Container(color) 가 아니라 Material — ListTile 의 선택 배경·잉크가 그 위에 그려진다.
        return Material(
          color: theme.colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.shield_outlined, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(l.navSandboxes, style: theme.textTheme.titleMedium),
                  ],
                ),
              ),
              if (!workspace.sandboxAvailable)
                _Notice(
                    text: PlatformFeatures.isIOS ? l.sandboxUnavailableIOS : l.sandboxUnavailable,
                    error: true),
              const Divider(height: 1),
              Expanded(
                child: sessions.isEmpty && systemBox == null
                    ? Center(
                        child: Text(l.sandboxNoProjects,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)))
                    : MasterDetail(
                        master: _buildList(l, theme, sessions, sel, systemBox, systemSelected),
                        detail: systemSelected
                            ? _buildDetail(l, theme,
                                title: l.sandboxSystemMachine,
                                subtitle: l.sandboxSystemMachineDesc,
                                box: systemBox)
                            : _buildDetail(l, theme, title: sel!.name, box: workspace.sandboxOf(sel)),
                        showDetail: _showDetail,
                        detailTitle: systemSelected ? l.sandboxSystemMachine : sel?.name,
                        onBack: () => setState(() => _showDetail = false),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildList(AppLocalizations l, ThemeData theme, List<ProjectSession> sessions,
      ProjectSession? sel, ProjectSandbox? systemBox, bool systemSelected) {
    // 맨 위 한 줄이 시스템 머신(있을 때), 그 아래가 열린 프로젝트들.
    final rows = <Widget>[
      if (systemBox != null)
        _tile(l, theme,
            title: l.sandboxSystemMachine,
            box: systemBox,
            selected: systemSelected,
            icon: Icons.settings_suggest_outlined,
            onTap: () => setState(() {
                  _selectedPath = _systemKey;
                  _showDetail = true;
                })),
      for (final s in sessions)
        _tile(l, theme,
            title: s.name,
            box: s.sandbox,
            selected: identical(s, sel) && !systemSelected,
            icon: null,
            onTap: () => setState(() {
                  _selectedPath = s.path;
                  _showDetail = true;
                })),
    ];
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => rows[i],
    );
  }

  Widget _tile(
    AppLocalizations l,
    ThemeData theme, {
    required String title,
    required ProjectSandbox? box,
    required bool selected,
    required IconData? icon,
    required VoidCallback onTap,
  }) {
    final running = box?.isRunning ?? false;
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(
        icon ?? (running ? Icons.shield : Icons.shield_outlined),
        size: 18,
        color: box?.state == SandboxState.failed
            ? theme.colorScheme.error
            : running
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_stateLabel(l, box), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }

  /// 고른 머신의 상세 — 프로젝트 머신과 시스템 머신이 같은 화면을 쓴다.
  /// (프로젝트 머신은 화면에서 처음 볼 때 자리만 만들어 둔다 — 부팅은 "시작" 때.)
  Widget _buildDetail(AppLocalizations l, ThemeData theme,
      {required String title, required ProjectSandbox? box, String? subtitle}) {
    final running = box?.isRunning ?? false;
    final starting = box?.state == SandboxState.starting;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.35);
    final since = box?.startedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    if (subtitle != null)
                      Text(subtitle,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    Text(
                      since != null
                          ? l.sandboxUptime(_hhmm(since))
                          : _stateLabel(l, box),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: box?.state == SandboxState.failed
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (box != null && !running)
                FilledButton.tonalIcon(
                  onPressed: starting ? null : () => _startAndFocus(box),
                  icon: starting
                      ? const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow, size: 18),
                  label: Text(l.sandboxStart),
                ),
              if (box != null && running) ...[
                TextButton.icon(
                  onPressed: box.restart,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(l.sandboxRestart),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: () => _stop(box),
                  icon: const Icon(Icons.stop_circle, size: 18),
                  label: Text(l.sandboxStop),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        if (box != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (host, guest, ro) in box.mounts)
                  Text('$guest  ←  $host${ro ? '  (${l.sandboxMountRo})' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [Tab(text: l.sandboxConsole), Tab(text: l.sandboxNetwork)],
        ),
        const Divider(height: 1),
        Expanded(
          child: box == null
              ? const SizedBox.shrink()
              : TabBarView(
                  controller: _tabs,
                  // 터미널에서 끌어 선택하면 탭이 넘어가 버린다 — 탭은 위의 탭 막대로만 바꾼다.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _buildConsole(l, theme, box, running),
                    _buildNetwork(l, theme, box, mono),
                  ],
                ),
        ),
      ],
    );
  }

  /// 터미널 테마 — 앱이 밝은 테마여도 터미널은 어두운 쪽이 관례이고 색 대비도 맞다.
  static const TerminalTheme _terminalTheme = TerminalThemes.defaultTheme;

  /// 터미널 단축키. **Ctrl 단독 조합은 전부 셸의 것**이다(Ctrl-A 줄 처음, Ctrl-C 끊기 …).
  ///
  /// xterm.dart 기본값은 Windows/Linux 에서 Ctrl-A(전체 선택)·Ctrl-V(붙여넣기)를 가로채
  /// 셸로 안 보낸다. 터미널 관례대로 복사·붙여넣기·전체 선택을 **Ctrl-Shift** 로 옮긴다.
  /// macOS 는 기본값이 Cmd 조합이라 Ctrl 과 겹치지 않는다 — 그대로 둔다(null).
  static Map<ShortcutActivator, Intent>? get _terminalShortcuts {
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return null;
    }
    return {
      const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
          CopySelectionTextIntent.copy,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
          const PasteTextIntent(SelectionChangedCause.keyboard),
      const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true):
          const SelectAllTextIntent(SelectionChangedCause.keyboard),
    };
  }

  Widget _buildConsole(AppLocalizations l, ThemeData theme, ProjectSandbox box, bool running) {
    final terminal = !widget.visible
        // 안 보이면 뺀다 — 크기를 잘못 재 머신에 엉뚱한 콘솔 크기를 보내지 않게.
        // 모델([SandboxConsole.terminal])은 그대로라 다시 보이면 스크롤백까지 돌아온다.
        ? const SizedBox.shrink()
        // 한글 조합이 쪼개지지 않게 글자 입력(IME)은 따로 받는다 — ImeTerminalView 참고.
        : ImeTerminalView(
            box.console.terminal,
            key: ValueKey(box),
            focusNode: _terminalFocus,
            autofocus: running,
            theme: _terminalTheme,
            textStyle: const TerminalStyle(fontSize: 13),
            padding: const EdgeInsets.all(8),
            shortcuts: _terminalShortcuts,
            // 머신이 없으면 칠 곳이 없다 — 입력을 받지 않는다(선택·복사·스크롤은 된다).
            readOnly: !running,
          );
    return ColoredBox(
      color: _terminalTheme.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          terminal,
          if (!running)
            // 꺼져 있을 때는 지난 출력 위에 안내를 얹는다(출력은 그대로 읽을 수 있게 흐리게).
            IgnorePointer(
              child: Container(
                color: _terminalTheme.background.withValues(alpha: 0.72),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(24),
                child: Text(
                  box.state == SandboxState.starting ? l.sandboxStarting : l.sandboxNotRunning,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: _terminalTheme.foreground),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNetwork(AppLocalizations l, ThemeData theme, ProjectSandbox box, TextStyle? mono) {
    if (!widget.visible) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: box.console,
      builder: (context, _) {
        final events = box.console.events.reversed.toList();
        if (events.isEmpty) {
          return Center(
            child: Text(l.sandboxNetworkEmpty,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          );
        }
        return ListView.builder(
          itemCount: events.length,
          itemBuilder: (_, i) => _eventRow(theme, events[i], mono),
        );
      },
    );
  }

  Widget _eventRow(ThemeData theme, NetworkEvent e, TextStyle? mono) {
    final target = e.url ?? e.host ?? '${e.ip}:${e.port}';
    final tail = [
      if (e.status != null) '${e.status}',
      if (e.blocked) 'BLOCKED',
      if (e.reason != null && e.reason!.isNotEmpty) e.reason!,
    ].join('  ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Text(
        '${e.via.padRight(3)} ${e.kind.padRight(7)} ${(e.phase ?? '').padRight(8)} $target  $tail',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: mono?.copyWith(color: e.blocked ? theme.colorScheme.error : null),
      ),
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
