import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../app/workspace_controller.dart';
import '../fs/file_service.dart';
import '../viewers/viewer_assets.dart';
import '../viewers/viewer_rule.dart';
import '../viewers/viewer_source.dart';
import '../webview/platform_web_view.dart';
import '../webview/web_assets.dart';
import 'project_files.dart';

/// 뷰어 드롭다운의 한 줄.
class ViewerChoice {
  const ViewerChoice(this.id, this.label);
  final String id;
  final String label;
}

/// **파일 뷰어** — 네이티브 틀(파일명·뷰어 선택·복사·외부 열기·전체화면·알림)과
/// 웹 보기 영역(`assets/web/viewer.html`) 사이의 창구. 세션이 소유한다.
///
/// 보기 영역을 웹에 남긴 이유: 뷰어는 **플러그인**이다(마크다운·hex·압축·사용자 JS/wasm).
/// 뷰어를 고르는 규칙(`match()`), 대용량 가상 스크롤, 편집기의 저장까지 전부 JS 쪽
/// 계약이라, 틀만 네이티브로 옮기고 레지스트리는 웹에 둔다. 어떤 뷰어가 골랐는지·후보가
/// 무엇인지는 웹이 `viewer.state` 로 보고하고, 틀은 그걸 그리기만 한다.
///
/// ★ 웹뷰는 **없을 수 있다**(화면이 안 떴거나 다시 붙는 중). 그동안 연 파일은
/// 기억해 두었다가 웹이 `ready` 를 보내면 다시 연다([_pushAll]).
class FileViewerController extends ChangeNotifier {
  FileViewerController(
    this._workspace,
    this._files, {
    FileService? fileService,
    Future<List<String>> Function(List<ViewerSource>)? viewerStager,
  })  : _fs = fileService ?? _files.fs,
        _stageViewers = viewerStager ?? ViewerAssets.sync {
    _changeSub = _files.changes.listen(_onFsChange);
    _eventSub = _files.events.listen(_onFsOp);
    _viewerSignature = _viewerSourcesSignature();
    _viewerRuleSignature = _viewerRulesSignature();
    _workspace.addListener(_onWorkspaceChanged);
  }

  final WorkspaceController _workspace;
  final ProjectFiles _files;
  final FileService _fs;
  final Future<List<String>> Function(List<ViewerSource>) _stageViewers;
  late final StreamSubscription<FsChange> _changeSub;
  late final StreamSubscription<FsOpEvent> _eventSub;

  PlatformWebView? _view;
  StreamSubscription<dynamic>? _msgSub;
  bool _disposed = false;

  // ---- 틀이 그리는 상태 (웹이 viewer.state 로 알려 준다) ----
  String? _path;
  String? _viewerId;
  List<ViewerChoice> _viewers = const [];
  String? _notice;
  bool _loading = false;
  String? _error;
  bool _fullscreen = false;

  /// 보고 있는(또는 여는 중인) 파일. 없으면 null.
  String? get path => _path;
  String? get viewerId => _viewerId;

  /// 쓸 수 있는 뷰어(우선순위 순). 드롭다운이 이걸 그린다.
  List<ViewerChoice> get viewers => _viewers;

  /// 대용량 안내 같은 한 줄(웹이 언어팩으로 만든 문구).
  String? get notice => _notice;
  bool get loading => _loading;
  String? get error => _error;
  bool get fullscreen => _fullscreen;

  String? get viewerLabel {
    for (final v in _viewers) {
      if (v.id == _viewerId) return v.label;
    }
    return null;
  }

  // ------------------------------------------------------------------ 화면이 부르는 것

  /// 파일을 연다. [viewerId] 를 주면 그 뷰어로(드롭다운), 아니면 웹이 고른다.
  void open(String path, {String? viewerId}) {
    // 같은 파일을 다시 열면(자동 갱신·재선택) 고른 뷰어를 유지한다.
    _viewerId = viewerId ?? (_path == path ? _viewerId : null);
    _path = path;
    _loading = true;
    _error = null;
    _notify();
    _post({'type': 'viewer.open', 'path': path, 'viewerId': ?_viewerId});
  }

  /// 뷰어를 비운다(보던 파일이 지워졌을 때 등).
  void clear() {
    _path = null;
    _viewerId = null;
    _notice = null;
    _loading = false;
    _error = null;
    _notify();
    _post({'type': 'viewer.clear'});
  }

