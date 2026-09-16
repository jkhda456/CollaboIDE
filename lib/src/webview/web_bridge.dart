import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../agent/agent_loop.dart';
import '../app/project_session.dart';
import '../app/workspace_controller.dart';
import '../fs/entry_name.dart';
import '../fs/file_service.dart';
import '../llm/llm_provider.dart';
import '../platform/mac_file_picker.dart';
import '../tools/tool_call_log.dart';
import '../viewers/viewer_assets.dart';
import '../viewers/viewer_rule.dart';
import '../viewers/viewer_source.dart';
import 'platform_web_view.dart';
import 'web_assets.dart';

/// `stripTurnSummary` 는 `agent/turn_summary.dart` 로 옮겼지만, 기존 import 경로
/// (`webview/web_bridge.dart`)를 그대로 쓸 수 있게 여기서 다시 내보낸다.
export '../agent/turn_summary.dart' show stripTurnSummary;

/// Flutter(네이티브) ↔ WebView(웹) 메시지 브리지.
///
/// 웹은 파일시스템에 직접 접근하지 않는다. 트리/파일 내용은 네이티브가 읽어
/// 이 브리지로 전달하고, 파일 변경은 감시자(watch)가 실시간으로 밀어준다.
///
/// 프로토콜(JSON):
///  Web → Dart: `ready`, `dir.list{path}`, `file.open{path,mode?}`,
///              `clipboard.write{text}`
///  Dart → Web: `project.changed{path}`, `dir.children{path,entries}`,
///              `file.content{...}`, `fs.change{paths:[...]}`
///
/// JSON 메시지가 아닌 예외가 둘 있다(웹의 전역 함수를 직접 호출):
/// 테마 주입(`collaboSetTheme`)과 사용자 뷰어 반영(`collaboSyncUserViewers`).
///
/// ★ **에이전트 루프는 여기 없다.** 루프는 [AgentLoop] 의 것이고([loop]), 브리지는
/// 그 이벤트를 **구독해 웹으로 실어 나르기만** 한다. 예전에는 둘이 한 클래스
/// (3,400줄)에 있었다 — 수명은 세션 소유로 이미 갈렸지만(§1.5), 루프를 별도
/// 객체로 뽑아 브리지가 구경꾼이 되는 것이 그 정리의 마지막 절반이었다.
/// 여기 남은 것은 **화면과 OS 자원 사이의 창구**뿐이다: 트리·뷰어·파일 조작·
/// 첨부 선택·클립보드·외부 열기·실시간 감시.
class WebBridge {
  WebBridge(
    this._workspace,
    this._session, {
    FileService? fileService,
    LlmProvider? llmClient,
    Future<List<String>> Function(List<ViewerSource>)? viewerStager,
    this.onOpenSettings,
    this.onOpenActivity,
  })  : _fs = fileService ?? FileService(),
        _stageViewers = viewerStager ?? ViewerAssets.sync {
    loop = AgentLoop(_workspace, _session,
        fileService: _fs, llmClient: llmClient);
    // 루프가 내보내는 것은 전부 그대로 웹으로 간다 — 브리지는 판단하지 않는다.
    _loopSub = loop.events.listen(_post);
  }

  /// 이 브리지가 맡은 프로젝트. **한 세션에 브리지 하나**이고 바뀌지 않는다.
  ///
  /// 예전에는 브리지 하나가 `setProject()` 로 프로젝트를 갈아탔다. 그러면 갈아탄
  /// 순간 이전 프로젝트의 생성 루프·큐·도구 호출 기록이 갈 곳을 잃는다 —
  /// 프로젝트마다 브리지를 따로 두는 것이 그 문제의 답이다.
  final ProjectSession _session;

  /// 이 프로젝트의 에이전트 실행 루프. 브리지는 이걸 **소유하되 조종하지 않는다**
  /// (웹에서 온 대화 메시지를 넘겨주고, 나오는 이벤트를 웹으로 흘린다).
  late final AgentLoop loop;
  late final StreamSubscription<Map<String, Object?>> _loopSub;

  /// 웹의 설정 안내 버튼 → 네이티브 설정 창 열기. 인자는 열 섹션
  /// ('model'|'tools' 등, 빈 문자열이면 기본 탭). 웹뷰는 BuildContext 가 없어
  /// 다이얼로그를 직접 못 띄우므로 패널이 콜백으로 내려 준다.
  final void Function(String section)? onOpenSettings;

  /// 웹의 "호출 내역" 링크 → 네이티브 도구 호출 내역 창 열기.
  /// [id] 를 주면 그 호출을 선택한 상태로 연다(빈 문자열이면 최신).
  final void Function(String id)? onOpenActivity;

