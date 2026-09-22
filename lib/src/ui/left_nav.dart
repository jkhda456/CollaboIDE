import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../app/project_session.dart';

/// 좌측 네비게이션 메뉴 (네이티브).
///
/// 구성:
/// - 최상단: 새 프로젝트 / 프로젝트 열기 (동작)
/// - **열린 프로젝트** — 남는 공간을 전부 차지한다 (화면)
/// - 웹 검색 (화면)
/// - 샌드박스 — 떠 있는 머신 수 배지 (화면, 샌드박스 모드일 때)
/// - 진행 상태 — 실행 중 명령 개수 배지 (화면)
/// - 최하단: 설정 (모달) + 접기/펼치기
///
/// ★ **설정 버튼 위는 전부 같은 성격이다** — 누르면 우측 영역이 그 화면으로 바뀌고,
/// 같은 것을 다시 누르면 프로젝트로 돌아온다. 설정만 모달로 남는다(잠깐 열고 닫는
/// 것이라 화면을 차지할 이유가 없다).
///
/// ★ **여기 보이는 프로젝트가 열려 있는 것 전부다.** 닫으면 목록에서 사라진다 —
/// 최근(MRU) 목록을 이 아래에 두지 않는 이유가 그것이다. 두면 닫은 프로젝트가
/// 아래 줄로 "내려간" 것처럼 보여, 목록만 보고는 열린 것과 닫힌 것을 구분할 수
/// 없다. 다시 열 때 쓰는 최근 목록은 **빈 화면**(`_EmptyState`)에 있다.
///
/// **열린 프로젝트와 웹 검색만 선택 상태를 가진다.** 그 둘이 우측 영역을 차지하는
/// 화면들이고, 이 메뉴는 그중 무엇을 볼지 고르는 자리다(VS Code 활동 막대와 같다).
/// 누르는 것으로 아무것도 닫히지 않는다 — 열린 프로젝트는 전부 계속 돌아간다.
///
/// 접기/펼치기 가능: 접으면 아이콘만, 펼치면 아이콘 + 라벨.
class LeftNav extends StatefulWidget {
  const LeftNav({
    super.key,
    required this.onNewProject,
    required this.onOpenProject,
    required this.onOpenSettings,
    this.openProjects = const [],
    this.activeProject = '',
    this.projectSelected = true,
    this.onSelectProject,
    this.onCloseProject,
    this.runningProcessCount = 0,
    this.processesSelected = false,
    this.onToggleProcesses,
    this.browserSelected = false,
    this.browserTabCount = 0,
    this.onToggleBrowser,
    this.sandboxesSelected = false,
    this.runningSandboxCount = 0,
    this.onToggleSandboxes,
  });

  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;
  final VoidCallback onOpenSettings;

  /// 지금 열려 있는 프로젝트들(연 순서).
  final List<ProjectSession> openProjects;

  /// 활성 프로젝트 경로.
  final String activeProject;

  /// 우측 영역이 지금 프로젝트 화면인지(웹 검색이면 false — 어느 프로젝트도
  /// 선택 표시를 달지 않는다).
  final bool projectSelected;

  final ValueChanged<String>? onSelectProject;
  final ValueChanged<ProjectSession>? onCloseProject;

  /// 열린 **모든** 프로젝트에서 실행 중인 백그라운드 명령 수(배지).
  final int runningProcessCount;

  /// 지금 우측 영역이 진행 상태 화면인지(선택 표시).
  final bool processesSelected;

  /// 진행 상태 화면 토글. null 이면 클릭 비활성.
  final VoidCallback? onToggleProcesses;

  /// 지금 우측 영역이 웹 검색 화면인지(선택 표시).
  final bool browserSelected;

  /// 열려 있는 브라우저 탭 수(0 이면 배지 없음).
  final int browserTabCount;

  /// 웹 검색 화면 토글. null 이면 항목을 감춘다.
  final VoidCallback? onToggleBrowser;

  /// 지금 우측 영역이 샌드박스 화면인지(선택 표시).
  final bool sandboxesSelected;

  /// 떠 있는 샌드박스 머신 수(0 이면 배지 없음).
  final int runningSandboxCount;

  /// 샌드박스 화면 토글. null 이면 항목을 감춘다(시스템 Python 모드이고 떠 있는 머신이 없을 때).
  final VoidCallback? onToggleSandboxes;

  static const double collapsedWidth = 56;
  static const double expandedWidth = 220;

  /// 빈 화면의 최근 프로젝트 목록에 보여 줄 개수. 메인 DB 의 MRU 와 같은 값이다.
  static const int maxRecent = 5;

  @override
  State<LeftNav> createState() => _LeftNavState();
}

