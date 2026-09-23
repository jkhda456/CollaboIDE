import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../app/project_session.dart';
import '../files/file_viewer.dart';
import '../platform/platform_features.dart';
import '../webview/viewer_web_view.dart';

/// 우측 패널 아래쪽 — **파일 뷰어의 틀**(네이티브) + 보기 영역(웹, [ViewerWebView]).
///
/// 틀이 가진 것: 파일명 · 뷰어 선택(후보는 웹의 레지스트리가 알려 준다) · 복사 ·
/// 연결 프로그램으로 열기 · 전체화면 · 내용 검색(보이는 부분 하이라이트) · 알림 줄
/// (대용량 안내·저장 실패). 상태는 [FileViewerController] 에 있다 — 틀은 그리기만 한다.
class FileViewerFrame extends StatefulWidget {
  const FileViewerFrame({
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
  State<FileViewerFrame> createState() => _FileViewerFrameState();
}

class _FileViewerFrameState extends State<FileViewerFrame> {
  bool _searchOpen = false;
  final TextEditingController _search = TextEditingController();
  Timer? _searchTimer;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _toggleSearch(FileViewerController v, bool open) {
    setState(() => _searchOpen = open);
    if (!open) {
      _search.clear();
      v.find('');
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewer = widget.session.viewer;
    if (viewer == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: viewer,
      builder: (context, _) => CallbackShortcuts(
        // 전체화면은 Esc 로 빠져나온다(초점이 웹뷰면 웹이 viewer.escape 로 알려 준다).
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => viewer.setFullscreen(false),
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, viewer),
            if (viewer.notice != null) _notice(context, viewer.notice!),
            const Divider(height: 1),
            Expanded(
              child: ViewerWebView(
                controller: viewer,
                themeMode: widget.themeMode,
                langCode: widget.langCode,
                visible: widget.visible,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, FileViewerController v) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final path = v.path;
    final hasFile = path != null;
    Widget iconBtn(IconData icon, String tip, VoidCallback? onTap) => IconButton(
          icon: Icon(icon, size: 17),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
        );

    if (_searchOpen) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _search,
              autofocus: true,
              style: theme.textTheme.bodySmall,
              decoration: InputDecoration(
                isDense: true,
                hintText: l.contentSearchPlaceholder,
                prefixIcon: const Icon(Icons.search, size: 16),
                border: const OutlineInputBorder(),
              ),
              onChanged: (q) {
                _searchTimer?.cancel();
                _searchTimer = Timer(const Duration(milliseconds: 150), () => v.find(q));
              },
            ),
          ),
          iconBtn(Icons.close, l.cancel, () => _toggleSearch(v, false)),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(children: [
        Expanded(
          child: Tooltip(
            message: path ?? '',
            child: Row(children: [
              Flexible(
                child: Text(
                  hasFile ? p.basename(path) : l.fileNone,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: hasFile ? FontWeight.w600 : null,
                    color: hasFile ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (v.loading) ...[
                const SizedBox(width: 6),
                const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
              ],
            ]),
          ),
        ),
        // 보기 방식 — 후보는 웹 레지스트리가 알려 준 것(확장·사용자 뷰어 포함).
        PopupMenuButton<String>(
          enabled: hasFile && v.viewers.isNotEmpty,
          tooltip: l.viewerModeTitle,
          onSelected: (id) => v.open(path!, viewerId: id),
          itemBuilder: (context) => [
            for (final c in v.viewers)
              CheckedPopupMenuItem(value: c.id, checked: c.id == v.viewerId, child: Text(c.label)),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(v.viewerLabel ?? (v.viewers.isNotEmpty ? v.viewers.first.label : '—'),
                  style: theme.textTheme.labelSmall),
              const Icon(Icons.arrow_drop_down, size: 16),
            ]),
          ),
        ),
        const SizedBox(width: 2),
        iconBtn(Icons.content_copy, l.copySelection, hasFile ? v.copy : null),
        if (PlatformFeatures.canOpenExternally)
          iconBtn(Icons.open_in_new, l.openWith,
              hasFile ? () => unawaited(widget.session.files.openExternal(path)) : null),
        iconBtn(v.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            v.fullscreen ? l.fullscreenExitTitle : l.fullscreenTitle, () => v.setFullscreen(!v.fullscreen)),
        iconBtn(Icons.search, l.contentSearchTitle, hasFile ? () => _toggleSearch(v, true) : null),
      ]),
    );
  }

  Widget _notice(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Text(text,
          style: theme.textTheme.labelSmall?.copyWith(color: Colors.orange.shade800)),
    );
  }
}