  /// 내용 검색(보이는 부분에 하이라이트). 빈 문자열이면 지운다.
  void find(String query) => _post({'type': 'viewer.find', 'query': query});

  /// 선택 영역(없으면 전체)을 클립보드로. 선택은 웹만 안다 — 웹이 `clipboard.write` 로 돌려준다.
  void copy() => _post({'type': 'viewer.copy'});

  void setFullscreen(bool value) {
    if (_fullscreen == value) return;
    _fullscreen = value;
    _notify();
  }

  // ------------------------------------------------------------------ 웹뷰

  Future<void> attachView(PlatformWebView view) async {
    if (identical(_view, view)) return;
    await _msgSub?.cancel();
    _view = view;
    _msgSub = view.messages.listen(_onMessage);
    await _pushAll();
  }

  Future<void> detachView() async {
    await _msgSub?.cancel();
    _msgSub = null;
    _view = null;
  }

  /// 웹을 현재 상태로 맞춘다(붙을 때 · `ready`). 페이지가 새로 떴으면 아무것도 없다.
  Future<void> _pushAll() async {
    await _pushViewerRules();
    await _syncUserViewers();
    final path = _path;
    if (path != null) {
      _post({'type': 'viewer.open', 'path': path, 'viewerId': ?_viewerId});
    }
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> msg;
    try {
      msg = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'ready':
        unawaited(_pushAll());
      case 'viewer.state':
        _onState(msg);
      case 'viewer.escape':
        // 초점이 웹뷰에 있으면 Esc 가 여기로 온다 — 전체화면은 틀(네이티브)의 것이다.
        setFullscreen(false);
      case 'viewers.list':
        _handleViewersList(msg['viewers']);
      case 'viewer.asset':
        unawaited(_handleViewerAsset(msg['from'] as String?, msg['name'] as String?));
      case 'archive.entry':
        unawaited(_handleArchiveEntry(msg['path'] as String?, msg['name'] as String?));
      case 'file.open':
        unawaited(_handleFileOpen(msg['path'] as String?, msg['mode'] as String?));
      case 'file.window':
        unawaited(_handleFileWindow(
          msg['path'] as String?,
          msg['mode'] as String?,
          (msg['from'] as num?)?.toInt() ?? 0,
          (msg['count'] as num?)?.toInt() ?? 0,
        ));
      case 'file.save':
        unawaited(handleFileSave(msg['path'] as String?, msg['content'] as String?));
      case 'clipboard.write':
        final text = msg['text'] as String?;
        if (text != null) unawaited(Clipboard.setData(ClipboardData(text: text)));
      case 'open.external':
        final uri = Uri.tryParse((msg['url'] as String?) ?? '');
        if (uri != null) {
          unawaited(launchUrl(uri, mode: LaunchMode.externalApplication)
              .then((_) {}, onError: (_) {}));
        }
    }
  }

  /// 웹이 보고한 뷰어 상태. **늦게 온 보고**(다른 파일을 이미 열었다)는 버린다.
  void _onState(Map<String, dynamic> msg) {
    final path = msg['path'] as String?;
    if (_path != null && path != null && path != _path) return;
    if (path == null && _path != null && msg['cleared'] != true) return;
    _path = path;
    _viewerId = msg['viewerId'] as String?;
    _viewers = [
      for (final v in (msg['viewers'] as List?) ?? const [])
        if (v is Map) ViewerChoice('${v['id']}', '${v['label'] ?? v['id']}'),
    ];
    final notice = msg['notice'] as String?;
    _notice = notice == null || notice.isEmpty ? null : notice;
    _loading = msg['loading'] == true;
    final error = msg['error'] as String?;
    _error = error == null || error.isEmpty ? null : error;
    _notify();
  }

  // ------------------------------------------------------------------ 파일 변화 따라가기

  void _onFsChange(FsChange change) {
    // 보고 있는 파일이 바뀌었는지는 웹이 판단한다(방금 저장한 변경은 다시 읽지 않는다 —
    // 그 기록은 웹에 있다). 여기서는 목록만 넘긴다.
    _post({'type': 'fs.change', 'files': change.files});
  }