class _LeftNavState extends State<LeftNav> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeInOut,
      width: _expanded ? LeftNav.expandedWidth : LeftNav.collapsedWidth,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 최상단: 새 프로젝트 / 프로젝트 열기
          _NavItem(
            icon: Icons.create_new_folder,
            label: l.navNewProject,
            expanded: _expanded,
            onTap: widget.onNewProject,
          ),
          _NavItem(
            icon: Icons.folder_open,
            label: l.navOpenProject,
            expanded: _expanded,
            onTap: widget.onOpenProject,
          ),
          const Divider(height: 1),

          // 열린 프로젝트 — **여기 있는 것이 곧 열려 있는 것 전부**다.
          //
          // 닫으면 목록에서 사라진다. 최근 목록을 그 아래에 두지 않는 이유가
          // 이것이다 — 닫은 프로젝트가 아래 줄로 내려간 것처럼 보이면, 닫힌
          // 것인지 열린 것인지 목록만 보고는 알 수 없다. 다시 열 때 쓰는
          // 최근 목록은 빈 화면에 있다.
          //
          // 남는 공간을 [Expanded] 로 전부 차지하고, **넘칠 때만** 스크롤한다.
          // (예전에는 Flexible + Spacer 가 공간을 나눠 가져, 두어 개만 열어도
          //  스크롤이 생겼다.)
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in widget.openProjects)
                    _NavItem(
                      leading: ProjectMonogram(path: s.path),
                      label: s.name,
                      tooltip: s.isBusy ? '${s.path}\n${l.projectBusy}' : s.path,
                      expanded: _expanded,
                      selected: widget.projectSelected &&
                          s.path == widget.activeProject,
                      busy: s.isBusy,
                      onTap: () => widget.onSelectProject?.call(s.path),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: l.closeProject,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 28, minHeight: 28),
                        onPressed: () => widget.onCloseProject?.call(s),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),

          // 웹 검색 (진행 상태 바로 위) — 유일하게 선택 상태를 가지는 항목.
          if (widget.onToggleBrowser != null)
            _NavItem(
              icon: Icons.travel_explore,
              label: l.navWebSearch,
              expanded: _expanded,
              selected: widget.browserSelected,
              badgeCount: widget.browserTabCount,
              onTap: widget.onToggleBrowser!,
            ),

          // 샌드박스 — 프로젝트마다 하나씩 도는 리눅스 머신(콘솔·네트워크 기록).
          if (widget.onToggleSandboxes != null)
            _NavItem(
              icon: Icons.shield_outlined,
              label: l.navSandboxes,
              tooltip: widget.runningSandboxCount > 0
                  ? l.navSandboxesRunning(widget.runningSandboxCount)
                  : null,
              expanded: _expanded,
              selected: widget.sandboxesSelected,
              badgeCount: widget.runningSandboxCount,
              onTap: widget.onToggleSandboxes!,
            ),

          // 진행 상태 (설정 바로 위) — 이것도 화면이다(예전엔 모달이었다).
          _ActivityItem(
            expanded: _expanded,
            runningCount: widget.runningProcessCount,
            selected: widget.processesSelected,
            onTap: widget.onToggleProcesses,
          ),
          const Divider(height: 1),

          // 최하단: 설정
          _NavItem(
            icon: Icons.settings,
            label: l.navSettings,
            expanded: _expanded,
            onTap: widget.onOpenSettings,
          ),

          // 접기/펼치기 토글
          _NavItem(
            icon: _expanded ? Icons.chevron_left : Icons.chevron_right,
            label: l.navCollapse,
            expanded: _expanded,
            onTap: _toggle,
          ),
        ],
      ),
    );
  }

}

/// 경로에서 폴더 이름만 뽑는다(3-OS 공통 — 구분자를 `/` 로 통일해 마지막 조각).
/// 빈 화면의 최근 목록도 같은 이름 규칙을 써야 좌측 메뉴와 같아 보인다.
String projectBasename(String path) {
  final parts = path.replaceAll('\\', '/').split('/')
    ..removeWhere((s) => s.isEmpty);
  return parts.isEmpty ? path : parts.last;
}

/// 좌측 메뉴의 일반 항목. 접힘 상태에서는 아이콘만, 펼침 상태에서는 아이콘 + 라벨.
///
/// [icon] 또는 [leading] 중 하나를 제공한다([leading] 우선).
class _NavItem extends StatelessWidget {
  const _NavItem({
    this.icon,
    this.leading,
    required this.label,
    required this.expanded,
    required this.onTap,
    this.tooltip,
    this.trailing,
    this.selected = false,
    this.badgeCount = 0,
    this.busy = false,
  }) : assert(icon != null || leading != null);

  final IconData? icon;
  final Widget? leading;
  final String label;
  final bool expanded;
  final VoidCallback onTap;
  final String? tooltip;

  /// 펼친 상태에서 라벨 오른쪽에 표시할 위젯(예: 제거 버튼).
  final Widget? trailing;

