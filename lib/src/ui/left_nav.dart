import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 좌측 네비게이션 메뉴 (네이티브).
///
/// 구성:
/// - 최상단: 프로젝트 열기
/// - 그 아래: 최근 프로젝트 (MRU, 최대 5개)
/// - (가변 여백)
/// - 설정 바로 위: 진행 상태(Activity) 아이콘 — 실행 중 프로세스 힌트
/// - 최하단: 설정
///
/// 접기/펼치기 가능: 접으면 아이콘만, 펼치면 아이콘 + 라벨.
class LeftNav extends StatefulWidget {
  const LeftNav({
    super.key,
    required this.onNewProject,
    required this.onOpenProject,
    required this.onOpenSettings,
    this.recentProjects = const [],
    this.onOpenRecent,
    this.onRemoveRecent,
    this.runningProcessCount = 0,
  });

  final VoidCallback onNewProject;
  final VoidCallback onOpenProject;
  final VoidCallback onOpenSettings;

  /// 최근 프로젝트 경로 목록 (MRU 순서, 최대 5개). 실제 데이터는 추후 네이티브 설정에서 로드.
  final List<String> recentProjects;
  final ValueChanged<String>? onOpenRecent;

  /// 최근 목록에서만 제거(실제 폴더는 삭제하지 않음).
  final ValueChanged<String>? onRemoveRecent;

  /// 실행 중인 서브프로세스 수 (진행 상태 아이콘 표시용).
  final int runningProcessCount;

  static const double collapsedWidth = 56;
  static const double expandedWidth = 220;
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
    final recent = widget.recentProjects.take(LeftNav.maxRecent).toList();

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

          // 최근 프로젝트 (MRU) — 폴더명 첫 글자 모노그램 타일.
          if (recent.isNotEmpty)
            ...recent.map(
              (path) => _NavItem(
                leading: _ProjectMonogram(path: path),
                label: _basename(path),
                tooltip: path,
                expanded: _expanded,
                onTap: () => widget.onOpenRecent?.call(path),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: l.remove,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => widget.onRemoveRecent?.call(path),
                ),
              ),
            ),

          const Spacer(),

          // 진행 상태 (설정 바로 위)
          _ActivityItem(
            expanded: _expanded,
            runningCount: widget.runningProcessCount,
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

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
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
  }) : assert(icon != null || leading != null);

  final IconData? icon;
  final Widget? leading;
  final String label;
  final bool expanded;
  final VoidCallback onTap;
  final String? tooltip;

  /// 펼친 상태에서 라벨 오른쪽에 표시할 위젯(예: 제거 버튼).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 16),
            leading ??
                Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant),
            if (expanded) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
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
class _ProjectMonogram extends StatelessWidget {
  const _ProjectMonogram({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final name = _LeftNavState._basename(path);
    final letter = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    final color = _colorForPath(path);
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
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

/// 진행 상태(Activity) 아이콘. 실행 중 프로세스가 있으면 활성 표시 + 개수 배지.
class _ActivityItem extends StatelessWidget {
  const _ActivityItem({required this.expanded, required this.runningCount});

  final bool expanded;
  final int runningCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final active = runningCount > 0;
    final color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;

    final iconWithBadge = Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          active ? Icons.sync : Icons.sync_disabled,
          size: 22,
          color: color,
        ),
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
                '$runningCount',
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
        ? l.activityRunningTooltip(runningCount)
        : l.activityIdleTooltip;

    return Tooltip(
      message: tooltipMsg,
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 16),
            iconWithBadge,
            if (expanded) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  active ? l.activityRunningLabel(runningCount) : l.activityTitle,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}
