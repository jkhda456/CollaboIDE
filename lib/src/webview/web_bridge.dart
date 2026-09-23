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
import '../files/project_files.dart';
import '../fs/file_service.dart';
import '../llm/llm_provider.dart';
import '../platform/mac_file_picker.dart';
import '../tools/tool_call_log.dart';
import 'platform_web_view.dart';

/// `stripTurnSummary` 는 `agent/turn_summary.dart` 로 옮겼지만, 기존 import 경로
/// (`webview/web_bridge.dart`)를 그대로 쓸 수 있게 여기서 다시 내보낸다.
export '../agent/turn_summary.dart' show stripTurnSummary;

/// Flutter(네이티브) ↔ **대화** WebView(`index.html`) 메시지 브리지.
///
/// 웹은 파일시스템에 직접 접근하지 않는다. 트리와 파일 뷰어는 이제 네이티브다
/// ([ProjectFiles] · `FileViewerController` + 뷰어 전용 웹뷰 `viewer.html`) — 이 브리지는
/// 대화만 맡는다. 대화 페이지가 파일을 열어 달라고 하면(`file.open` — 계획 파일 등)
/// 세션을 통해 네이티브 뷰어로 넘긴다.
///
/// ★ **에이전트 루프는 여기 없다.** 루프는 [AgentLoop] 의 것이고([loop]), 브리지는
/// 그 이벤트를 **구독해 웹으로 실어 나르기만** 한다. 여기 남은 것은 **대화 화면과
/// OS 자원 사이의 창구**뿐이다: 첨부 선택·클립보드·외부 열기.
class WebBridge {
  WebBridge(
    this._workspace,
    this._session, {
    FileService? fileService,
    LlmProvider? llmClient,
    this.onOpenSettings,
    this.onOpenActivity,
    this.onStopChoice,
    this.onOpenCheckpoint,
  }) : _fs = fileService ?? FileService() {
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

  /// 웹의 중지 버튼 → **네이티브 선택 창**(여기까지 남길지, 전부 취소할지).
  /// 이번 요청에서 이미 뭔가 나왔을 때만 온다(아무것도 없으면 웹이 바로 `chat.stop`).
  final void Function()? onStopChoice;

  /// 웹의 "대화 시작점" 버튼 → 네이티브 시작점 창.
  final void Function()? onOpenCheckpoint;

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

  StreamSubscription<dynamic>? _msgSub;
  StreamSubscription<FsChange>? _fsSub;

  /// 이 브리지가 맡은 프로젝트 루트. 세션의 것이라 **바뀌지 않는다.**
  ///
  /// 널 가능 타입을 유지하는 것은 "프로젝트가 없을 수 있다" 를 전제로 쓰인 기존
  /// 가드들(`if (root == null || root.isEmpty)`)을 그대로 두기 위해서다.
  String? get _projectPath => _session.path;

  /// 세션이 만들어질 때 1회. **웹뷰와 무관한** 준비만 한다.
  Future<void> start() async {
    // ⚠️ **구독은 지문을 다 잡은 뒤에 건다** — 헤더 메타의 지문은 루프가 들고 있으므로
    // ([AgentLoop.start]) 그것까지 끝난 다음이 안전한 자리다(첫 알림에 쓸데없이 재전송하지 않게).
    await loop.start();
    _workspace.addListener(_onWorkspaceChanged);
    // 파일이 바뀌면 프로젝트 폴더 mtime 이 변한다 — 헤더의 "마지막 변경" 을 갱신.
    _fsSub = _session.files.changes.listen((_) => unawaited(loop.pushChatMeta()));
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
    // 대화 제목(폴더명)에만 쓴다 — 트리는 네이티브다.
    _post({'type': 'project.changed', 'path': _session.path});
    await loop.pushAll();
  }

  /// 지금 이 프로젝트에서 생성이 돌고 있는지. 좌측 메뉴 표시와 닫기 확인이 본다.
  bool get isGenerating => loop.isGenerating;

  /// 바깥(프로젝트 닫기)에서 생성을 끊는다. 사용자의 중지 버튼과 같은 경로다.
  void stopGeneration() => loop.stop();

  /// 컨트롤러 알림 — 헤더 메타는 루프가 지문으로 걸러 보낸다.
  /// (뷰어 설정·사용자 뷰어는 `FileViewerController` 가 따로 듣는다.)
  void _onWorkspaceChanged() => loop.onWorkspaceChanged();

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
        // 페이지가 (다시) 로드되면 웹에는 아무것도 없다 — 프로젝트·기록·계획을 통째로
        // 다시 보낸다. 계획은 사용자가 에디터에서 고쳤을 수 있어 파일에서 다시 읽는다.
        unawaited(loop.reloadPlaybook().then((_) => pushAll()));
        break;
      case 'file.open':
        // 대화 쪽에서 파일을 보여 달라고 했다(계획 파일 등) → 네이티브 뷰어로.
        final path = msg['path'] as String?;
        if (path != null && path.isNotEmpty) _session.openInViewer(path);
        break;
      case 'file.openExternal':
        final path = msg['path'] as String?;
        if (path != null && path.isNotEmpty) unawaited(_session.files.openExternal(path));
        break;
      case 'layout.toggleRight':
        _session.toggleSidePanel();
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
        // keep: 지금까지 한 것을 남기고 멈춘다(기본은 이번 요청의 기록을 되돌린다).
        loop.stop(keep: msg['keep'] == true);
        break;
      case 'chat.stop.ask':
        // 이미 진행된 것이 있다 — 어떻게 할지 네이티브 창이 묻고, 그 창이 loop.stop 을 부른다.
        onStopChoice?.call();
        break;
      case 'chat.checkpoint.open':
        onOpenCheckpoint?.call();
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
      case 'chat.plan.reset':
        loop.planReset();
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
        // 알림 본문은 `text` 다(예전에 `message` 로 보내 빈 줄만 보였다).
        _post({
          'type': 'chat.notice',
          'text': 'Image too large (max 12MB).',
          'key': 'noticeImageTooLarge',
        });
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
      _post({
        'type': 'chat.notice',
        'text': 'Failed to read image: $e',
        'key': 'noticeImageReadFailed',
        'args': {'error': '$e'},
      });
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

  /// 웹에서 클릭한 링크를 외부 브라우저로 연다(웹뷰는 내부 navigation 을 막음).
  Future<void> _handleOpenExternal(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
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
    await _fsSub?.cancel();
  }
}