  /// 화면을 바꾸는 항목이 **지금 그 화면**일 때. 왼쪽 세로 막대 + 강조색.
  final bool selected;

  /// 아이콘 우상단 개수 배지(0 이면 없음).
  final int badgeCount;

  /// 이 항목의 프로젝트에서 생성이 돌고 있는지. 아이콘을 도는 고리로 감싼다 —
  /// **화면을 떠나 있어도 일이 계속된다는 것**을 보여 주는 자리다.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    Widget iconWidget =
        leading ?? Icon(icon, size: 22, color: tint);
    if (busy) {
      iconWidget = Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          iconWidget,
        ],
      );
    }
    if (badgeCount > 0) {
      iconWidget = Stack(
        clipBehavior: Clip.none,
        children: [
          iconWidget,
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                '$badgeCount',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onPrimary, height: 1),
              ),
            ),
          ),
        ],
      );
    }
    final content = InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: selected
            ? BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
                border: Border(
                  left: BorderSide(width: 3, color: theme.colorScheme.primary),
                ),
              )
            : null,
        child: Row(
          children: [
            SizedBox(width: selected ? 13 : 16),
            iconWidget,
            if (expanded) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selected ? theme.colorScheme.primary : null,
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
              ),
              ?trailing,
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );

    // 접힘 상태(또는 별도 tooltip 지정 시)에는 툴팁으로 라벨/경로 노출.
    final message = tooltip ?? (expanded ? null : label);
    return message == null ? content : Tooltip(message: message, child: content);
  }
}

/// 최근 프로젝트 타일: 폴더명 첫 글자를 담은 라운드 사각형(경로 기반 랜덤 컬러).
/// 프로젝트 타일: 폴더명 첫 글자를 담은 라운드 사각형(경로 기반 안정 컬러).
/// 좌측 메뉴와 빈 화면의 최근 목록이 함께 쓴다.
class ProjectMonogram extends StatelessWidget {
  const ProjectMonogram({super.key, required this.path, this.dimmed = false});

  final String path;

  /// 아직 열지 않은 프로젝트(최근 목록)는 흐리게 — 열린 것과 한눈에 갈린다.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final name = projectBasename(path);
    final letter = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    final color = _colorForPath(path);
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dimmed ? color.withValues(alpha: 0.38) : color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        letter,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }

  /// 경로 문자열을 해시해 안정적인(재시작에도 동일한) 색을 만든다.
  static Color _colorForPath(String path) {
    var hash = 0;
    for (final code in path.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor();
  }
}

/// 진행 상태(Activity) 아이콘. 실행 중 프로세스가 있으면 활성 표시 + 개수 배지 +
/// sync 아이콘이 회전하는 애니메이션.
class _ActivityItem extends StatefulWidget {
  const _ActivityItem({
    required this.expanded,
    required this.runningCount,
    this.selected = false,
    this.onTap,
  });

  final bool expanded;
  final int runningCount;

  /// 우측 영역이 지금 진행 상태 화면인지.
  final bool selected;

  final VoidCallback? onTap;

  @override
  State<_ActivityItem> createState() => _ActivityItemState();
}

class _ActivityItemState extends State<_ActivityItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  bool get _active => widget.runningCount > 0;

  @override
  void initState() {
    super.initState();
    _spin =
        AnimationController(vsync: this, duration: const Duration(seconds: 1));
    if (_active) _spin.repeat();
  }

  @override
  void didUpdateWidget(_ActivityItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 실행 중이면 계속 회전, 아니면 멈추고 원위치.
    if (_active && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!_active && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final active = _active;
    // 선택(이 화면을 보고 있음)과 활성(돌고 있음)은 다른 것이지만 색은 같이 쓴다 —
    // 구분은 왼쪽 세로 막대가 한다.
    final color = active || widget.selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    Widget icon = Icon(
      active ? Icons.sync : Icons.sync_disabled,
      size: 22,
      color: color,
    );
    if (active) icon = RotationTransition(turns: _spin, child: icon);

    final iconWithBadge = Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        if (active)
          Positioned(
            right: -6,
            top: -6,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                '${widget.runningCount}',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );

    final tooltipMsg = active
        ? l.activityRunningTooltip(widget.runningCount)
        : l.activityIdleTooltip;

    return Tooltip(
      message: tooltipMsg,
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          height: 48,
          // 선택 표시는 다른 화면 항목(`_NavItem`)과 같은 모양이어야 한다.
          decoration: widget.selected
              ? BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.10),
                  border: Border(
                    left:
                        BorderSide(width: 3, color: theme.colorScheme.primary),
                  ),
                )
              : null,
          child: Row(
            children: [
              SizedBox(width: widget.selected ? 13 : 16),
              iconWithBadge,
              if (widget.expanded) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    active
                        ? l.activityRunningLabel(widget.runningCount)
                        : l.activityTitle,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