  void _onFsOp(FsOpEvent e) {
    final cur = _path;
    switch (e) {
      case FsCreated(:final path, :final isDir):
        // 만든 파일은 바로 열어 편집할 수 있게.
        if (!isDir) open(path);
      case FsMoved(:final from, :final to):
        if (cur == null) return;
        if (p.equals(cur, from)) {
          open(to, viewerId: _viewerId);
        } else if (p.isWithin(from, cur)) {
          open(p.join(to, p.relative(cur, from: from)), viewerId: _viewerId);
        }
      case FsDeleted(:final path):
        if (cur != null && (p.equals(cur, path) || p.isWithin(path, cur))) clear();
    }
  }

  // ------------------------------------------------------------------ 뷰어 설정 · 사용자 뷰어

  String _viewerSignature = '';
  String _viewerRuleSignature = '';

  /// 컨트롤러 알림 중 **실제로 달라진 것만** 웹에 반영한다(알림은 자주 온다 — 프로세스
  /// 레지스트리도 포워드된다. 매번 스테이징하면 파일 복사가 반복된다).
  void _onWorkspaceChanged() {
    final vsig = _viewerSourcesSignature();
    if (vsig != _viewerSignature) {
      _viewerSignature = vsig;
      unawaited(_syncUserViewers());
    }
    final rsig = _viewerRulesSignature();
    if (rsig != _viewerRuleSignature) {
      _viewerRuleSignature = rsig;
      unawaited(_pushViewerRules());
    }
  }

  String _viewerSourcesSignature() =>
      jsonEncode([for (final v in _workspace.viewerSources) v.id]);

  /// 뷰어 **목록 보고**(`viewers.list`)도 컨트롤러 알림을 일으키므로, 여기엔 사용자
  /// 설정만 넣는다 — 목록을 넣으면 보고 → 재전송 → 보고의 순환이 된다.
  String _viewerRulesSignature() => jsonEncode(_viewerRulesJson());

  Map<String, Object?> _viewerRulesJson() => {
        'rules': {
          for (final e in _workspace.viewerRules.entries) e.key: e.value.toJson(),
        },
        'order': _workspace.viewerOrder,
      };

  Future<void> _pushViewerRules() async {
    try {
      await _view?.executeScript('window.collaboSetViewerRules && '
          'window.collaboSetViewerRules(${jsonEncode(_viewerRulesJson())})');
    } catch (_) {
      // 웹이 아직 준비 전 — `ready` 에서 다시 보낸다.
    }
  }

  /// 사용자 뷰어(JS)를 웹 루트로 복사한 뒤 **현재 목록 전체**를 넘긴다. 무엇을 얹고
  /// 내릴지는 웹이 정한다(어떤 스크립트가 로드됐는지는 웹만 안다). 빈 목록도 보낸다.
  Future<void> _syncUserViewers() async {
    List<String> urls;
    try {
      urls = await _stageViewers(_workspace.viewerSources);
    } catch (_) {
      return; // 스테이징 실패(권한 등) — 기본 뷰어로 계속 동작한다.
    }
    if (_disposed) return;
    try {
      await _view?.executeScript('window.collaboSyncUserViewers && '
          'window.collaboSyncUserViewers(${jsonEncode(urls)})');
    } catch (_) {}
  }

  void _handleViewersList(Object? raw) {
    if (raw is! List) return;
    _workspace.setRegisteredViewers([
      for (final e in raw)
        if (e is Map) ViewerInfo.fromJson(e.cast<String, Object?>()),
    ]);
  }

  // ------------------------------------------------------------------ 읽기 · 쓰기

  FileViewMode? _viewModeFor(String? modeName) => switch (modeName) {
        'text' => FileViewMode.text,
        'hex' => FileViewMode.hex,
        'md' => FileViewMode.md,
        'archive' => FileViewMode.archive,
        _ => null,
      };

  Future<void> _handleFileOpen(String? path, String? modeName) async {
    if (path == null || path.isEmpty) return;
    try {
      final content = await _fs.readFile(path, mode: _viewModeFor(modeName));
      _post({'type': 'file.content', ...content.toJson()});
    } catch (e) {
      _post({'type': 'file.error', 'path': path, 'message': '$e'});
    }
  }

