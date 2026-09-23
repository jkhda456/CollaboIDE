import 'package:flutter/material.dart';

import '../app/project_session.dart';
import '../webview/web_view_panel.dart';
import 'adaptive.dart';
import 'file_tree_view.dart';
import 'file_viewer_frame.dart';

/// 프로젝트 하나의 화면: **가운데 대화(웹)** + **우측 트리·뷰어(네이티브 틀 + 뷰어 웹뷰)**.
///
/// 예전에는 이 전체가 웹뷰 하나(`index.html`)였다. 모바일 준비로 우측을 네이티브로 옮겼다
/// (뷰어의 보기 영역만 웹 — 확장성 때문에). 폭·높이 조절선, 우측 숨기기(대화 헤더의 버튼),
/// 뷰어 전체화면이 여기 있다.
///
/// **좁은 화면**([Breakpoints.sidePanelOverlay] 미만 — 휴대폰·좁은 창)에서는 우측을 나란히 두지 않고
/// 대화 위에 덮는다(바깥 누르기·닫기 버튼으로 접고, 왼쪽 가장자리로 폭 조절). 대화 웹뷰는 폭이 바뀌지
/// 않아 다시 그리지 않는다.
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

  /// 좁은 화면에서 대화 위를 덮는 우측 패널 폭(null = 화면의 [_overlayFraction]).
  double? _overlayWidth;

  /// 우측 패널에서 트리가 차지하는 비율(나머지가 뷰어).
  double _treeFraction = 0.5;

  /// 직전 배치가 덮기였는가(나란히 → 덮기로 바뀌는 순간을 알려고).
  bool? _wasOverlay;

  static const double _minSide = 220;
  static const double _minChat = 320;
  static const double _splitter = 6;
  static const double _overlayFraction = 0.88;

  /// 덮을 때 대화 쪽에 남기는 띠(눌러서 닫을 자리).
  static const double _overlayGap = 40;

  final GlobalKey _viewerKey = GlobalKey(debugLabel: 'viewer-frame');
  final GlobalKey _treeKey = GlobalKey(debugLabel: 'file-tree');

  void _hideSide() => widget.session.sidePanelVisible.value = false;

  /// 나란히 → 덮기로 바뀌면(휴대폰에서 처음 열 때 포함) 우측을 접는다 — 대화를 가리고 시작하지 않게.
  /// 파일을 열면([ProjectSession.openInViewer]) 다시 펴진다.
  void _onLayoutMode(bool overlay) {
    if (_wasOverlay == overlay) return;
    final becameOverlay = overlay && _wasOverlay != true;
    _wasOverlay = overlay;
    if (becameOverlay && widget.session.sidePanelVisible.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hideSide();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final viewer = session.viewer;
    return ListenableBuilder(
      listenable: Listenable.merge([session.sidePanelVisible, ?viewer]),
      builder: (context, _) => LayoutBuilder(builder: (context, box) {
        final total = box.maxWidth;
        final overlay = total < Breakpoints.sidePanelOverlay;
        _onLayoutMode(overlay);
        return overlay ? _buildOverlay(context, box) : _buildSideBySide(context, box);
      }),
    );
  }

  Widget _chat() => WebViewPanel(
        session: widget.session,
        themeMode: widget.themeMode,
        langCode: widget.langCode,
        visible: widget.visible,
      );

  /// 넓은 화면: 대화 | 조절선 | 우측.
  Widget _buildSideBySide(BuildContext context, BoxConstraints box) {
    final showSide = widget.session.sidePanelVisible.value;
    final fullscreen = widget.session.viewer?.fullscreen ?? false;
    final total = box.maxWidth;
    final maxSide = (total - _minChat - _splitter).clamp(_minSide, double.infinity);
    final side = _sideWidth.clamp(_minSide, maxSide);
    return Stack(children: [
      Positioned(left: 0, top: 0, bottom: 0, right: showSide ? side + _splitter : 0, child: _chat()),
      if (showSide)
        Positioned(
          top: 0,
          bottom: 0,
          right: side,
          width: _splitter,
          child: Splitter(
            vertical: true,
            onDrag: (d) => setState(() => _sideWidth = (side - d).clamp(_minSide, maxSide)),
          ),
        ),
      Positioned(
        top: 0,
        bottom: 0,
        right: 0,
        width: fullscreen ? total : side,
        child: _side(context, visible: showSide || fullscreen),
      ),
    ]);
  }

  /// 좁은 화면: 대화는 그대로 두고 우측을 **위에 덮는다**. 바깥(어두운 띠)을 누르거나 트리 머리의
  /// 닫기로 접고, 왼쪽 가장자리를 끌어 폭을 바꾼다.
  Widget _buildOverlay(BuildContext context, BoxConstraints box) {
    final showSide = widget.session.sidePanelVisible.value;
    final fullscreen = widget.session.viewer?.fullscreen ?? false;
    final total = box.maxWidth;
    final minWidth = _minSide < total ? _minSide : total;
    final maxWidth = total - _overlayGap < minWidth ? minWidth : total - _overlayGap;
    final width = fullscreen ? total : (_overlayWidth ?? total * _overlayFraction).clamp(minWidth, maxWidth);
    final open = showSide || fullscreen;
    return Stack(children: [
      Positioned.fill(child: _chat()),
      if (open && !fullscreen)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _hideSide,
            child: const ColoredBox(color: Color(0x55000000)),
          ),
        ),
      Positioned(
        top: 0,
        bottom: 0,
        right: 0,
        width: width,
        child: Offstage(
          offstage: !open,
          child: Material(
            elevation: 8,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!fullscreen)
                  SizedBox(
                    width: _splitter,
                    child: Splitter(
                      vertical: true,
                      onDrag: (d) => setState(() => _overlayWidth = (width - d).clamp(minWidth, maxWidth)),
                    ),
                  ),
                Expanded(child: _side(context, visible: open, onClose: _hideSide)),
              ],
            ),
          ),
        ),
      ),
    ]);
  }

  /// 우측 내용: 트리(위) | 조절선 | 뷰어(아래). 전체화면이면 뷰어만.
  Widget _side(BuildContext context, {required bool visible, VoidCallback? onClose}) {
    final session = widget.session;
    final fullscreen = session.viewer?.fullscreen ?? false;
    final theme = Theme.of(context);
    return Offstage(
      offstage: !visible,
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
                  child: FileTreeView(key: _treeKey, session: session, onClose: onClose),
                ),
                SizedBox(
                  height: _splitter,
                  child: Splitter(
                    vertical: false,
                    onDrag: (d) => setState(
                        () => _treeFraction = ((treeH + d) / sideBox.maxHeight).clamp(0.12, 0.88)),
                  ),
                ),
              ],
              Expanded(
                child: FileViewerFrame(
                  key: _viewerKey,
                  session: session,
                  themeMode: widget.themeMode,
                  langCode: widget.langCode,
                  visible: widget.visible && visible,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