  /// 이번 세션의 도구 호출 기록(인자 + 결과 원문). 네이티브 창이 이걸 보여 준다.
  /// 실제 소유자는 루프다 — 화면(`app_layout.dart`)이 브리지를 통해 집는다.
  ToolCallLog get toolCalls => loop.toolCalls;

  /// 지금 이 브리지를 **보고 있는** 웹뷰. 붙어 있지 않을 수 있다.
  ///
  /// ★ 이 필드가 null 일 수 있다는 것이 이 클래스의 핵심 성질이다. 에이전트 루프는
  /// 세션의 것이고 화면은 구경꾼이다 — 사용자가 다른 프로젝트나 웹 검색으로 화면을
  /// 옮겨도, 웹뷰 런타임이 없어 패널이 안 떠도, 루프는 그대로 돈다. 그 동안 웹으로
  /// 나갈 메시지는 [_post] 에서 조용히 버려지고, 화면이 다시 붙을 때
  /// [attachView] 가 현재 상태를 통째로 다시 밀어 넣는다(기록은 DB 가 정본이다).
  PlatformWebView? _view;

  final WorkspaceController _workspace;
  final FileService _fs;

  /// 사용자 뷰어 JS 를 웹 루트로 복사하고 상대 URL 목록을 돌려주는 함수.
  /// 기본은 [ViewerAssets.sync](path_provider 필요) — 테스트에서 갈아끼운다.
  final Future<List<String>> Function(List<ViewerSource>) _stageViewers;

  StreamSubscription<dynamic>? _msgSub;
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _flushTimer;
  final Set<String> _pendingDirs = {};
  final Set<String> _pendingFiles = {};

  /// 이 브리지가 맡은 프로젝트 루트. 세션의 것이라 **바뀌지 않는다.**
  ///
  /// 널 가능 타입을 유지하는 것은 "프로젝트가 없을 수 있다" 를 전제로 쓰인 기존
  /// 가드들(`if (root == null || root.isEmpty)`)을 그대로 두기 위해서다.
  String? get _projectPath => _session.path;

  /// 세션이 만들어질 때 1회. **웹뷰와 무관한** 준비만 한다.
  ///
  /// 파일 감시와 계획 메모리는 화면이 붙기 전에도 필요하다 — 에이전트가 먼저
  /// 일을 시작할 수 있기 때문이다.
  Future<void> start() async {
    // ⚠️ **구독은 지문을 다 잡은 뒤에 건다.** 설정 창에서 프리셋을 바꾸면
    // (추가/이름 변경/모델 변경/삭제/기본 지정) 대화 헤더가 바로 따라오도록
    // 컨트롤러 변경을 구독하는데, 구독 시점의 상태를 지문으로 먼저 잡아 두어야
    // 첫 알림에서 불필요한 재전송이 나가지 않는다. 헤더 메타의 지문은 루프가
    // 들고 있으므로([AgentLoop.start]) 그것까지 끝난 다음이 안전한 자리다.
    await loop.start();
    _viewerSignature = _viewerSourcesSignature();
    _viewerRuleSignature = _viewerRulesSignature();
    _workspace.addListener(_onWorkspaceChanged);
    await _restartWatcher(_session.path);
  }

  /// 웹뷰를 붙이고 **현재 상태를 통째로 다시 밀어 넣는다.**
  ///
  /// 화면을 떠나 있는 동안 나간 메시지는 버려졌으므로, 증분이 아니라 전체를 보낸다.
  /// 대화 기록은 DB, 계획은 `PLAYBOOK.md` 가 정본이라 그대로 다시 읽으면 된다.
  Future<void> attachView(PlatformWebView view) async {
    if (identical(_view, view)) return;
    await _msgSub?.cancel();
    _view = view;
    _msgSub = view.messages.listen(_onMessage);
    await pushAll();
  }

  /// 붙어 있는 웹뷰를 뗀다. **루프는 계속 돈다.**
  Future<void> detachView() async {
    await _msgSub?.cancel();
    _msgSub = null;
    _view = null;
  }

  /// 지금 상태 전부를 웹으로 보낸다(붙을 때 · 웹이 `ready` 를 보낼 때).
  Future<void> pushAll() async {
    _post({'type': 'project.changed', 'path': _session.path});
    await loop.pushAll();
    await _pushViewerRules();
    await _syncUserViewers();
  }

  /// 지금 이 프로젝트에서 생성이 돌고 있는지. 좌측 메뉴 표시와 닫기 확인이 본다.
  bool get isGenerating => loop.isGenerating;

  /// 바깥(프로젝트 닫기)에서 생성을 끊는다. 사용자의 중지 버튼과 같은 경로다.
  void stopGeneration() => loop.stop();

  /// 사용자 뷰어 목록의 지문. 이 값이 달라질 때만 웹에 다시 얹는다.
  String _viewerSignature = '';

  /// 뷰어별 확장자/사용 여부 설정의 지문.
  String _viewerRuleSignature = '';

