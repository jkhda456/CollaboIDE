import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../app/project_session.dart';
import '../files/project_files.dart';
import '../fs/entry_name.dart';
import '../fs/file_service.dart';

/// 우측 패널 위쪽 — **네이티브 파일 트리**.
///
/// 예전엔 대화 웹뷰 안의 HTML 트리였다. 모바일 준비로 네이티브로 옮겼다(모델은
/// [ProjectFiles], 세션 소유). 기능은 그대로다: 펼침(상태 보존)·실시간 갱신·파일명 검색·
/// 우클릭(모바일은 길게 누르기) 메뉴·드래그 이동(Ctrl/⌥ 를 누르고 놓으면 복사)·
/// 계획 파일 바로가기·탐색기에서 열기.
class FileTreeView extends StatefulWidget {
  const FileTreeView({super.key, required this.session});

  final ProjectSession session;

  @override
  State<FileTreeView> createState() => _FileTreeViewState();
}

class _FileTreeViewState extends State<FileTreeView> {
  ProjectFiles get files => widget.session.files;

  StreamSubscription<String>? _errSub;
  bool _searchOpen = false;
  final TextEditingController _search = TextEditingController();
  Timer? _searchTimer;
  final ScrollController _scroll = ScrollController();

  /// 드래그가 지나가는 폴더(강조 표시).
  String? _dropTarget;

