import 'package:flutter/material.dart';

import '../app/project_session.dart';
import '../webview/web_view_panel.dart';
import 'file_tree_view.dart';
import 'file_viewer_frame.dart';

/// 프로젝트 하나의 화면: **가운데 대화(웹)** + **우측 트리·뷰어(네이티브 틀 + 뷰어 웹뷰)**.
///
/// 예전에는 이 전체가 웹뷰 하나(`index.html`)였다. 모바일 준비로 우측을 네이티브로 옮겼다
/// (뷰어의 보기 영역만 웹 — 확장성 때문에). 폭·높이 조절선, 우측 숨기기(대화 헤더의 버튼),
/// 뷰어 전체화면이 여기 있다.
///
/// ★ **뷰어 웹뷰를 다시 만들지 않는다.** 전체화면이 되면 트리만 빠지고 뷰어 틀은 같은
/// 자리(같은 요소 — [GlobalKey])에서 커지기만 한다. 우측을 숨길 때도 트리에서 빼지 않고
/// 가린다([Offstage]) — 빼면 웹뷰가 죽고 다시 떠서 보던 파일을 처음부터 다시 그린다.
class ProjectPanel extends StatefulWidget {
  const ProjectPanel({
    super.key,
    required this.session,
    required this.themeMode,
    required this.langCode,
    this.visible = true,
  });

  final ProjectSession session;
  final ThemeMode themeMode;
  final String langCode;
  final bool visible;

  @override
  State<ProjectPanel> createState() => _ProjectPanelState();
}

class _ProjectPanelState extends State<ProjectPanel> {
  /// 우측 패널 폭(대화 쪽이 최소 [_minChat] 을 남기도록 자른다).
  double _sideWidth = 360;

  /// 우측 패널에서 트리가 차지하는 비율(나머지가 뷰어).
  double _treeFraction = 0.5;

  static const double _minSide = 220;
  static const double _minChat = 320;
  static const double _splitter = 6;

  final GlobalKey _viewerKey = GlobalKey(debugLabel: 'viewer-frame');
  final GlobalKey _treeKey = GlobalKey(debugLabel: 'file-tree');

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final viewer = session.viewer;
    return ListenableBuilder(
      listenable: Listenable.merge([session.sidePanelVisible, ?viewer]),
      builder: (context, _) => LayoutBuilder(builder: (context, box) {
        final showSide = session.sidePanelVisible.value;
        final fullscreen = viewer?.fullscreen ?? false;
        final total = box.maxWidth;
        final maxSide = (total - _minChat - _splitter).clamp(_minSide, double.infinity);
        final side = _sideWidth.clamp(_minSide, maxSide);
        final theme = Theme.of(context);
        return Stack(children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            right: showSide ? side + _splitter : 0,
            child: WebViewPanel(
              session: session,
              themeMode: widget.themeMode,
              langCode: widget.langCode,
              visible: widget.visible,
            ),
          ),
          if (showSide)
            Positioned(
              top: 0,
              bottom: 0,
              right: side,
              width: _splitter,
              child: _Splitter(
                vertical: true,
                onDrag: (d) => setState(() => _sideWidth = (side - d).clamp(_minSide, maxSide)),
              ),
            ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: fullscreen ? total : side,
            child: Offstage(
              offstage: !showSide && !fullscreen,
              child: Material(
                color: theme.colorScheme.surface,
                child: LayoutBuilder(builder: (context, sideBox) {
                  // 뷰어가 최소 160 은 갖게 한다(창이 아주 낮으면 하한이 이긴다 — clamp 역전 방지).
                  final maxTree = sideBox.maxHeight - 160 < 60 ? 60.0 : sideBox.maxHeight - 160;
                  final treeH = (sideBox.maxHeight * _treeFraction).clamp(60.0, maxTree);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!fullscreen) ...[
                        SizedBox(
                          height: treeH,
                          child: FileTreeView(key: _treeKey, session: session),
                        ),
                        SizedBox(
                          height: _splitter,
                          child: _Splitter(
                            vertical: false,
                            onDrag: (d) => setState(() => _treeFraction =
                                ((treeH + d) / sideBox.maxHeight).clamp(0.12, 0.88)),
                          ),
                        ),
                      ],
                      Expanded(
                        child: FileViewerFrame(
                          key: _viewerKey,
                          session: session,
                          themeMode: widget.themeMode,
                          langCode: widget.langCode,
                          visible: widget.visible && (showSide || fullscreen),
                        ),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ]);
      }),
    );
  }
}

/// 끌어서 크기를 바꾸는 선. [vertical] 이면 세로선(좌우로 끈다).
class _Splitter extends StatefulWidget {
  const _Splitter({required this.vertical, required this.onDrag});
  final bool vertical;
  final ValueChanged<double> onDrag;

  @override
  State<_Splitter> createState() => _SplitterState();
}

class _SplitterState extends State<_Splitter> {
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