  /// 대용량 파일의 **줄 창**(뷰어 가상 스크롤). 요청한 `path/mode/from` 을 그대로 담아
  /// 보낸다 — 웹이 늦게 온 응답을 버릴 수 있게.
  Future<void> _handleFileWindow(String? path, String? modeName, int from, int count) async {
    if (path == null || path.isEmpty) return;
    final mode = _viewModeFor(modeName) ?? FileViewMode.text;
    try {
      final w = await _fs.readWindow(path, mode: mode, from: from, count: count);
      _post({
        'type': 'file.windowData',
        'path': path,
        'mode': mode.name,
        'from': w.from,
        'lines': w.lines,
        'lineCount': w.lineCount,
      });
    } catch (e) {
      _post({
        'type': 'file.windowData',
        'path': path,
        'mode': mode.name,
        'from': from,
        'lines': const <String>[],
        'lineCount': 0,
        'error': '$e',
      });
    }
  }

  /// 뷰어 편집기의 저장. 결과를 `file.saved{path,ok,message}` 로 알린다.
  ///
  /// **에이전트의 수정과 다른 경로다**(도구 계층을 안 지난다) — 그래서 가드를 여기 둔다:
  /// 프로젝트 밖 거부(심링크 풀어 비교, 형제 prefix 차단) · 없는 파일은 만들지 않는다.
  @visibleForTesting
  Future<void> handleFileSave(String? path, String? content) async {
    if (path == null || path.isEmpty || content == null) return;
    void fail(String message) =>
        _post({'type': 'file.saved', 'path': path, 'ok': false, 'message': message});
    try {
      final target = File(path).absolute;
      if (!await target.exists()) {
        fail('File does not exist: $path');
        return;
      }
      final realTarget = await target.resolveSymbolicLinks();
      final realRoot = await Directory(_files.root).resolveSymbolicLinks();
      if (!p.isWithin(realRoot, realTarget)) {
        fail('Outside the project: $path');
        return;
      }
      await _fs.writeFile(realTarget, content);
      _post({'type': 'file.saved', 'path': path, 'ok': true});
    } catch (e) {
      fail('$e');
    }
  }

  /// 압축 파일 안의 항목 하나(압축 뷰어의 미리보기). 실패도 결과에 담는다.
  Future<void> _handleArchiveEntry(String? path, String? name) async {
    if (path == null || name == null || path.isEmpty || name.isEmpty) return;
    final data = await _fs.archives.readEntry(path, name);
    _post({'type': 'archive.entryData', 'path': path, ...data.toJson()});
  }

  /// 뷰어 플러그인이 자기 폴더의 파일(주로 `.wasm`)을 요청한 것. 웹은 `file://` 에서
  /// fetch 를 못 쓴다 — 네이티브가 읽어 base64 로 준다. **스테이징 폴더 밖은 거부.**
  Future<void> _handleViewerAsset(String? from, String? name) async {
    if (from == null || name == null || from.isEmpty || name.isEmpty) return;
    void fail(String message) =>
        _post({'type': 'viewer.assetData', 'from': from, 'name': name, 'error': message});
    try {
      final uri = Uri.parse(from);
      if (uri.scheme != 'file') {
        fail('Not a local viewer.');
        return;
      }
      final target = File(p.normalize(p.join(p.dirname(uri.toFilePath()), name)));
      final root = p.join((await WebAssets.webRoot()).path, 'viewers');
      if (!p.isWithin(root, target.path)) {
        fail('Outside the viewer folder.');
        return;
      }
      if (!await target.exists()) {
        fail('No such file: $name');
        return;
      }
      final length = await target.length();
      if (length > _maxViewerAssetBytes) {
        fail('Asset is too large (${length >> 20}MB > ${_maxViewerAssetBytes >> 20}MB).');
        return;
      }
      _post({
        'type': 'viewer.assetData',
        'from': from,
        'name': name,
        'b64': base64.encode(await target.readAsBytes()),
      });
    } catch (e) {
      fail('$e');
    }
  }

  static const int _maxViewerAssetBytes = 32 << 20;

  // ------------------------------------------------------------------

  void _post(Map<String, Object?> msg) {
    if (_disposed) return;
    _view?.postMessage(jsonEncode(msg));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _workspace.removeListener(_onWorkspaceChanged);
    _view = null;
    unawaited(_msgSub?.cancel());
    unawaited(_changeSub.cancel());
    unawaited(_eventSub.cancel());
    super.dispose();
  }
}