  /// 컨트롤러 알림을 받아, 실제로 달라진 것만 웹에 반영한다.
  ///
  /// [WorkspaceController] 의 알림은 백그라운드 프로세스 레지스트리에서도 포워드되어
  /// 자주 온다. 알림마다 [_syncUserViewers] 를 부르면 파일 복사가 반복되므로,
  /// 각각 지문이 바뀐 경우에만 보낸다(헤더 메타는 루프가 같은 방식으로 거른다).
  void _onWorkspaceChanged() {
    loop.onWorkspaceChanged();
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

  /// 설정에 등록된 사용자 뷰어의 지문(경로 목록).
  String _viewerSourcesSignature() =>
      jsonEncode([for (final v in _workspace.viewerSources) v.id]);

  /// 뷰어 설정(확장자·사용 여부 + 우선순위)의 지문.
  ///
  /// 뷰어 **목록 보고**(`viewers.list` → `setRegisteredViewers`)도 컨트롤러 알림을
  /// 일으키므로, 지문에 그 목록을 넣으면 보고 → 재전송 → 보고의 순환이 된다.
  /// **여기엔 사용자 설정만 넣는다.**
  String _viewerRulesSignature() => jsonEncode(_viewerRulesJson());

  Map<String, Object?> _viewerRulesJson() => {
        'rules': {
          for (final e in _workspace.viewerRules.entries) e.key: e.value.toJson(),
        },
        // 뷰어 우선순위(앞이 이긴다). 여기 없는 뷰어는 웹이 선언 priority 로 뒤에 붙인다.
        'order': _workspace.viewerOrder,
      };

  /// 뷰어 설정을 웹 레지스트리에 적용한다(확장자 override / 끄기 / 우선순위).
  Future<void> _pushViewerRules() async {
    try {
      await _view?.executeScript('window.collaboSetViewerRules && '
          'window.collaboSetViewerRules(${jsonEncode(_viewerRulesJson())})');
    } catch (_) {
      // 웹이 아직 준비 전 — `ready` 에서 다시 보낸다.
    }
  }

  /// 웹이 보고한 등록 뷰어 목록을 컨트롤러에 넣는다(설정 화면이 이걸로 줄을 그린다).
  void _handleViewersList(Object? raw) {
    if (raw is! List) return;
    _workspace.setRegisteredViewers([
      for (final e in raw)
        if (e is Map) ViewerInfo.fromJson(e.cast<String, Object?>()),
    ]);
  }

  /// 압축 파일 안의 항목 하나를 읽어 준다(압축 뷰어의 미리보기).
  ///
  /// 목록(`file.open{mode:'archive'}`)과 달리 뷰어를 바꾸지 않으므로 전용 메시지를
  /// 쓴다. 해독은 [ArchiveService] 가 아이솔레이트에서 하고, 실패도 결과에 담아 준다
  /// (뷰어가 그 자리에 이유를 보여 준다).
  Future<void> _handleArchiveEntry(String? path, String? name) async {
    if (path == null || name == null || path.isEmpty || name.isEmpty) return;
    final data = await _fs.archives.readEntry(path, name);
    _post({
      'type': 'archive.entryData',
      'path': path,
      ...data.toJson(),
    });
  }

  /// 뷰어 플러그인이 자기 폴더의 파일(주로 `.wasm`)을 읽어 달라고 요청한 것.
  ///
  /// **웹은 `file://` 에서 fetch/XHR 을 쓸 수 없다**(Chromium 차단, WKWebView 읽기
  /// 범위 제한). 그래서 `WebAssembly.instantiateStreaming(fetch(...))` 같은 흔한
  /// 방법이 통하지 않는다 → 네이티브가 바이트를 읽어 base64 로 넘겨주고, 웹이
  /// `WebAssembly.instantiate(bytes)` 로 쓴다.
  ///
  /// [from] 은 요청한 스크립트의 URL(`document.currentScript.src`)이다. 그 파일이
  /// 놓인 폴더를 기준으로 [name] 을 찾으므로, 플러그인은 자기 폴더 안만 볼 수 있다
  /// — 실제로 **스테이징 폴더(`<web>/viewers/`) 밖이면 거부**한다.
  Future<void> _handleViewerAsset(String? from, String? name) async {
    if (from == null || name == null || from.isEmpty || name.isEmpty) return;
    void fail(String message) => _post({
          'type': 'viewer.assetData',
          'from': from,
          'name': name,
          'error': message,
        });
    try {
      final uri = Uri.parse(from);
      if (uri.scheme != 'file') {
        fail('Not a local viewer.');
        return;
      }
      // 로드 시 캐시 무효화용 ?v=… 가 붙어 있어도 경로만 쓴다.
      final scriptPath = uri.toFilePath();
      final target = File(p.normalize(p.join(p.dirname(scriptPath), name)));
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
        fail('Asset is too large (${length >> 20}MB > '
            '${_maxViewerAssetBytes >> 20}MB).');
        return;
      }
      final bytes = await target.readAsBytes();
      _post({
        'type': 'viewer.assetData',
        'from': from,
        'name': name,
        'b64': base64.encode(bytes),
      });
    } catch (e) {
      fail('$e');
    }
  }

