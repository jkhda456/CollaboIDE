import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

/// 좁은 화면(휴대폰·좁은 창) 대비 공용 배치 도구.
///
///  - [Breakpoints]: 판단 기준 폭.
///  - [Splitter]: 끌어서 크기를 바꾸는 선(프로젝트 패널·목록/상세 공용).
///  - [ResizableSplit]: 목록 | 상세 — 목록 폭을 끌어서 바꾼다.
///  - [MasterDetail]: 넓으면 [ResizableSplit], 좁으면 목록 → 상세(뒤로) 한 장씩.
///  - [adaptiveDialogWidth] / [isCompactScreen]: 대화상자 폭·전체화면 판단.
abstract final class Breakpoints {
  /// 이보다 좁으면 휴대폰 배치(대화상자 전체화면, 좌측 메뉴 펼침은 덮기).
  static const double compact = 600;

  /// 프로젝트 화면에서 이보다 좁으면 우측(트리·뷰어)을 나란히 두지 않고 대화 위에 덮는다
  /// (대화 최소 320 + 우측 기본 360 + 여유).
  static const double sidePanelOverlay = 720;
}

/// 화면(창) 폭이 휴대폰 배치인가.
bool isCompactScreen(BuildContext context) => MediaQuery.sizeOf(context).width < Breakpoints.compact;

/// 대화상자 내용 폭: [preferred] 를 쓰되 화면에 들어가게 줄인다.
/// [margin] 은 화면 폭에서 빼는 양 — `AlertDialog` 는 바깥 여백 40씩 + 안쪽 여백 24씩이라 128.
double adaptiveDialogWidth(BuildContext context, double preferred, {double margin = 128}) {
  final available = MediaQuery.sizeOf(context).width - margin;
  return preferred < available ? preferred : (available < 200 ? 200 : available);
}

/// 끌어서 크기를 바꾸는 선. [vertical] 이면 세로선(좌우로 끈다).
class Splitter extends StatefulWidget {
  const Splitter({super.key, required this.vertical, required this.onDrag});
  final bool vertical;
  final ValueChanged<double> onDrag;

  @override
  State<Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<Splitter> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _hover || _drag;
    return MouseRegion(
      cursor: widget.vertical ? SystemMouseCursors.resizeColumn : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: widget.vertical ? (_) => setState(() => _drag = true) : null,
        onHorizontalDragUpdate: widget.vertical ? (d) => widget.onDrag(d.delta.dx) : null,
        onHorizontalDragEnd: widget.vertical ? (_) => setState(() => _drag = false) : null,
        onVerticalDragStart: widget.vertical ? null : (_) => setState(() => _drag = true),
        onVerticalDragUpdate: widget.vertical ? null : (d) => widget.onDrag(d.delta.dy),
        onVerticalDragEnd: widget.vertical ? null : (_) => setState(() => _drag = false),
        child: Container(
          decoration: BoxDecoration(
            color: active ? theme.colorScheme.primary.withValues(alpha: 0.6) : theme.colorScheme.surface,
            border: widget.vertical
                ? Border(left: BorderSide(color: theme.dividerColor))
                : Border(top: BorderSide(color: theme.dividerColor)),
          ),
        ),
      ),
    );
  }
}

/// 목록 | 상세. 목록 폭을 [Splitter] 로 끌어서 바꾼다(상세가 최소 [minEnd] 를 갖도록 자른다).
class ResizableSplit extends StatefulWidget {
  const ResizableSplit({
    super.key,
    required this.start,
    required this.end,
    this.initialStartWidth = 280,
    this.minStart = 180,
    this.minEnd = 240,
  });

  final Widget start;
  final Widget end;
  final double initialStartWidth;
  final double minStart;
  final double minEnd;

  static const double splitterWidth = 6;

  @override
  State<ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends State<ResizableSplit> {
  late double _startWidth = widget.initialStartWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final maxStart = box.maxWidth - widget.minEnd - ResizableSplit.splitterWidth;
      final start = _startWidth.clamp(widget.minStart, maxStart < widget.minStart ? widget.minStart : maxStart);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: start, child: widget.start),
          SizedBox(
            width: ResizableSplit.splitterWidth,
            child: Splitter(
              vertical: true,
              onDrag: (d) => setState(() => _startWidth = start + d),
            ),
          ),
          Expanded(child: widget.end),
        ],
      );
    });
  }
}

/// 넓으면 목록 | 상세([ResizableSplit]), 좁으면 **한 장씩**: [showDetail] 이 거짓이면 목록,
/// 참이면 상세 위에 뒤로 버튼 줄을 붙인다([onBack] 이 목록으로 돌아간다).
///
/// 좁은지는 **이 위젯이 받은 폭**으로 판단한다(창 폭이 아니라) — 좌측 메뉴·대화상자 안에서도 맞다.
class MasterDetail extends StatelessWidget {
  const MasterDetail({
    super.key,
    required this.master,
    required this.detail,
    required this.showDetail,
    required this.onBack,
    this.detailTitle,
    this.initialMasterWidth = 280,
    this.compactBelow = 560,
  });

  final Widget master;
  final Widget detail;
  final bool showDetail;
  final VoidCallback onBack;
  final String? detailTitle;
  final double initialMasterWidth;

  /// 이 폭보다 좁으면 한 장씩 보여 준다.
  final double compactBelow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= compactBelow) {
        return ResizableSplit(start: master, end: detail, initialStartWidth: initialMasterWidth);
      }
      if (!showDetail) return master;
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                IconButton(
                  tooltip: AppLocalizations.of(context).back,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                ),
                if (detailTitle != null)
                  Expanded(
                    child: Text(detailTitle!,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: detail),
        ],
      );
    });
  }
}