  static bool get _touch =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _errSub = files.errors.listen(_showError);
  }

  @override
  void didUpdateWidget(FileTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _errSub?.cancel();
      _errSub = files.errors.listen(_showError);
    }
  }

  @override
  void dispose() {
    _errSub?.cancel();
    _searchTimer?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 4)));
  }

  // ------------------------------------------------------------------ 열기 · 검색

  void _openFile(String path) {
    files.select(path);
    widget.session.viewer?.open(path);
  }

  void _toggleSearch(bool open) {
    setState(() => _searchOpen = open);
    if (!open) {
      _search.clear();
      _searchTimer?.cancel();
      unawaited(files.search(''));
    }
  }

  void _onSearchChanged(String q) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 250), () => unawaited(files.search(q)));
  }

  // ------------------------------------------------------------------ 메뉴 · 대화상자

  /// 우클릭(길게 누르기) 메뉴. [entry] 가 null 이면 빈 영역 = 프로젝트 루트 대상
  /// (만들기와 경로 복사만 — 루트는 여기서 못 건드린다).
  Future<void> _showMenu(Offset globalPos, FsEntry? entry) async {
    final l = AppLocalizations.of(context);
    final path = entry?.path ?? files.root;
    final isRoot = entry == null;
    final isDir = entry?.isDir ?? true;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(globalPos & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'newFile', child: Text(l.newFile)),
        PopupMenuItem(value: 'newFolder', child: Text(l.newFolder)),
        if (!isRoot) ...[
          const PopupMenuDivider(),
          PopupMenuItem(value: 'rename', child: Text(l.rename)),
          PopupMenuItem(
            value: 'delete',
            child: Text(l.delete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
        const PopupMenuDivider(),
        if (!isRoot && !isDir) PopupMenuItem(value: 'openWith', child: Text(l.openWith)),
        PopupMenuItem(value: 'copyPath', child: Text(l.copyPath)),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'newFile':
      case 'newFolder':
        // 폴더를 눌렀으면 그 안, 파일을 눌렀으면 그 파일이 있는 폴더.
        final parent = isDir ? path : p.dirname(path);
        final dir = choice == 'newFolder';
        final name = await _askName(title: dir ? l.newFolder : l.newFile, where: parent, ok: l.create);
        if (name != null) await files.create(parent, name, dir: dir);
      case 'rename':
        final name = await _askName(
            title: l.rename, where: path, ok: l.rename, initial: p.basename(path), selectStem: true);
        if (name != null) await files.rename(path, name);
      case 'delete':
        if (await _confirmDelete(path, isDir)) await files.delete(path);
      case 'openWith':
        await files.openExternal(path);
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: path));
    }
  }

  /// 이름 입력(새 파일·새 폴더·이름 변경). 규칙은 네이티브 판정과 같은 함수로 즉시 보여 준다.
  Future<String?> _askName({
    required String title,
    required String where,
    required String ok,
    String initial = '',
    bool selectStem = false,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => _NameDialog(
            title: title, where: where, ok: ok, initial: initial, selectStem: selectStem),
      );

  /// 삭제 확인 — **되돌릴 수 없다**(휴지통을 거치지 않는다)는 것을 분명히 알린다.
  Future<bool> _confirmDelete(String path, bool isDir) async {
    final l = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.delete),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(path),
            const SizedBox(height: 8),
            Text(isDir ? l.deleteFolderWarn : l.deleteWarn,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------------ 드래그

  /// Ctrl(Windows/Linux) · ⌥(macOS) 를 누르고 놓으면 복사, 아니면 이동.
  bool get _copyModifier {
    final k = HardwareKeyboard.instance;
    return k.isControlPressed || k.isAltPressed || k.isMetaPressed;
  }

  bool _canDrop(String src, String dir) =>
      !p.equals(src, dir) && !p.isWithin(src, dir) && !p.equals(p.dirname(src), dir);

  Widget _dropArea(String dir, Widget child) => DragTarget<String>(
        onWillAcceptWithDetails: (d) {
          final ok = _canDrop(d.data, dir);
          if (ok) setState(() => _dropTarget = dir);
          return ok;
        },
        onLeave: (_) => setState(() => _dropTarget = null),
        onAcceptWithDetails: (d) {
          setState(() => _dropTarget = null);
          unawaited(files.move(d.data, dir, copy: _copyModifier));
        },
        builder: (context, candidate, rejected) => child,
      );

  Widget _draggable(FsEntry e, Widget child) {
    final feedback = Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(e.name),
      ),
    );
    return _touch
        ? LongPressDraggable<String>(data: e.path, feedback: feedback, child: child)
        : Draggable<String>(data: e.path, feedback: feedback, dragAnchorStrategy: pointerDragAnchorStrategy, child: child);
  }

  // ------------------------------------------------------------------ 그리기

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: files,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          Expanded(child: files.searching ? _results(context) : _tree(context)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget iconBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
          icon: Icon(icon, size: 18),
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
                hintText: l.fileSearchPlaceholder,
                prefixIcon: const Icon(Icons.search, size: 16),
                border: const OutlineInputBorder(),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          iconBtn(Icons.close, l.cancel, () => _toggleSearch(false)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(children: [
        Expanded(
          child: Tooltip(
            message: files.root,
            child: Text(p.basename(files.root),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ),
        // 계획 파일 바로가기 — `.collabo` 안에만 생겨 사용자가 존재를 모르고 지나치기 쉽다.
        if (files.playbookExists)
          iconBtn(Icons.checklist, l.openPlaybook, () => widget.session.openInViewer(files.playbookPath)),
        iconBtn(Icons.folder_open_outlined, l.openInExplorer, () => unawaited(files.openExternal(files.root))),
        iconBtn(Icons.search, l.fileSearchTitle, () => _toggleSearch(true)),
      ]),
    );
  }

  Widget _tree(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rows = files.visibleRows;
    final rootLoaded = files.childrenOf(files.root) != null;
    Widget body;
    if (!rootLoaded) {
      body = _hint(context, l.treeLoading);
    } else if (rows.isEmpty) {
      body = _hint(context, l.folderEmpty);
    } else {
      body = ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: rows.length,
        itemExtent: 26,
        itemBuilder: (context, i) => _row(context, rows[i]),
      );
    }
    // 빈 영역 = 루트: 우클릭 메뉴(만들기) · 드롭(루트로 옮기기).
    return _dropArea(
      files.root,
      GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _showMenu(d.globalPosition, null),
        onLongPressStart: _touch ? (d) => _showMenu(d.globalPosition, null) : null,
        child: Container(
          color: _dropTarget == files.root ? theme.colorScheme.primary.withValues(alpha: 0.06) : null,
          child: body,
        ),
      ),
    );
  }

  Widget _row(BuildContext context, TreeRow r) {
    final theme = Theme.of(context);
    final e = r.entry;
    final selected = files.selected != null && p.equals(files.selected!, e.path);
    final expanded = e.isDir && files.isExpanded(e.path);
    final dropHere = _dropTarget == e.path;
    Widget row = InkWell(
      onTap: () => e.isDir ? files.toggle(e.path) : _openFile(e.path),
      onSecondaryTapUp: (d) => _showMenu(d.globalPosition, e),
      child: Container(
        padding: EdgeInsets.only(left: r.depth * 14.0 + 4, right: 8),
        decoration: BoxDecoration(
          color: dropHere
              ? theme.colorScheme.primary.withValues(alpha: 0.14)
              : selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.10)
                  : null,
          border: dropHere ? Border.all(color: theme.colorScheme.primary, width: 1) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(children: [
          SizedBox(
            width: 18,
            child: e.isDir
                ? Icon(expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16, color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          Icon(
            e.isDir ? (expanded ? Icons.folder_open : Icons.folder) : Icons.insert_drive_file_outlined,
            size: 15,
            color: e.isDir ? theme.colorScheme.primary.withValues(alpha: 0.8) : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: e.isDir ? FontWeight.w500 : null,
                  color: theme.colorScheme.onSurface,
                )),
          ),
          if (e.isDir && files.isLoading(e.path) && expanded)
            const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5)),
        ]),
      ),
    );
    if (_touch) {
      // 모바일: 길게 누르기 = 메뉴. 드래그는 길게 누른 채 끄는 것(LongPressDraggable)과 겹치므로
      // 메뉴를 우선한다 — 옮기기는 메뉴의 잘라내기가 생기면 그쪽으로(아직 없음).
      row = GestureDetector(onLongPressStart: (d) => _showMenu(d.globalPosition, e), child: row);
    } else {
      row = _draggable(e, row);
    }
    return e.isDir ? _dropArea(e.path, row) : row;
  }

  Widget _results(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final results = files.results;
    if (results == null) return _hint(context, l.treeLoading);
    if (results.isEmpty) return _hint(context, l.noResults);
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final e = results[i];
        final rel = p.relative(p.dirname(e.path), from: files.root);
        return InkWell(
          onTap: () => _openFile(e.path),
          onSecondaryTapUp: (d) => _showMenu(d.globalPosition, e),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                if (rel != '.')
                  Text(rel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// 이름 입력 대화상자. 입력 컨트롤러는 **이 위젯이 소유한다** — 닫히는 애니메이션 동안에도
/// 입력칸이 다시 그려지므로, 대화상자의 결과가 돌아온 시점에 버리면 폐기된 컨트롤러를 쓰게 된다.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.where,
    required this.ok,
    required this.initial,
    required this.selectStem,
  });

  final String title;
  final String where;
  final String ok;
  final String initial;
  final bool selectStem;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    // 이름 변경은 확장자를 뺀 부분만 선택한다 — 확장자를 지우는 실수를 줄인다.
    final dot = widget.initial.lastIndexOf('.');
    _ctl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.selectStem && dot > 0 ? dot : widget.initial.length);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String? _message(AppLocalizations l, String v) => switch (validateProjectName(v)) {
        null => null,
        ProjectNameError.empty => l.nameEmpty,
        ProjectNameError.invalidChars => l.nameInvalidChars,
        ProjectNameError.invalidName => l.nameInvalidName,
        ProjectNameError.trailingDot => l.nameTrailingDot,
        ProjectNameError.reserved => l.nameReserved,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final value = _ctl.text;
    final err = value.isEmpty ? null : _message(l, value);
    final unchanged = widget.initial.isNotEmpty && value.trim() == widget.initial;
    final canOk = value.trim().isNotEmpty && _message(l, value) == null && !unchanged;
    void submit() {
      if (canOk) Navigator.pop(context, value.trim());
    }

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.where,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: _ctl,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                  isDense: true, border: const OutlineInputBorder(), errorText: err),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: canOk ? submit : null, child: Text(widget.ok)),
      ],
    );
  }
}