  /// 뷰어 에셋(wasm 등) 1건의 상한. base64 로 부풀려 브리지를 타므로 넉넉하지만
  /// 무한하지는 않게 둔다.
  static const int _maxViewerAssetBytes = 32 << 20;

  /// 사용자 뷰어(JS)를 웹뷰에 반영한다.
  ///
  /// 파일을 웹 루트로 복사한 뒤, **현재 목록 전체**를 웹에 넘긴다. 무엇을 새로
  /// 얹고 무엇을 내릴지는 웹이 판단한다(`collaboSyncUserViewers`) — 어떤 스크립트가
  /// 이미 로드돼 있는지는 웹만 알기 때문이다.
  Future<void> _syncUserViewers() async {
    List<String> urls;
    try {
      urls = await _stageViewers(_workspace.viewerSources);
    } catch (_) {
      return; // 스테이징 실패(권한 등) — 기본 뷰어로 계속 동작한다.
    }
    try {
      await _view?.executeScript('window.collaboSyncUserViewers && '
          'window.collaboSyncUserViewers(${jsonEncode(urls)})');
    } catch (_) {
      // 웹이 아직 준비 전이거나 이미 내려갔다 — `ready` 에서 다시 얹힌다.
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
        // 페이지가 (다시) 로드되면 웹에는 아무것도 없다 — 프로젝트·기록·계획·뷰어를
        // 통째로 다시 보낸다. 화면을 새로 붙일 때와 같은 일이라 같은 함수를 쓴다.
        // 계획은 사용자가 에디터에서 고쳤을 수 있어 파일에서 다시 읽는다.
        unawaited(loop.reloadPlaybook().then((_) => pushAll()));
        break;
      case 'viewers.list':
        _handleViewersList(msg['viewers']);
        break;
      case 'viewer.asset':
        _handleViewerAsset(msg['from'] as String?, msg['name'] as String?);
        break;
      case 'archive.entry':
        _handleArchiveEntry(msg['path'] as String?, msg['name'] as String?);
        break;
      case 'dir.list':
        _handleDirList(msg['path'] as String?);
        break;
      case 'file.open':
        _handleFileOpen(msg['path'] as String?, msg['mode'] as String?);
        break;
      case 'file.window':
        _handleFileWindow(
          msg['path'] as String?,
          msg['mode'] as String?,
          (msg['from'] as num?)?.toInt() ?? 0,
          (msg['count'] as num?)?.toInt() ?? 0,
        );
        break;
      case 'file.save':
        _handleFileSave(msg['path'] as String?, msg['content'] as String?);
        break;
      case 'file.search':
        _handleFileSearch(msg['query'] as String?);
        break;
      case 'file.openExternal':
        _handleOpenFileExternal(msg['path'] as String?);
        break;
      case 'fs.move':
        _handleFsMove(msg['src'] as String?, msg['dst'] as String?, move: true);
        break;
      case 'fs.copy':
        _handleFsMove(msg['src'] as String?, msg['dst'] as String?, move: false);
        break;
      case 'fs.create':
        _handleFsCreate(
          msg['parent'] as String?,
          msg['name'] as String?,
          msg['dir'] == true,
        );
        break;
      case 'fs.rename':
        _handleFsRename(msg['path'] as String?, msg['name'] as String?);
        break;
      case 'fs.delete':
        _handleFsDelete(msg['path'] as String?);
        break;
      case 'clipboard.write':
        final text = msg['text'] as String?;
        if (text != null) Clipboard.setData(ClipboardData(text: text));
        break;
      case 'open.external':
        _handleOpenExternal(msg['url'] as String?);
        break;
      case 'attach.pick':
        _handleAttachPick();
        break;
      case 'image.pick':
        _handleImagePick();
        break;
      // --- 아래는 전부 루프의 일이다. 브리지는 넘겨만 준다. ---
      case 'chat.send':
        loop.send(msg['text'] as String?, msg['attachments']);
        break;
      case 'chat.stop':
        loop.stop();
        break;
      case 'chat.queue.cancel':
        loop.cancelQueued((msg['id'] as num?)?.toInt());
        break;
      case 'chat.checkpoint.preview':
        loop.checkpointPreview((msg['size'] as num?)?.toInt() ?? 2000);
        break;
      case 'chat.checkpoint.create':
        loop.checkpointCreate(msg['compress'] == true, msg['content'] as String?);
        break;
      case 'chat.checkpoint.revert':
        loop.checkpointRevert((msg['id'] as num?)?.toInt());
        break;
      case 'chat.checkpoint.edit':
        loop.checkpointEdit(
            (msg['id'] as num?)?.toInt(), msg['content'] as String?);
        break;
      case 'chat.retry':
        loop.retry();
        break;
      case 'chat.truncateFrom':
        loop.truncateFrom(msg['messageId'] as int?);
        break;
      case 'chat.delete':
        loop.deleteMessage((msg['messageId'] as num?)?.toInt());
        break;
      case 'chat.edit':
        loop.editMessage(msg['messageId'] as int?, msg['text'] as String?);
        break;
      case 'chat.setModel':
        loop.setModel(msg['presetId'] as String?);
        break;
      case 'chat.summary.skip':
        loop.skipSummary();
        break;
      case 'settings.open':
        onOpenSettings?.call((msg['section'] as String?) ?? '');
        break;
      case 'activity.open':
        // 결과 원문은 네이티브가 들고 있다 — 웹은 열어 달라고만 한다.
        onOpenActivity?.call((msg['id'] as String?) ?? '');
        break;
    }
  }

  // ======================================================= 첨부 선택(네이티브)

  /// 첨부 사본 저장 상한(일반 파일). 이미지는 [_maxImageBytes] 가 따로 있다.
  static const int _maxAttachBytes = 64 * 1024 * 1024; // 64MB

  /// 첨부 파일 사본을 프로젝트의 `.collabo/attach/` 에 저장하고 절대 경로를
  /// 돌려준다. 워크스페이스 안이라 도구(read_file 등)가 읽을 수 있고, 서브
  /// 컨텍스트에 경로로 동반된다. 프로젝트가 없거나 실패하면 null(첨부 자체는
  /// 동작하되 보존/도구 접근만 생략).
  Future<String?> _persistAttachment(List<int> bytes, String name) async {
    final root = _projectPath;
    if (root == null || root.isEmpty) return null;
    try {
      final dir = Directory(p.join(root, '.collabo', 'attach'));
      await dir.create(recursive: true);
      // 이름 충돌 방지: 타임스탬프 접두 + 파일명 정리(경로 문자 제거).
      final safe = p.basename(name).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final path = p.join(dir.path, '${stamp}_$safe');
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// + 첨부: 파일 선택 → 텍스트면 내용을, 아니면 경로를 입력창에 삽입.
  /// macOS 는 file_selector 패널이 뜨지 않는 문제가 있어, 설정에서 이미 쓰는
  /// 자체 네이티브 패널(collabo/macos_files)로 통일한다.
  Future<void> _handleAttachPick() async {
    final path = MacFilePicker.supported
        ? await MacFilePicker.pickFile()
        : (await openFile())?.path;
    if (path == null) return;
    if (_fs.defaultModeFor(path) == FileViewMode.hex) {
      // 비텍스트(바이너리): `.collabo/attach` 로 복사해 그 경로를 삽입한다 —
      // 워크스페이스 안이라 도구가 읽을 수 있다(원본이 밖에 있어도 접근 가능).
      // 복사 불가(프로젝트 없음/대용량)면 원래 경로를 그대로 삽입.
      var insert = path;
      try {
        final f = File(path);
        if (await f.length() <= _maxAttachBytes) {
          insert = await _persistAttachment(await f.readAsBytes(), path) ?? path;
        }
      } catch (_) {}
      _post({'type': 'composer.insert', 'text': insert});
      return;
    }
    try {
      final content = await _fs.readFile(path, mode: FileViewMode.text);
      _post({'type': 'composer.insert', 'text': content.content});
    } catch (_) {
      _post({'type': 'composer.insert', 'text': path});
    }
  }

  /// 멀티모달용 이미지 선택: 이미지를 골라 base64 data URL 로 웹에 전달한다.
  /// (웹은 OS 파일시스템에 직접 접근하지 못하므로 네이티브가 읽어 넘긴다.)
  static const int _maxImageBytes = 12 * 1024 * 1024; // 12MB 가드

  Future<void> _handleImagePick() async {
    const exts = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];
    String? path;
    if (MacFilePicker.supported) {
      // macOS: 자체 네이티브 패널(위 _handleAttachPick 참고) + 확장자 필터.
      path = await MacFilePicker.pickFile(extensions: exts);
    } else {
      const group = XTypeGroup(
        label: 'Image',
        extensions: exts,
        mimeTypes: ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
      );
      path = (await openFile(acceptedTypeGroups: [group]))?.path;
    }
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length > _maxImageBytes) {
        _post({'type': 'chat.notice', 'message': 'Image too large (max 12MB).'});
        return;
      }
      final mime = _imageMimeFor(path);
      // `.collabo/attach` 에 사본 저장 → 서브 컨텍스트 동반/도구 접근용 경로.
      final saved = await _persistAttachment(bytes, path);
      final url = 'data:$mime;base64,${base64Encode(bytes)}';
      _post({
        'type': 'composer.attachImage',
        'url': url,
        'name': p.basename(path),
        'kind': 'image',
        'mime': mime,
        if (saved != null) 'path': saved,
      });
    } catch (e) {
      _post({'type': 'chat.notice', 'message': 'Failed to read image: $e'});
    }
  }

  String _imageMimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }

  // ======================================================= 트리 · 뷰어 · 파일

  /// 뷰어의 현재 파일을 OS 기본(연결) 프로그램으로 연다.
  Future<void> _handleOpenFileExternal(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      if (Platform.isWindows) {
        // start 는 cmd 내장 명령. 빈 "" 는 창 제목 인자(경로가 제목으로 먹히지 않게).
        await Process.start('cmd', ['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else {
        await Process.start('xdg-open', [path]);
      }
    } catch (e) {
      _post({'type': 'fs.error', 'message': 'Failed to open: $e'});
    }
  }

  /// 웹에서 클릭한 링크를 외부 브라우저로 연다(웹뷰는 내부 navigation 을 막음).
  Future<void> _handleOpenExternal(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _handleDirList(String? path) async {
    if (path == null || path.isEmpty) return;
    final entries = await _fs.listDirectory(path);
    _post({
      'type': 'dir.children',
      'path': path,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
  }

  /// 파일명 검색(프로젝트 전체) → 결과 목록 전송.
  Future<void> _handleFileSearch(String? query) async {
    final root = _projectPath;
    if (root == null || query == null || query.trim().isEmpty) {
      _post({'type': 'search.results', 'query': query ?? '', 'files': []});
      return;
    }
    final entries = await _fs.findByName(root, query);
    _post({
      'type': 'search.results',
      'query': query,
      'files': entries.map((e) => {'name': e.name, 'path': e.path}).toList(),
    });
  }

  // --- 트리에서의 파일 조작 (드래그 이동/복사, 우클릭 새로 만들기/이름 변경/삭제) ---

  /// 앱이 관리하는 폴더. 트리에서 직접 옮기거나 지우지 못하게 한다 —
  /// 대화 DB·venv·백그라운드 명령 레지스트리가 **열려 있는 채로** 사라질 수 있다.
  static const String _appDirName = '.collabo';

  void _fsError(String message) =>
      _post({'type': 'fs.error', 'message': message});

  /// 사용자가 트리에서 지시한 경로를 검증한다(이동/복사/생성/이름 변경/삭제 공용).
  ///
  /// 통과하면 **심링크를 푼 실제 경로**, 아니면 null — 이유는 `fs.error` 로 이미 보냈다.
  /// 뷰어 저장(`_handleFileSave`)과 같은 취지의 fail-safe 가드이고, 여기에
  /// `.collabo` 차단이 더 붙는다. [allowRoot] 는 프로젝트 루트 자신을 허용할지 —
  /// 새로 만들 때의 **부모**로는 되지만, 이름 변경·삭제·이동의 **대상**으로는 안 된다.
  Future<String?> _resolveUserPath(String? path, {bool allowRoot = false}) async {
    if (path == null || path.isEmpty) return null;
    final root = _projectPath;
    if (root == null || root.isEmpty) {
      _fsError('No project is open.');
      return null;
    }
    final String real;
    final String realRoot;
    try {
      realRoot = await Directory(root).resolveSymbolicLinks();
      real = await File(path).absolute.resolveSymbolicLinks();
    } catch (e) {
      // 존재하지 않는 경로도 여기로 온다(resolveSymbolicLinks 가 던진다).
      _fsError('$e');
      return null;
    }
    if (p.equals(real, realRoot)) {
      if (allowRoot) return real;
      _fsError('The project root cannot be changed here.');
      return null;
    }
    // isWithin 은 형제 prefix 탈출(`/proj-evil` vs `/proj`)을 걸러 준다.
    if (!p.isWithin(realRoot, real)) {
      _fsError('Outside the project: $path');
      return null;
    }
    if (p.split(p.relative(real, from: realRoot)).first == _appDirName) {
      _fsError('$_appDirName is managed by the app.');
      return null;
    }
    return real;
  }

  /// 새 이름을 검사해 다듬은 값을 준다. 부적합하면 null(오류는 이미 보냈다).
  ///
  /// 규칙은 새 프로젝트 다이얼로그와 공유한다(`fs/entry_name.dart`) — 웹에도 같은
  /// 규칙이 한 벌 있지만(모달에서 즉시 번역 메시지를 띄우려고), 판정은 여기가 최종이다.
  String? _checkEntryName(String? raw) {
    final name = (raw ?? '').trim();
    if (validateProjectName(name) != null) {
      _fsError('Invalid name: ${raw ?? ''}');
      return null;
    }
    return name;
  }

  /// 트리에서 드래그한 항목을 폴더로 이동/복사한다(사용자 동작).
  Future<void> _handleFsMove(String? src, String? dst, {required bool move}) async {
    final source = await _resolveUserPath(src);
    if (source == null) return;
    // dst 는 대상 폴더. 실제 목적지 = 폴더/원본이름.
    final destDir = await _resolveUserPath(dst, allowRoot: true);
    if (destDir == null) return;
    final target = p.join(destDir, p.basename(source));
    // 자기 자신/내부로의 이동 방지.
    if (p.equals(source, target)) return;
    if (p.isWithin(source, destDir) || p.equals(source, destDir)) {
      _fsError('Cannot move a folder into itself.');
      return;
    }
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _fsError('Target already exists: $target');
      return;
    }
    try {
      if (move) {
        await _fs.movePath(source, target);
      } else {
        await _fs.copyPath(source, target);
      }
      // 감시자가 양쪽 디렉토리를 갱신하지만, 즉시 반영 위해 명시적으로도 통지.
      _post({
        'type': 'fs.change',
        'paths': [p.dirname(source), destDir],
      });
    } catch (e) {
      _fsError('$e');
    }
  }

  /// 우클릭 → 새 파일 / 새 폴더. [parent] 는 만들 곳(폴더), [name] 은 이름 하나.
  Future<void> _handleFsCreate(String? parent, String? name, bool isDir) async {
    final dir = await _resolveUserPath(parent, allowRoot: true);
    if (dir == null) return;
    if (FileSystemEntity.typeSync(dir) != FileSystemEntityType.directory) {
      _fsError('Not a folder: $parent');
      return;
    }
    final clean = _checkEntryName(name);
    if (clean == null) return;
    final target = p.join(dir, clean);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _fsError('Target already exists: $target');
      return;
    }
    try {
      if (isDir) {
        await Directory(target).create();
      } else {
        // 빈 파일. 뷰어가 바로 열어 편집할 수 있다.
        await File(target).create();
      }
      _post({'type': 'fs.change', 'paths': [dir]});
      // 웹이 만든 항목을 펼쳐서 선택하도록(파일이면 뷰어로 연다).
      _post({'type': 'fs.created', 'path': target, 'isDir': isDir});
    } catch (e) {
      _fsError('$e');
    }
  }

  /// 우클릭 → 이름 변경. 같은 폴더 안에서만 바꾼다(경로 이동은 드래그로).
  Future<void> _handleFsRename(String? path, String? name) async {
    final src = await _resolveUserPath(path);
    if (src == null) return;
    final clean = _checkEntryName(name);
    if (clean == null) return;
    final target = p.join(p.dirname(src), clean);
    if (p.equals(src, target)) return; // 이름이 그대로면 조용히 넘어간다.
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _fsError('Target already exists: $target');
      return;
    }
    try {
      await _fs.movePath(src, target);
      _post({
        'type': 'fs.change',
        'paths': [p.dirname(src)],
        'files': [src, target],
      });
      _post({'type': 'fs.renamed', 'path': src, 'to': target});
    } catch (e) {
      _fsError('$e');
    }
  }

  /// 우클릭 → 삭제. **되돌릴 수 없다**(휴지통을 거치지 않는다) — 확인은 웹 모달이 받는다.
  Future<void> _handleFsDelete(String? path) async {
    final target = await _resolveUserPath(path);
    if (target == null) return;
    try {
      if (FileSystemEntity.typeSync(target) == FileSystemEntityType.directory) {
        await Directory(target).delete(recursive: true);
      } else {
        await File(target).delete();
      }
      _post({
        'type': 'fs.change',
        'paths': [p.dirname(target)],
        'files': [target],
      });
      // 보고 있던 파일이 사라졌으면 웹이 뷰어를 닫는다.
      _post({'type': 'fs.deleted', 'path': target});
    } catch (e) {
      _fsError('$e');
    }
  }

  /// 뷰어 편집기의 저장. 결과를 `file.saved{path,ok,message}` 로 알린다.
  ///
  /// **프로젝트 밖은 거부한다**(fail-safe). 뷰어는 트리에서 고른 파일만 열지만,
  /// 쓰기는 되돌릴 수 없으니 경로를 여기서 한 번 더 확인한다 — Python 도구 계층의
  /// `_resolve()` 가드와 같은 취지다(심링크는 realpath 로 풀어 비교).
  Future<void> _handleFileSave(String? path, String? content) async {
    if (path == null || path.isEmpty || content == null) return;
    final root = _projectPath;
    void fail(String message) => _post(
        {'type': 'file.saved', 'path': path, 'ok': false, 'message': message});
    if (root == null || root.isEmpty) {
      fail('No project is open.');
      return;
    }
    try {
      final target = File(path).absolute;
      // 존재하는 파일만 저장한다(뷰어는 열려 있는 파일을 저장하는 것이다).
      if (!await target.exists()) {
        fail('File does not exist: $path');
        return;
      }
      final realTarget = await target.resolveSymbolicLinks();
      final realRoot = await Directory(root).resolveSymbolicLinks();
      // isWithin 은 형제 prefix 탈출(`/proj-evil` vs `/proj`)을 걸러 주고,
      // Windows 에서는 대소문자를 무시한다(package:path 가 플랫폼 컨텍스트를 쓴다).
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

  /// 대용량 파일의 **줄 창**을 읽어 준다(뷰어 가상 스크롤).
  ///
  /// 파일을 한 번에 다 보내지 않고 화면에 필요한 줄만 오간다. 응답은 요청한
  /// `path/mode/from` 을 그대로 담아 보낸다 — 웹이 늦게 온 응답을 버릴 수 있게.
  Future<void> _handleFileWindow(
      String? path, String? modeName, int from, int count) async {
    if (path == null || path.isEmpty) return;
    final mode = _viewModeFor(modeName) ?? FileViewMode.text;
    try {
      final window =
          await _fs.readWindow(path, mode: mode, from: from, count: count);
      _post({
        'type': 'file.windowData',
        'path': path,
        'mode': mode.name,
        'from': window.from,
        'lines': window.lines,
        'lineCount': window.lineCount,
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

  FileViewMode? _viewModeFor(String? modeName) => switch (modeName) {
        'text' => FileViewMode.text,
        'hex' => FileViewMode.hex,
        'md' => FileViewMode.md,
        'archive' => FileViewMode.archive,
        _ => null,
      };

  Future<void> _handleFileOpen(String? path, String? modeName) async {
    if (path == null || path.isEmpty) return;
    final mode = _viewModeFor(modeName);
    try {
      final content = await _fs.readFile(path, mode: mode);
      _post({'type': 'file.content', ...content.toJson()});
    } catch (e) {
      _post({'type': 'file.error', 'path': path, 'message': '$e'});
    }
  }

  // --- 실시간 감시 ---

  Future<void> _restartWatcher(String? path) async {
    await _watchSub?.cancel();
    _watchSub = null;
    _flushTimer?.cancel();
    _pendingDirs.clear();
    if (path == null) return;
    try {
      _watchSub = _fs.watch(path).listen(_onFsEvent, onError: (_) {});
    } catch (_) {
      // 감시 불가(권한/플랫폼) — 무시. 수동 새로고침으로 대체 가능.
    }
  }

  /// 변경 이벤트는 영향받은 **부모 디렉토리**(트리 갱신용)와 **변경된 경로**
  /// (뷰어 자동 갱신용)를 모아 디바운스 후 통지한다.
  /// (웹은 보고 있는 디렉토리만 갱신 → 트리가 접히지 않는다.)
  void _onFsEvent(FileSystemEvent event) {
    _pendingDirs.add(p.dirname(event.path));
    _pendingFiles.add(event.path);
    if (event is FileSystemMoveEvent && event.destination != null) {
      _pendingDirs.add(p.dirname(event.destination!));
      _pendingFiles.add(event.destination!);
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 200), _flushChanges);
  }

  void _flushChanges() {
    final dirs = _pendingDirs.toList();
    final files = _pendingFiles.toList();
    _pendingDirs.clear();
    _pendingFiles.clear();
    _flushTimer = null;
    if (dirs.isNotEmpty || files.isNotEmpty) {
      _post({'type': 'fs.change', 'paths': dirs, 'files': files});
      // 파일 변경 → 프로젝트 폴더 mtime 변동. 헤더의 "마지막 변경" 을 갱신.
      unawaited(loop.pushChatMeta());
    }
  }

  /// 웹으로 메시지 하나를 보낸다.
  ///
  /// **화면이 안 붙어 있으면 조용히 버린다.** 쌓아 두지 않는 이유: 생성이 길게
  /// 돌면 델타만 수만 건이 되고, 그걸 나중에 몰아서 재생해 봐야 의미가 없다.
  /// 다시 붙을 때는 [pushAll] 이 DB 와 파일에서 **현재 상태**를 새로 만든다.
  void _post(Map<String, Object?> msg) {
    _view?.postMessage(jsonEncode(msg));
  }

  Future<void> dispose() async {
    _workspace.removeListener(_onWorkspaceChanged);
    // 먼저 화면을 끊는다 — 정리 도중 늦게 도착한 결과가 이미 버려진 웹뷰로
    // 나가지 않게 한다(`_post` 는 null 이면 조용히 버린다).
    _view = null;
    await _loopSub.cancel();
    await loop.dispose();
    await _msgSub?.cancel();
    await _watchSub?.cancel();
    _flushTimer?.cancel();
  }
}
