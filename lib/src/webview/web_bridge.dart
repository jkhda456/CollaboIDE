import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../agent/playbook.dart';
import '../agent/supervisor.dart';
import '../app/workspace_controller.dart';
import '../conversation/conversation_store.dart';
import '../conversation/models.dart';
import '../fs/entry_name.dart';
import '../fs/file_service.dart';
import '../llm/llm_config.dart';
import '../llm/message_shape.dart';
import '../llm/openai_client.dart';
import '../llm/stream_budget.dart';
import '../llm/system_prompt.dart';
import '../platform/mac_file_picker.dart';
import '../tools/tool_call_log.dart';
import '../tools/tool_module.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_runner.dart';
import '../viewers/viewer_assets.dart';
import '../viewers/viewer_rule.dart';
import '../viewers/viewer_source.dart';
import 'platform_web_view.dart';
import 'web_assets.dart';

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
class WebBridge {
  WebBridge(
    this._view,
    this._workspace, {
    FileService? fileService,
    LlmProvider? llmClient,
    Future<List<String>> Function(List<ViewerSource>)? viewerStager,
    this.onOpenSettings,
    this.onOpenActivity,
  })  : _fs = fileService ?? FileService(),
        _defaultProvider = llmClient ?? OpenAiClient(),
        _stageViewers = viewerStager ?? ViewerAssets.sync;

  /// 웹의 설정 안내 버튼 → 네이티브 설정 창 열기. 인자는 열 섹션
  /// ('model'|'tools' 등, 빈 문자열이면 기본 탭). 웹뷰는 BuildContext 가 없어
  /// 다이얼로그를 직접 못 띄우므로 패널이 콜백으로 내려 준다.
  final void Function(String section)? onOpenSettings;

  /// 웹의 "호출 내역" 링크 → 네이티브 도구 호출 내역 창 열기.
  /// [id] 를 주면 그 호출을 선택한 상태로 연다(빈 문자열이면 최신).
  final void Function(String id)? onOpenActivity;

  /// 이번 세션의 도구 호출 기록(인자 + 결과 원문). 네이티브 창이 이걸 보여 준다.
  final ToolCallLog toolCalls = ToolCallLog();

  final PlatformWebView _view;
  final WorkspaceController _workspace;
  final FileService _fs;

  /// 사용자 뷰어 JS 를 웹 루트로 복사하고 상대 URL 목록을 돌려주는 함수.
  /// 기본은 [ViewerAssets.sync](path_provider 필요) — 테스트에서 갈아끼운다.
  final Future<List<String>> Function(List<ViewerSource>) _stageViewers;

  /// 기본 provider(주입되면 OpenAI 연결에 재사용). 다른 연결 방식은 [_providerFor]
  /// 가 연결별로 만들어 캐시한다.
  final LlmProvider _defaultProvider;
  final Map<LlmConnection, LlmProvider> _providers = {};

  /// 설정([LlmConfig.connection])에 맞는 provider 를 돌려준다. OpenAI 는 기본
  /// provider(주입 가능)를 쓰고, 그 외 연결은 연결별로 한 번 만들어 캐시한다.
  LlmProvider _providerFor(LlmConfig cfg) {
    if (cfg.connection == LlmConnection.openai) return _defaultProvider;
    return _providers.putIfAbsent(
        cfg.connection, () => createLlmProvider(cfg.connection));
  }

  bool _generating = false;

  /// 지금 프로젝트의 계획 메모리(`.collabo/PLAYBOOK.md`). 프로젝트가 없으면 null.
  ///
  /// 파일이 정본이므로 **생성이 시작될 때마다 다시 읽는다** — 사용자가 에디터에서
  /// 직접 고쳤을 수 있다. 생성 중에는 이 인스턴스가 유일한 창구다(계획 도구·컨텍스트
  /// 주입·종료 차단이 전부 같은 것을 본다).
  Playbook? _playbook;

  /// 이번 생성의 감독자. 생성이 끝나면 버린다(궤적은 턴 단위로만 의미가 있다).
  Supervisor? _supervisor;

  /// 도구가 파일을 바꿀 때마다 증가한다(`_recordFileChange`).
  /// 감독자의 "진전" 판정에만 쓴다 — 절대값은 의미가 없고 **움직였는지**만 본다.
  int _fileChangeSeq = 0;

  /// 사용자가 "중지"를 눌렀을 때 true. 진행 중인 스트림을 끊고 큐를 비운다.
  bool _cancelRequested = false;

  /// 현재 살아 있는 LLM 스트림들을 강제로 끊는 콜백 모음(메인 + 서브에이전트).
  final Set<void Function()> _streamAborters = {};

  /// 지금 돌고 있는 도구 프로세스들. 중지를 누르면 이것도 함께 끊는다.
  ///
  /// 도구에는 기본 타임아웃이 없다(길게 기다리는 게 정상인 도구가 있다) — 그래서
  /// 이 목록이 없으면 "중지" 가 실행 중인 도구가 끝날 때까지 기다리게 된다.
  final Set<Process> _toolProcesses = {};

  /// 생성 중 들어온 전송은 큐에 쌓아 두고, 끝나면 순서대로 처리한다.
  /// 각 항목 {id,text}. 웹은 상태 풍선의 큐 칩/모달로 보여주고 취소할 수 있다.
  final List<Map<String, Object?>> _queue = [];
  int _queueSeq = 0;

  StreamSubscription<dynamic>? _msgSub;
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _flushTimer;
  final Set<String> _pendingDirs = {};
  final Set<String> _pendingFiles = {};

  String? _projectPath;

  /// 웹 메시지 수신을 시작한다(컨트롤러 초기화 후 1회).
  void start() {
    _msgSub = _view.messages.listen(_onMessage);
    // 설정 창에서 프리셋을 바꾸면(추가/이름 변경/모델 변경/삭제/기본 지정) 대화
    // 헤더가 바로 따라오도록 컨트롤러 변경을 구독한다. 구독 시점의 상태를 지문으로
    // 잡아 두어, 첫 알림에서 불필요한 재전송이 나가지 않게 한다.
    _metaSignature = _headerMetaSignature();
    _viewerSignature = _viewerSourcesSignature();
    _viewerRuleSignature = _viewerRulesSignature();
    _workspace.addListener(_onWorkspaceChanged);
  }

  /// 헤더 메타(`chat.meta`)에 실리는 LLM 설정의 지문. 이 값이 달라질 때만 다시 보낸다.
  String _metaSignature = '';

  /// 사용자 뷰어 목록의 지문. 이 값이 달라질 때만 웹에 다시 얹는다.
  String _viewerSignature = '';

  /// 뷰어별 확장자/사용 여부 설정의 지문.
  String _viewerRuleSignature = '';

  /// 컨트롤러 알림을 받아, 실제로 달라진 것만 웹에 반영한다.
  ///
  /// [WorkspaceController] 의 알림은 백그라운드 프로세스 레지스트리에서도 포워드되어
  /// 자주 온다. 알림마다 [_pushChatMeta] 를 부르면 토큰 합산용 DB 조회(메인 + 하위
  /// 대화 전체)가, [_syncUserViewers] 를 부르면 파일 복사가 반복되므로, 각각
  /// 지문이 바뀐 경우에만 보낸다.
  void _onWorkspaceChanged() {
    final sig = _headerMetaSignature();
    if (sig != _metaSignature) {
      _metaSignature = sig;
      unawaited(_pushChatMeta());
    }
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
      await _view.executeScript('window.collaboSetViewerRules && '
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
      await _view.executeScript(
          'window.collaboSyncUserViewers && '
          'window.collaboSyncUserViewers(${jsonEncode(urls)})');
    } catch (_) {
      // 웹이 아직 준비 전이거나 이미 내려갔다 — `ready` 에서 다시 얹힌다.
    }
  }

  /// [_pushChatMeta] 가 웹으로 보내는 설정 관련 필드를 모은 지문.
  /// (프리셋 목록 = 드롭다운 항목, 기본/선택 프리셋 = 활성 표시, 모델명·멀티모달 =
  ///  헤더 라벨과 첨부 버튼, setup = 설정 안내 버튼.)
  /// 여기 없는 값이 헤더에 추가되면 이 지문에도 더해야 한다.
  String _headerMetaSignature() {
    final cfg = _workspace.configForConversation();
    return jsonEncode([
      [
        for (final p in _workspace.llmPresets) [p.id, p.label, p.config.model],
      ],
      _workspace.defaultPresetId,
      _workspace.presetIdForProject(),
      cfg.model,
      cfg.multimodal,
      _missingSetup(),
    ]);
  }

  /// 에이전트가 제대로 돌기 위해 아직 빠져 있는 설정(웹 헤더 안내 버튼용).
  /// **순서 = 안내 우선순위** — 웹은 첫 항목에 해당하는 설정 탭을 연다.
  List<String> _missingSetup() => [
        // 대화 자체가 불가능한 쪽을 먼저.
        if (!_workspace.configForConversation().isConfigured) 'llm',
        // 도구가 없으면 대화는 되지만 서브에이전트가 아무 작업도 못 한다.
        if (!_workspace.toolsReady) 'python',
      ];

  /// 현재 프로젝트를 바꾼다: 웹에 알리고, 감시자를 재시작하고, 대화 기록을 보낸다.
  Future<void> setProject(String? path) async {
    _projectPath = path;
    await _restartWatcher(path);
    _post({'type': 'project.changed', 'path': path ?? ''});
    // 계획은 프로젝트에 딸린 파일이다 — 프로젝트가 바뀌면 다시 읽어 카드를 갈아 끼운다.
    await _reloadPlaybook();
    _pushPlan();
    await _pushHistory();
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
        // 웹 준비 완료 → 현재 프로젝트/대화 기록 재통지.
        _post({'type': 'project.changed', 'path': _projectPath ?? ''});
        _pushHistory();
        // 페이지가 다시 로드되면 계획 카드도 비어 있다 → 파일에서 다시 읽어 보낸다.
        unawaited(_reloadPlaybook().then((_) => _pushPlan()));
        // 페이지가 (다시) 로드되면 등록된 뷰어는 사라진 상태다 → 다시 얹는다.
        // 규칙을 먼저 보낸다 — 파일을 열기 전에 확장자 연결이 적용돼 있어야 한다.
        unawaited(_pushViewerRules());
        unawaited(_syncUserViewers());
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
      case 'chat.send':
        _handleChatSend(
          msg['text'] as String?,
          _parseAttachments(msg['attachments']),
        );
        break;
      case 'chat.stop':
        _handleChatStop();
        break;
      case 'chat.queue.cancel':
        _handleQueueCancel((msg['id'] as num?)?.toInt());
        break;
      case 'chat.checkpoint.preview':
        _handleCheckpointPreview((msg['size'] as num?)?.toInt() ?? 2000);
        break;
      case 'chat.checkpoint.create':
        _handleCheckpointCreate(
            msg['compress'] == true, msg['content'] as String?);
        break;
      case 'chat.checkpoint.revert':
        _handleCheckpointRevert((msg['id'] as num?)?.toInt());
        break;
      case 'chat.checkpoint.edit':
        _handleCheckpointEdit(
            (msg['id'] as num?)?.toInt(), msg['content'] as String?);
        break;
      case 'chat.retry':
        _handleChatRetry();
        break;
      case 'chat.truncateFrom':
        _handleTruncate(msg['messageId'] as int?);
        break;
      case 'chat.delete':
        _handleDeleteMessage((msg['messageId'] as num?)?.toInt());
        break;
      case 'chat.edit':
        _handleChatEdit(msg['messageId'] as int?, msg['text'] as String?);
        break;
      case 'chat.setModel':
        _handleSetModel(msg['presetId'] as String?);
        break;
      case 'settings.open':
        onOpenSettings?.call((msg['section'] as String?) ?? '');
        break;
      case 'activity.open':
        // 결과 원문은 네이티브가 들고 있다 — 웹은 열어 달라고만 한다.
        onOpenActivity?.call((msg['id'] as String?) ?? '');
        break;
      case 'chat.summary.skip':
        _handleSummarySkip();
        break;
    }
  }

  /// 현재 프로젝트의 대화 모델 프리셋을 변경한다(빈/누락=기본 프리셋 사용).
  Future<void> _handleSetModel(String? presetId) async {
    final pp = _projectPath;
    if (pp == null) return;
    await _workspace.setProjectModel(pp, presetId ?? '');
    await _pushChatMeta();
  }

  // --- 대화 (LLM 스트리밍) ---

  ConversationStore? get _store => _workspace.conversation;
  int? get _convId => _workspace.activeConversationId;

  Future<void> _pushHistory() async {
    final store = _store, convId = _convId;
    if (store == null || convId == null) return;
    final msgs = await store.messages(convId);
    _post({
      'type': 'chat.history',
      'messages': msgs
          .map((m) => {
                'id': m.id,
                'role': m.role.name,
                // 예전 기록에 남은 <turn_summary> 마커는 표시 전에 걷어낸다.
                'content': stripTurnSummary(m.content),
                'model': m.model,
                'pipeline': m.pipeline,
                'toolCalls': m.toolCalls,
                'toolName': m.toolName,
                'toolCallId': m.toolCallId,
                if (m.role == MessageRole.assistant)
                  'summary': _summaryFromMeta(m.metadata),
                if (m.role == MessageRole.user)
                  'images': _imagesFromMeta(m.metadata),
              })
          .toList(),
    });
    await _pushChatMeta();
  }

  /// 어시스턴트 메시지 metadata(JSON)에서 이 턴의 요약을 꺼낸다(없으면 '').
  String _summaryFromMeta(String? metadata) {
    if (metadata == null || metadata.isEmpty) return '';
    try {
      final m = jsonDecode(metadata);
      if (m is Map && m['summary'] is String) return m['summary'] as String;
    } catch (_) {}
    return '';
  }

  /// 메시지 metadata 에 기록된 위임을 **컨텍스트용 마커 줄**로 만든다.
  ///
  /// 형식은 시스템 프롬프트에 명시돼 있다([kDelegationMarkerNote]) — 모델이 이 줄을
  /// 보고 "그 단계는 다른 에이전트가 했고, 상세는 이 컨텍스트에 없다" 를 알아야 한다.
  List<String> _delegationsFromMeta(String? metadata) {
    if (metadata == null || metadata.isEmpty) return const [];
    try {
      final m = jsonDecode(metadata);
      if (m is! Map) return const [];
      final list = m['delegated'];
      if (list is! List) return const [];
      return [
        for (final e in list)
          if (e is Map)
            '$kDelegationMarker ${e['tool'] ?? 'run_subagent'} — '
                '${e['task'] ?? ''}',
      ];
    } catch (_) {}
    return const [];
  }

  /// 메시지 metadata(JSON)에서 첨부 목록 전체를 꺼낸다(없으면 빈 리스트).
  /// 신규 키 'attachments' 와 레거시 키 'images' 를 모두 읽는다.
  List<Map<String, Object?>> _attachmentsFromMeta(String? metadata) {
    if (metadata == null || metadata.isEmpty) return const [];
    try {
      final m = jsonDecode(metadata);
      if (m is Map) return _parseAttachments(m['attachments'] ?? m['images']);
    } catch (_) {}
    return const [];
  }

  /// 첨부 중 인라인 표시/멀티모달 전송이 가능한 이미지(url 보유)만 꺼낸다.
  List<Map<String, Object?>> _imagesFromMeta(String? metadata) => [
        for (final a in _attachmentsFromMeta(metadata))
          if (a['url'] is String &&
              (a['url'] as String).startsWith('data:image'))
            a,
      ];

  /// 헤더용 메타: 모델명 + 현재 컨텍스트 점유량 + 누적 총 사용량(메인 + 서브 LLM).
  ///
  /// **컨텍스트**는 이제 가장 최근 메인 턴이 실제로 처리한 창 크기
  /// (prompt+completion)다. 예전엔 여기에 모든 메시지의 usage.total 을 합산했는데,
  /// 에이전트 루프는 도구 반복마다 assistant 턴을 저장하고 각 호출의 prompt 에
  /// 직전 히스토리가 다시 포함되므로, 합산하면 같은 컨텍스트를 중복 카운트해
  /// 실제 창 크기보다 크게 부풀려졌다(그 합산값은 '점유량'이 아니라 '누적 사용량').
  Future<void> _pushChatMeta() async {
    final store = _store, convId = _convId;
    var context = 0;
    var total = 0;
    if (store != null && convId != null) {
      final mainMsgs = await store.messages(convId);
      context = _currentContextTokens(mainMsgs);
      total = _sumUsageTotal(mainMsgs);
      // 하위 대화(서브에이전트/검증)의 토큰도 누적 총합에 더한다.
      for (final sub in await store.subConversations(convId)) {
        total += _sumUsageTotal(await store.messages(sub.id));
      }
    }
    // 프로젝트 폴더의 마지막 변경 시각(없으면 null) — 타이틀바에 표시.
    int? lastUpdated;
    final pp = _projectPath;
    if (pp != null) {
      try {
        lastUpdated = Directory(pp).statSync().modified.millisecondsSinceEpoch;
      } catch (_) {}
    }
    final convCfg = _workspace.configForConversation();
    _post({
      'type': 'chat.meta',
      'model': convCfg.model,
      'contextTokens': context,
      'totalTokens': total,
      'lastUpdated': lastUpdated,
      'multimodal': convCfg.multimodal,
      // 프로젝트 대화 모델 전환용: 프리셋 목록 + 현재 선택(빈 값=기본 프리셋).
      'presets': [
        for (final p in _workspace.llmPresets)
          {'id': p.id, 'name': p.label, 'model': p.config.model},
      ],
      'selectedPresetId': _workspace.presetIdForProject(),
      'defaultPresetId': _workspace.defaultPresetId,
      // 빠진 설정이 있으면 헤더에 안내 버튼을 띄운다(비어 있으면 숨김).
      'setup': _missingSetup(),
    });
  }

  /// 현재 컨텍스트 점유량(토큰): 가장 최근 **메인** 모델 턴이 실제로 처리한
  /// prompt+completion. 다음 턴에 실릴 컨텍스트 창 크기에 가장 가깝다.
  /// (한 요청의 마지막 메인 턴이라, 그 요청 중간의 도구 결과까지 포함된 값 —
  ///  다음 턴엔 도구 메시지가 제거돼 실제 전송량은 이보다 다소 작을 수 있다.)
  int _currentContextTokens(List<Message> msgs) {
    for (final m in msgs.reversed) {
      if (m.role != MessageRole.assistant || m.pipeline != 'main') continue;
      if (m.metadata == null) continue;
      try {
        final usage = (jsonDecode(m.metadata!) as Map)['usage'];
        if (usage is Map) {
          final prompt = usage['prompt'] is int ? usage['prompt'] as int : 0;
          final completion =
              usage['completion'] is int ? usage['completion'] as int : 0;
          if (prompt > 0 || completion > 0) return prompt + completion;
        }
      } catch (_) {}
    }
    return 0;
  }

  /// 메시지들의 metadata.usage.total 합(누적 사용량).
  int _sumUsageTotal(List<Message> msgs) {
    var sum = 0;
    for (final m in msgs) {
      if (m.metadata == null) continue;
      try {
        final usage = (jsonDecode(m.metadata!) as Map)['usage'];
        if (usage is Map && usage['total'] is int) sum += usage['total'] as int;
      } catch (_) {}
    }
    return sum;
  }

  Future<void> _handleChatSend(
      String? text, List<Map<String, Object?>> attachments) async {
    final store = _store, convId = _convId;
    final t = (text ?? '').trim();
    // 텍스트가 비어 있어도 첨부(이미지)가 있으면 전송을 허용한다.
    if ((t.isEmpty && attachments.isEmpty) || store == null || convId == null) {
      return;
    }
    // 생성 중이면 드롭하지 않고 대기 큐에 넣는다(끝나면 순서대로 처리).
    if (_generating) {
      _queue.add({'id': ++_queueSeq, 'text': t, 'attachments': attachments});
      _emitQueue();
      return;
    }
    await _sendAndDrain(store, convId, t, attachments);
  }

  /// 메시지를 보내고 생성한다. 끝난 뒤 큐에 쌓인 메시지가 있으면 순서대로 이어서 처리.
  Future<void> _sendAndDrain(ConversationStore store, int convId, String first,
      List<Map<String, Object?>> attachments) async {
    await _sendOne(store, convId, first, attachments);
    await _drainQueue(store, convId);
  }

  Future<void> _sendOne(ConversationStore store, int convId, String text,
      List<Map<String, Object?>> attachments) async {
    // 첨부는 메시지 metadata 에 확장 가능한 레코드로 보관(본문은 텍스트 그대로).
    // (과거 기록은 'images' 키 — 읽기는 양쪽 다 지원한다.)
    final meta = attachments.isEmpty
        ? null
        : jsonEncode({'attachments': attachments});
    final userId = await store.addMessage(
      conversationId: convId,
      role: MessageRole.user,
      content: text,
      metadata: meta,
    );
    _post({
      'type': 'chat.message',
      'id': userId,
      'role': 'user',
      'content': text,
      // 표시용은 인라인 이미지(url 보유)만 — 그 외 종류는 경로 기반(도구 접근).
      if (attachments.isNotEmpty)
        'images': [
          for (final a in attachments)
            if (a['url'] is String &&
                (a['url'] as String).startsWith('data:image'))
              a,
        ],
    });
    await _generate(store, convId);
  }

  /// 생성이 끝난 뒤 대기 큐를 순서대로 비운다(재시도/수정 경로에서도 호출).
  Future<void> _drainQueue(ConversationStore store, int convId) async {
    while (_queue.isNotEmpty) {
      if (_cancelRequested) break; // 중지 시 남은 큐 처리하지 않음
      final item = _queue.removeAt(0);
      _emitQueue();
      await _sendOne(store, convId, item['text'] as String,
          _parseAttachments(item['attachments']));
    }
  }

  /// 웹에서 받은 첨부 목록을 정규화한다. 확장 가능한 레코드 형태:
  /// {kind, name, url?, path?, mime?} — kind 는 image/file 등(향후 종류 추가),
  /// url 은 인라인 표시/멀티모달용(data URL), path 는 `.collabo/attach` 사본 경로.
  List<Map<String, Object?>> _parseAttachments(Object? raw) {
    if (raw is! List) return const [];
    final out = <Map<String, Object?>>[];
    for (final e in raw) {
      if (e is Map) {
        final url = e['url'], path = e['path'];
        final hasUrl = url is String && url.isNotEmpty;
        final hasPath = path is String && path.isNotEmpty;
        if (hasUrl || hasPath) {
          out.add({
            'kind': (e['kind'] as String?) ?? 'image',
            'name': (e['name'] as String?) ?? '',
            if (hasUrl) 'url': url,
            if (hasPath) 'path': path,
            if (e['mime'] is String && (e['mime'] as String).isNotEmpty)
              'mime': e['mime'],
          });
        }
      }
    }
    return out;
  }

  /// 현재 대기 큐 상태를 웹으로 전달한다(상태 풍선 칩/모달 갱신용).
  void _emitQueue() => _post({'type': 'chat.queue', 'items': _queue});

  /// 중지 완료를 웹에 **정확히 한 번** 알린다.
  ///
  /// 웹은 중지를 누른 순간 버튼을 "중지 중…" 으로 바꾸고 비활성화한다 — 이 통지가
  /// 안 가면 그 상태로 영영 멈춘다. 중지 경로가 여러 갈래(스트림 abort, 루프 조기
  /// 반환, 중지할 게 없는 경우)라 여기 한 곳으로 모은다.
  void _postStopped() {
    if (_stoppedPosted) return;
    _stoppedPosted = true;
    _post({'type': 'chat.stopped'});
    _clearStatus();
  }

  /// 이번 중지 사이클에서 `chat.stopped` 를 이미 보냈는지(새 생성 시작 시 초기화).
  bool _stoppedPosted = false;

  /// 진행 중인 생성을 강제로 중지하고, 대기 큐의 모든 요청을 취소한다.
  void _handleChatStop() {
    // 누를 때마다 한 번은 응답한다 — 두 번째 누름이 중복 가드에 막히면 그때부터
    // 다시 "중지 중…" 에 갇힌다. (한 번의 누름 안에서만 중복을 막는다.)
    _stoppedPosted = false;
    // 중지할 게 없어도 **응답은 반드시 보낸다.** 오류로 이미 끝난 뒤에 누르면
    // 예전에는 여기서 조용히 반환해, 웹의 "중지 중…" 이 영원히 남았다.
    if (!_generating && _queue.isEmpty && _streamAborters.isEmpty) {
      _postStopped();
      return;
    }
    _cancelRequested = true;
    // 대기 중인 요청 모두 취소.
    _queue.clear();
    _emitQueue();
    // 살아 있는 LLM 스트림(메인/서브에이전트)을 즉시 끊는다.
    for (final abort in _streamAborters.toList()) {
      abort();
    }
    // 실행 중인 도구도 함께 끊는다. 이게 없으면 도구가 끝날 때까지 중지가 지연된다
    // (예: `run_wait` 의 30초 대기). 백그라운드 명령 자체는 detached 라 살아 있고,
    // 사용자가 프로세스 뷰어에서 따로 관리한다.
    for (final proc in _toolProcesses.toList()) {
      proc.kill();
    }
    _toolProcesses.clear();
  }

  /// 큐에서 대기 메시지를 취소(제거)한다.
  void _handleQueueCancel(int? id) {
    if (id == null) return;
    _queue.removeWhere((m) => m['id'] == id);
    _emitQueue();
  }

  Future<void> _handleChatRetry() async {
    final store = _store, convId = _convId;
    if (store == null || convId == null || _generating) return;
    await _generate(store, convId);
    await _drainQueue(store, convId);
  }

  Future<void> _handleTruncate(int? messageId) async {
    final store = _store, convId = _convId;
    if (messageId == null || store == null || convId == null) return;
    await store.deleteMessagesFrom(convId, messageId);
    _post({'type': 'chat.truncated', 'messageId': messageId});
  }

  /// 메시지 삭제: 그 메시지가 속한 턴 구간(도구 호출/결과, 중간 assistant 행,
  /// 서브에이전트 기록 포함)을 함께 지운다. 앞뒤 다른 턴은 유지.
  Future<void> _handleDeleteMessage(int? messageId) async {
    final store = _store, convId = _convId;
    if (messageId == null || store == null || convId == null || _generating) {
      return;
    }
    await store.deleteTurn(convId, messageId);
    await _pushHistory();
  }

  /// 인플레이스 수정: 해당 메시지를 고치고, 그 아래는 삭제 후 다시 생성한다.
  Future<void> _handleChatEdit(int? messageId, String? text) async {
    final store = _store, convId = _convId;
    if (messageId == null ||
        text == null ||
        text.trim().isEmpty ||
        store == null ||
        convId == null ||
        _generating) {
      return;
    }
    await store.updateMessageContent(messageId, text);
    await store.deleteMessagesAfter(convId, messageId);
    _post({'type': 'chat.edited', 'messageId': messageId, 'content': text});
    await _generate(store, convId);
    await _drainQueue(store, convId);
  }

  // ===== 시작점(체크포인트): 지금까지의 대화를 (선택적으로 압축해) 새 시작점으로 =====

  /// 시작점 압축 미리보기: 이전 내용을 LLM 으로 약 [sizeTokens] 토큰으로 요약해
  /// 다이얼로그로 돌려준다(아직 시작점을 만들지는 않는다 → 사용자가 보고 편집).
  Future<void> _handleCheckpointPreview(int sizeTokens) async {
    final store = _store, convId = _convId;
    if (store == null || convId == null || _generating) return;
    _generating = true;
    _status('Generating preview…');
    String summary = '';
    try {
      summary = await _compressHistory(
          await store.messages(convId), sizeTokens.clamp(100, 10000));
    } finally {
      _generating = false;
      _clearStatus();
    }
    _post({'type': 'checkpoint.preview', 'text': summary});
  }

  /// 시작점 생성. [compress] 면 미리보기에서 받은(편집 가능) [content] 를 그대로
  /// 시작점에 보관한다. 이후 대화는 그 요약 + 시작점 이후 메시지만 컨텍스트에 쓴다.
  Future<void> _handleCheckpointCreate(bool compress, String? content) async {
    final store = _store, convId = _convId;
    if (store == null || convId == null || _generating) return;
    final summary = compress ? (content ?? '').trim() : '';
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.system,
      content: summary,
      pipeline: 'checkpoint',
    );
    await _pushHistory();
    if (_queue.isNotEmpty) await _drainQueue(store, convId);
  }

  /// 마지막 시작점 이후 메시지(+이전 요약)를 LLM 으로 요약한다. 실패하면 ''.
  Future<String> _compressHistory(List<Message> all, int targetTokens) async {
    var startIdx = 0;
    var prior = '';
    for (var i = all.length - 1; i >= 0; i--) {
      if (all[i].pipeline == 'checkpoint') {
        startIdx = i + 1;
        prior = all[i].content.trim();
        break;
      }
    }
    final buf = StringBuffer();
    if (prior.isNotEmpty) buf.writeln('[Earlier summary]\n$prior\n');
    for (final m in all.sublist(startIdx)) {
      if (m.pipeline == 'checkpoint') continue;
      final c = m.content.trim();
      if (c.isEmpty) continue;
      buf.writeln('[${m.role.name}] $c');
    }
    final transcript = buf.toString().trim();
    if (transcript.isEmpty) return '';
    final cfg = _workspace.configForConversation();
    final presetId = _workspace.resolvedPresetIdForConversation();
    final sys =
        'You compress a conversation into a concise summary that preserves key '
        'decisions, requirements, file/code changes, and open threads, so the '
        'assistant can continue seamlessly. Target about $targetTokens tokens '
        '(~${targetTokens * 4} characters). Output ONLY the summary text.';
    try {
      final turn = await _withLlmRetry(
        () => _runSubModelTurn(cfg, presetId, [
          {'role': 'system', 'content': sys},
          {'role': 'user', 'content': transcript},
        ], null),
        reason: 'Compress',
        maxAttempts: 2,
      );
      return turn.content.trim();
    } catch (_) {
      return '';
    }
  }

  /// 시작점 원복: 시작점 메시지 한 건만 삭제(앞뒤 대화는 그대로 유지).
  Future<void> _handleCheckpointRevert(int? id) async {
    final store = _store, convId = _convId;
    if (id == null || store == null || convId == null) return;
    await store.deleteMessage(id);
    await _pushHistory();
  }

  /// 시작점의 압축 내용 편집.
  Future<void> _handleCheckpointEdit(int? id, String? content) async {
    final store = _store;
    if (id == null || content == null || store == null) return;
    await store.updateMessageContent(id, content);
    await _pushHistory();
  }

  static const int _maxToolIterations = 20;
  static const int _maxAttempts = 3;
  static const int _maxSubIterations = 8;

  // 요청 후 **첫 응답**(첫 토큰/리즈닝/도구호출)까지의 대기 시간은 **연결(프리셋)별
  // 설정**이다 — `LlmConfig.firstResponseTimeout`(설정 → 모델, 0 이면 제한 없음).
  //
  // 아직 아무것도 오지 않은 상태만 대상으로 한다 — 연결이 죽었는지 앱이 알 방법이
  // 이것뿐이기 때문이다. 다만 로컬 모델은 컨텍스트가 크면 첫 토큰 전 **프리필**에만
  // 수십 분이 걸릴 수 있고, 그동안 서버는 멀쩡히 일하는 중인데도 소켓에는 아무것도
  // 오지 않는다 — 그래서 고정값을 두지 않고 서버에 맞춰 늘리거나 끄게 했다.
  // 이 대기 중에도 사용자는 언제든 중지할 수 있다.

  // 스트리밍 **도중**에는 타임아웃을 걸지 않는다.
  //
  // 예전에는 이벤트 간격 90초를 넘기면 끊었다(모델이 같은 문자를 무한히 뱉는 상태를
  // 빨리 벗어나려는 장치였다). 그런데 정상적으로 오래 걸리는 작업 — 큰 컨텍스트의
  // 프리필, 긴 추론, 느린 로컬 모델 — 까지 같이 끊겨 **진행 중인 작업을 죽이는 쪽이
  // 훨씬 큰 피해**였다. 토큰이 오고 있다면 그건 살아 있다는 뜻이므로 앱은 기다린다.
  //
  // 반복 출력에 빠진 경우는 **사용자가 직접 보고 판단**한다: 상태 풍선의 "토큰 보기"
  // 로 지금 들어오는 스트림을 그대로 볼 수 있고, 중지 버튼은 항상 열려 있다.

  /// 네이티브로 처리하는 도구(서브 LLM 분기). 파이썬으로 보내지 않는다.
  static const Set<String> _nativeToolNames = {'run_subagent', 'verify_work'};

  /// 계획 메모리(`.collabo/PLAYBOOK.md`)를 고치는 도구. 이것도 네이티브다 —
  /// 브리지 자신이 PLAYBOOK 을 읽어 컨텍스트에 넣고 종료 차단의 근거로 쓰므로,
  /// 파이썬 프로세스를 한 번 더 띄울 이유가 없다.
  static const Set<String> _planToolNames = {
    'set_goal',
    'update_plan',
    'note_write',
  };

  /// **서브에이전트에 주는 계획 도구는 `note_write` 하나뿐이다.**
  ///
  /// 목표와 계획은 오케스트레이터(메인)의 것이다. 서브에이전트는 자기 과제 하나만
  /// 보고 있어서 전체 계획을 다시 쓰면 안 된다. 반대로 **알아낸 것·배제한 접근**은
  /// 실제 작업이 일어나는 그 자리에서 남기는 게 가장 정확하다.
  static const Set<String> _subPlanToolNames = {'note_write'};

  static const List<Map<String, Object?>> _nativeTools = [
    {
      'type': 'function',
      'function': {
        'name': 'run_subagent',
        'description':
            'Delegate a focused sub-task to a separate sub-agent that has its '
                'own fresh context and can use the file tools. Returns the '
                'sub-agent result. Use this to keep the main conversation '
                'context small.',
        'parameters': {
          'type': 'object',
          'properties': {
            'prompt': {
              'type': 'string',
              'description': 'The full instruction for the sub-agent.',
            },
          },
          'required': ['prompt'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'verify_work',
        'description':
            'Verify that completed work was done correctly. Provide a '
                'verification prompt (based on what you just did) describing '
                'what to check. A sub-agent inspects the project and returns a '
                'verdict (PASS/FAIL with reasons).',
        'parameters': {
          'type': 'object',
          'properties': {
            'prompt': {
              'type': 'string',
              'description': 'What to verify, based on the work just performed.',
            },
          },
          'required': ['prompt'],
        },
      },
    },
  ];

  /// 계획 메모리 도구 3종. 설정에서 계획 메모리를 끄면 아예 넘기지 않는다
  /// (모델에게 없는 도구를 보여 주지 않는다).
  static const List<Map<String, Object?>> _planTools = [
    {
      'type': 'function',
      'function': {
        'name': 'set_goal',
        'description':
            'Record the goal of what the user asked for, in one sentence, and '
                'optionally the steps to get there. Call this ONCE at the start '
                'of a non-trivial task, before doing the work. The goal and plan '
                'are stored in $kPlaybookPath and survive summarisation, so you '
                'can always see what you set out to do.',
        'parameters': {
          'type': 'object',
          'properties': {
            'goal': {
              'type': 'string',
              'description': 'The goal in one sentence, in the user\'s words.',
            },
            'steps': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Optional: the steps, each a short imperative phrase. '
                      'Same as calling update_plan with steps.',
            },
          },
          'required': ['goal'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'update_plan',
        'description':
            'Change the plan. Give `steps` to replace the whole plan (use this '
                'when you change direction), or give `step` + `status` to move '
                'one step along. Mark each step DONE as soon as it is actually '
                'finished — a step left TODO or DOING blocks you from ending '
                'the turn. If you need to stop and ask the user something, mark '
                'the step BLOCKED first: that is the only way to hand the turn '
                'back while the step is unfinished.',
        'parameters': {
          'type': 'object',
          'properties': {
            'steps': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Replace the whole plan with these steps.',
            },
            'step': {
              'type': 'string',
              'description':
                  'Which step to update: its 1-based number, or part of its text.',
            },
            'status': {
              'type': 'string',
              'enum': ['TODO', 'DOING', 'BLOCKED', 'DONE', 'DROP'],
              'description':
                  'New status for that step. BLOCKED means you are waiting on '
                      'an answer from the user. DROP means you decided not to '
                      'do it.',
            },
            'note': {
              'type': 'string',
              'description': 'Optional short note appended to that step.',
            },
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'note_write',
        'description':
            'Record one thing you learned, in one line, so it survives even '
                'after this conversation is summarised. ALWAYS mark how sure you '
                'are: VERIFIED (you checked it with a tool just now), ASSUMED '
                '(you believe it but have not checked), REFUTED (you tried it '
                'and it does not work).',
        'parameters': {
          'type': 'object',
          'properties': {
            'section': {
              'type': 'string',
              'enum': ['working_model', 'ruled_out', 'open_questions'],
              'description':
                  'working_model = how this project actually works; '
                      'ruled_out = an approach you tried that failed; '
                      'open_questions = something still unknown.',
            },
            'text': {
              'type': 'string',
              'description': 'The single line to record.',
            },
            'marker': {
              'type': 'string',
              'enum': ['VERIFIED', 'ASSUMED', 'REFUTED'],
              'description': 'How sure you are. Defaults to ASSUMED.',
            },
          },
          'required': ['section', 'text'],
        },
      },
    },
  ];

  /// 서브에이전트에 주는 계획 도구(= `note_write` 하나).
  static List<Map<String, Object?>> get _subPlanTools => [
        for (final t in _planTools)
          if (_subPlanToolNames
              .contains((t['function'] as Map)['name'] as String))
            t,
      ];

  // 서브에이전트는 **사용자 편집 시스템 프롬프트를 받지 않는다**(자기 컨텍스트로
  // 분기하며 아래 문구만 system 으로 받는다). 실제 파일 작업은 여기서 일어나므로,
  // 임시 스크립트 규칙도 반드시 이 문구에 있어야 한다.
  /// 서브에이전트에게 "네가 가진 도구" 를 **실제 목록으로** 알려 주는 문장.
  ///
  /// 예전에는 `(file read/search/edit, commands)` 라고 손으로 요약해 뒀는데,
  /// 그게 사실상 능력 화이트리스트처럼 읽혀 **모듈을 더 붙여도 모델이 모르는** 문제가
  /// 있었다(문서 도구를 두고도 파이썬 스크립트를 짜는 원인). 레지스트리에서 그대로
  /// 뽑아 쓰면 도구가 늘거나 사용자가 추가해도 문구가 저절로 따라온다.
  static String _toolInventory(ToolRegistry? registry) {
    final names = registry?.toolNames ?? const <String>[];
    if (names.isEmpty) {
      return 'You have NO tools available right now — say so instead of '
          'pretending to act.';
    }
    return 'These are ALL the tools you have: ${names.join(', ')}. '
        'Read that list before deciding how to do something — if one of them '
        'covers the job, use it instead of writing your own script.';
  }

  static String _subAgentSystemFor(ToolRegistry? registry) =>
      'You are a focused sub-agent in Collabo IDE. Complete the given task using '
      'your tools. Work only within the project. '
      '${_toolInventory(registry)} '
      'A purpose-built tool understands the format and its pitfalls, while a '
      'hand-written script silently corrupts what it does not know about. '
      'If no tool fits and you must write a throwaway helper script, create it '
      'under `$kAgentScratchDir` and run it from there — never scatter temporary '
      'scripts in the project root. Files that belong to the user\'s project '
      '(real source, tests, config they asked for) still go in their normal '
      'place. Return a concise result of what you did or found.';

  static String _verifySystemFor(ToolRegistry? registry) =>
      'You are a verification sub-agent in Collabo IDE. Inspect the project and '
      'verify whether the described work was completed correctly. '
      '${_toolInventory(registry)} '
      'If no tool fits and you need a throwaway check script, put it under '
      '`$kAgentScratchDir`. Be concise. End with a clear verdict: '
      'PASS or FAIL, with brief reasons.';

  /// 트리아지(사전 평가) 서브에이전트: 사용자의 마지막 요청만 보고, 서브에이전트가
  /// 할 일(자기 차례)이 있는지 한 줄로 답한다. 실제 작업은 하지 않는다.
  static const String _triageSystem =
      'You are a fast triage sub-agent in Collabo IDE. Look ONLY at the user\'s '
      'latest request and decide whether it needs delegated sub-agent work '
      '(file edits, multi-step changes, running commands, code investigation). '
      'Do NOT do the work. Reply with ONE short line:\n'
      '- If sub-agent work IS needed, start with "YES:" then what to delegate.\n'
      '- If NOT needed (just conversational), reply with exactly "NO".\n'
      'Output only that one line, nothing else.';

  /// 에이전트 루프 + 재시도. 모델 호출 → 도구 호출이 있으면 실행·회신 → 반복.
  /// 도구 호출 없는 최종 응답이 나오면 성공. **오류(예: 통신 실패)** 시에만 그 시도의
  /// 기록을 정리하고 최대 [_maxAttempts] 회 재시도한다. 반복 한도 초과(비수렴)는
  /// 이미 수행한 작업을 지우지 않고 그대로 두고 종료한다.
  Future<void> _generate(ConversationStore store, int convId) async {
    final cfg = _workspace.configForConversation();
    // 속도 실측과 시간 예산은 **프리셋 단위**로 모은다 — 서버가 다르면 속도도 다르다.
    final presetId = _workspace.resolvedPresetIdForConversation();
    if (!cfg.isConfigured) {
      _post({
        'type': 'chat.error',
        'message': 'LLM is not configured. Enter connection info in settings.'
      });
      return;
    }
    _generating = true;
    _cancelRequested = false; // 새 생성 시작 — 이전 중지 플래그 초기화
    _stoppedPosted = false;
    // 직전 턴의 백그라운드 요약이 아직 돌고 있으면 여기서만 기다린다
    // (요약은 아래 _buildContextMessages 에서 처음 쓰인다).
    await _awaitTurnSummaries();
    _status('Preparing…');

    // 계획 메모리는 **파일이 정본**이라 생성마다 다시 읽는다(사용자가 고쳤을 수 있다).
    // 감독자는 이번 생성 동안만 산다 — 궤적은 턴 단위로만 의미가 있다.
    await _reloadPlaybook();
    _supervisor = Supervisor(enabled: _workspace.supervisor);

    final registry = await _buildToolRegistry();
    // 파이썬 도구 + 네이티브 서브에이전트 도구 + 계획 도구를 메인 LLM 에 제공.
    final tools = <Map<String, Object?>>[
      if (registry != null) ...registry.openAiTools,
      ..._nativeTools,
      if (_playbook != null) ..._planTools,
    ];
    final workspace = _workspace.projectPath;

    // 사전 평가: 서브에이전트가 마지막 요청을 보고 "자기 차례가 있는지" 한 줄 피드백.
    // 이 한 줄을 메인 컨텍스트에 넣어 메인 에이전트가 그걸 참고해 답을 쓰게 한다.
    final triage = await _triageRequest(store, convId, cfg);
    // 턴 요약에 "무엇을 요청받았는지"를 함께 넘기려고 한 번만 읽어 둔다.
    final userRequest = _clip(await _lastUserRequest(store, convId), 600);

    // 이 생성이 시작되기 **전** 마지막 메시지(보통 방금 저장한 사용자 메시지).
    // 재시도/중지 정리는 이 경계 뒤를 지운다 — 시도 중 어디서 실패하든(첫 호출이
    // 곧바로 던져도) 이번 요청이 만든 기록만 정확히 걷힌다.
    // 목록은 created_at 순이라 마지막 항목이 곧 최대 id 라는 보장이 없다(시계 역전).
    // 삭제 기준은 id 이므로 최대 id 를 직접 고른다.
    var maxId = 0;
    for (final m in await store.messages(convId)) {
      if (m.id > maxId) maxId = m.id;
    }
    final baselineId = maxId == 0 ? null : maxId;

    try {
      for (var attempt = 0; attempt < _maxAttempts; attempt++) {
        if (_cancelRequested) return; // 중지 요청됨 — 더 진행하지 않음
        try {
          final messages = await _buildContextMessages(store, convId,
              preAssessment: triage);
          // 보낼 사용자 메시지가 하나도 없으면 부르지 않는다. 시작점을 만든 직후
          // "다시 시도" 를 누르면 이 상태가 된다(시작점 이후가 비어 있다) — 지시만
          // 있고 대화가 없는 요청이라, 로컬 서버는 템플릿 단계에서 그대로 실패한다.
          if (!messages.any((m) => m['role'] == 'user')) {
            _post({
              'type': 'chat.notice',
              'text': 'Nothing to send yet — write a message first.',
            });
            return;
          }
          var converged = false;
          // 이 턴에서 쓴 도구 이름 — 요약 호출에 함께 넘긴다(무엇을 했는지 근거).
          final toolsUsed = <String>[];
          for (var iter = 0; iter < _maxToolIterations; iter++) {
            if (_cancelRequested) throw const _GenerationStopped();
            final changesBeforeRound = _fileChangeSeq;
            // 실제 대기/수신 상태는 _runModelTurn 이 직접 풍선에 표시한다.
            final turn =
                await _runModelTurn(store, convId, cfg, presetId, messages, tools);
            if (turn.toolCalls.isEmpty) {
              // **종료 차단**: 계획에 열린 단계가 남았는데 끝내려 하면 되돌려보낸다.
              // 판단 재료는 구조적인 것뿐이다 — 열린 단계와 "이 턴에 도구를 썼는가".
              // 답변 본문은 보지 않는다. 사용자를 기다리며 끝내려면 모델이
              // `update_plan` 으로 그 단계에 BLOCKED 를 찍으면 된다.
              final violations = _supervisor?.exitViolations(
                    openSteps: _playbook?.openSteps ?? const [],
                    usedTools: toolsUsed.isNotEmpty,
                  ) ??
                  const <String>[];
              if (violations.isNotEmpty && (_supervisor?.mayReinject ?? false)) {
                _supervisor!.noteReinjection();
                _applyIntervention(
                  messages,
                  Intervention(
                    action: 'exit_guard',
                    reason: 'finished with open plan steps',
                    message: '[supervisor] Not done yet.\n'
                        '- ${violations.join('\n- ')}',
                    level: 0,
                    halt: false,
                  ),
                );
                continue; // 같은 턴 안에서 이어서 돌린다
              }
              converged = true;
              // 답변은 이미 확정됐다 — 요약은 기다리지 않고 뒤에서 만든다.
              _scheduleTurnSummary(
                  store, turn.id, turn.content, toolsUsed, userRequest);
              break;
            }
            toolsUsed.addAll(turn.toolCalls.map((c) => c.name));
            messages.add({
              'role': 'assistant',
              'content': turn.content.isEmpty ? null : turn.content,
              'tool_calls': [
                for (final c in turn.toolCalls)
                  {
                    'id': c.id,
                    'type': 'function',
                    'function': {'name': c.name, 'arguments': c.arguments},
                  },
              ],
            });
            Intervention? iv;
            for (final c in turn.toolCalls) {
              // 중지를 눌렀으면 남은 도구 호출은 시작하지 않는다(빠른 중지).
              if (_cancelRequested) throw const _GenerationStopped();
              iv = await _runToolCall(store, convId, registry, workspace,
                      messages, attempt, iter, c, turn.id) ??
                  iv;
            }
            // 라운드가 끝났다 — 이 라운드에 파일이 하나도 안 바뀌었으면 진전 없음.
            iv ??= _supervisor?.roundDone(
                progress: _fileChangeSeq != changesBeforeRound);
            if (iv != null) {
              _applyIntervention(messages, iv);
              if (iv.halt) {
                // 마지막 단계다. 도구를 **거두고** 한 라운드만 더 돌려 사용자에게
                // 무엇이 막혔는지 말하게 한다. 그냥 끊으면 사용자는 이유를 모른다.
                final closing =
                    await _runModelTurn(store, convId, cfg, presetId, messages, null);
                _scheduleTurnSummary(
                    store, closing.id, closing.content, toolsUsed, userRequest);
                converged = true;
                break;
              }
            }
          }
          // 계획 카드는 계획 도구가 부를 때마다 이미 갱신된다(_runPlanTool → _pushPlan).
          // 비수렴(반복 한도 초과)이어도 수행한 작업은 그대로 두고 종료한다.
          if (!converged) {
            _post({'type': 'chat.notice', 'text': 'reached step limit ($_maxToolIterations)'});
          }
          await _pushChatMeta();
          return;
        } catch (e) {
          // 사용자가 중지를 누른 경우: 재시도하지 않고 이번 시도의 부분 기록만 정리.
          if (e is _GenerationStopped || _cancelRequested) {
            await _cleanupAttempt(store, convId, baselineId);
            _postStopped();
            return;
          }
          // 예산 초과: 재시도하지 않는다. 같은 조건이면 또 걸리므로 토큰만 두 배로
          // 나간다. 대신 **왜 이 시간이었는지**를 그대로 보여 준다(설정을 고치라고).
          if (e is LlmBudgetExceeded) {
            await _cleanupAttempt(store, convId, baselineId);
            _post({'type': 'chat.error', 'message': e.message});
            return;
          }
          // 통신/타임아웃 등 오류는 재시도(이미 추가된 이번 시도 기록은 정리).
          await _cleanupAttempt(store, convId, baselineId);
          if (attempt == _maxAttempts - 1) {
            _post({'type': 'chat.error', 'message': '$e'});
            return;
          }
          _post({'type': 'chat.notice', 'text': 'retry ${attempt + 2}/$_maxAttempts'});
          await _retryDelay(attempt + 2, _maxAttempts, _briefErr(e));
        }
      }
    } finally {
      _generating = false;
      _supervisor = null; // 궤적은 턴 단위 — 다음 생성은 깨끗한 상태로 시작한다
      // 중지로 끝났다면 어느 경로로 빠져나왔든 여기서 통지가 보장된다.
      // (예: 시도 루프 맨 위의 `if (_cancelRequested) return;` — 예전에는 이 길로
      //  나가면 `chat.stopped` 가 없어 웹이 "중지 중…" 에 갇혔다.)
      if (_cancelRequested) {
        _postStopped();
      } else {
        _clearStatus();
      }
    }
  }

  /// 사전 평가(트리아지): 마지막 사용자 요청을 서브 LLM 으로 한 줄 평가한다.
  /// 설정(preAssessment)이 꺼져 있거나 사용자 메시지가 없으면 null.
  /// 실패해도 메인 흐름을 막지 않도록 best-effort 로 처리한다.
  Future<String?> _triageRequest(
      ConversationStore store, int convId, LlmConfig cfg) async {
    if (!_workspace.preAssessment) return null;
    String? lastUser;
    for (final m in (await store.messages(convId)).reversed) {
      if (m.role == MessageRole.user && m.content.trim().isNotEmpty) {
        lastUser = m.content;
        break;
      }
    }
    if (lastUser == null) return null;
    _status('Assessing request…');
    try {
      final turn = await _withLlmRetry(
        () => _runSubModelTurn(cfg, _workspace.resolvedPresetIdForConversation(),
            [
          {'role': 'system', 'content': _triageSystem},
          {'role': 'user', 'content': lastUser!},
        ], null),
        reason: 'Pre-assessment',
        maxAttempts: 2,
      );
      final line = turn.content.trim().replaceAll('\n', ' ');
      // 차례 없음(NO)으로 판단되면 아무것도 추가/표시하지 않는다. "없다"는 문구를
      // 컨텍스트에 넣으면 메인 에이전트가 위임을 안 해버리므로, 차례 있을 때만 넣는다.
      if (line.isEmpty || RegExp(r'^no\b', caseSensitive: false).hasMatch(line)) {
        return null;
      }
      // "YES:" 접두는 떼고 정리해 한 줄 피드백으로 표시 + 컨텍스트에 주입.
      final body =
          line.replaceFirst(RegExp(r'^yes\s*[:\-—]?\s*', caseSensitive: false), '');
      final feedback = 'Sub-agent: ${body.isEmpty ? 'yes' : body}';
      _post({'type': 'chat.notice', 'text': feedback}); // 한 줄 피드백 표시
      return feedback;
    } catch (_) {
      return null; // 사전 평가 실패는 무시(메인 응답은 계속 진행)
    }
  }

  /// 시스템 프롬프트 + 기존 user/assistant/system 텍스트로 컨텍스트를 만든다.
  ///
  /// **시작점(체크포인트)** 이 있으면, 마지막 체크포인트 **이후** 메시지만 LLM 에
  /// 넣고, 그 이전 내용은 체크포인트에 저장된 **압축 요약**(있으면)으로 대체한다.
  /// 요약은 시스템 지시가 아니라 **지난 대화의 내용**이므로 `assistant` 메시지로
  /// 넣는다. 압축본이 없는 시작점이면 아무것도 더하지 않는다 — 시작점 이후만
  /// 남는 것이 곧 그 의미다.
  Future<List<Map<String, Object?>>> _buildContextMessages(
      ConversationStore store, int convId,
      {String? preAssessment}) async {
    final prompt = _workspace.systemPrompt.trim();
    final all = await store.messages(convId);
    // 마지막 시작점(체크포인트)을 찾는다.
    var startIdx = 0;
    String? summary;
    for (var i = all.length - 1; i >= 0; i--) {
      if (all[i].pipeline == 'checkpoint') {
        startIdx = i + 1;
        final c = all[i].content.trim();
        if (c.isNotEmpty) summary = c;
        break;
      }
    }
    // 프로젝트 상태(폴더 구조 + 이미 바꾼 파일) — 매 턴 새로 만들어 최신을 유지한다.
    final state = await _projectStateContext();

    final slice = all.sublist(startIdx);
    // 대화 **중간**에 있는 system 기록은 머리로 끌어올린다. 우리가 만드는 건
    // 시작점(위에서 걸러짐)뿐이지만, **가져오기(import)** 로 들어온 대화에는 다른
    // 도구가 남긴 system 이 섞여 있을 수 있다 — 중간에 두면 로컬 템플릿이 거부한다.
    final strays = [
      for (final m in slice)
        if (m.role == MessageRole.system && m.pipeline != 'checkpoint')
          m.content.trim(),
    ];

    final messages = <Map<String, Object?>>[
      ...systemHead([
        prompt,
        // 마커 설명은 **항상** 들어가야 한다. 기본 프롬프트에도 들어 있지만, 사용자가
        // 프롬프트를 편집해 저장하면 그 문단이 통째로 사라질 수 있다 — 그러면
        // 컨텍스트에 남은 `[delegated]` 줄이 정체불명의 텍스트가 된다.
        if (!prompt.contains(kDelegationMarker)) kDelegationMarkerNote,
        // 계획 규율도 마커 설명과 같은 이유로 보강한다 — 사용자가 프롬프트를 편집해
        // 저장했으면 이 문단이 통째로 없다. 계획 메모리가 꺼져 있으면 넣지 않는다
        // (`_playbook == null`) — 없는 도구를 설명하지 않는다.
        if (_playbook != null && !prompt.contains(kPlaybookPath)) kPlanningNote,
        // 계획은 상태보다 **먼저** 온다 — "무엇을 하려는가" 를 읽고 나서 "지금 어떤
        // 상태인가" 를 읽는 순서가 자연스럽다.
        _planContext(forSubAgent: false),
        state,
        // 사전 평가(트리아지)도 여기 합친다. 예전에는 **맨 뒤**에 system 으로 붙였는데,
        // 그러면 배열이 system 으로 끝나 대부분의 템플릿이 생성 프롬프트를 못 붙인다.
        if (preAssessment != null)
          'Sub-agent pre-assessment of the latest request: $preAssessment\n'
              'Use this when deciding whether to delegate via `run_subagent`.',
        ...strays,
      ]),
      // 압축본은 **지난 대화의 요약**이다 — 지시가 아니므로 assistant 로 넣는다.
      // (압축 없이 만든 시작점은 summary 가 비어 있어 아무것도 들어가지 않는다.)
      if (summary != null)
        {
          'role': 'assistant',
          'content': 'Summary of our earlier conversation (before the current '
              'starting point):\n$summary',
        },
    ];

    final multimodal = _workspace.configForConversation().multimodal;
    // 직전 1턴(가장 최근 어시스턴트 메시지)은 원문 그대로 두어 바로 앞 대화의
    // 정확성을 지키고, 그보다 이전의 어시스턴트 턴만 요약으로 대체한다.
    var lastAssistantIdx = -1;
    for (var i = slice.length - 1; i >= 0; i--) {
      if (slice[i].role == MessageRole.assistant) {
        lastAssistantIdx = i;
        break;
      }
    }
    for (var idx = 0; idx < slice.length; idx++) {
      final m = slice[idx];
      if (m.pipeline == 'checkpoint') continue;
      final role = switch (m.role) {
        MessageRole.user => 'user',
        MessageRole.assistant => 'assistant',
        // system 은 위(strays)에서 머리로 올렸다 — 대화 중간에 다시 넣지 않는다.
        MessageRole.system => null,
        _ => null,
      };
      if (role == null) continue;
      // 멀티모달이 켜져 있고 사용자 메시지에 이미지가 있으면 content 를
      // OpenAI 멀티모달 배열(text + image_url)로 구성한다.
      final images =
          (multimodal && m.role == MessageRole.user) ? _imagesFromMeta(m.metadata) : const [];
      if (images.isNotEmpty) {
        final parts = <Map<String, Object?>>[
          if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
          for (final img in images)
            {
              'type': 'image_url',
              'image_url': {'url': img['url']},
            },
        ];
        messages.add({'role': role, 'content': parts});
      } else {
        // 어시스턴트가 이 턴 요약을 달아 뒀으면, 컨텍스트에는 사용자용 본문 대신
        // 요약을 넣어 재전송량을 줄인다(요약엔 이어가기에 필요한 핵심만 담김).
        // 단, 직전 1턴(가장 최근 어시스턴트 메시지)은 원문을 그대로 유지한다.
        final useSummary =
            m.role == MessageRole.assistant && idx != lastAssistantIdx;
        final turnSummary = useSummary ? _summaryFromMeta(m.metadata) : '';
        var ctx =
            turnSummary.isNotEmpty ? turnSummary : stripTurnSummary(m.content);
        // 위임한 턴은 본문이 비어 컨텍스트에서 사라진다 — **위임했다는 사실**을
        // 마커로 대신 남긴다(결과 원문은 넣지 않는다. 내용은 요약이 전달한다).
        // 마커 형식은 시스템 프롬프트(kDelegationMarkerNote)에 설명돼 있다.
        final delegations = _delegationsFromMeta(m.metadata);
        if (delegations.isNotEmpty) {
          final lines = delegations.join('\n');
          ctx = ctx.isEmpty ? lines : '$ctx\n$lines';
        }
        if (ctx.isNotEmpty) messages.add({'role': role, 'content': ctx});
      }
    }
    return messages;
  }

  /// 도구 한 건 실행: 화면 표시(running→done) + DB 기록 + 컨텍스트에 결과 추가.
  /// 네이티브 도구(run_subagent/verify_work)는 서브 LLM 으로, 계획 도구는
  /// PLAYBOOK 으로 간다(둘 다 파이썬을 거치지 않는다).
  ///
  /// 감독자가 켜져 있으면 이 호출을 관측하고, 정체로 판단되면 [Intervention] 을
  /// 돌려준다 — 실제 주입은 호출자(`_generate`)가 한다.
  Future<Intervention?> _runToolCall(
    ConversationStore store,
    int convId,
    ToolRegistry? registry,
    String? workspace,
    List<Map<String, Object?>> messages,
    int attempt,
    int iter,
    ToolCall c,
    int? assistantMessageId,
  ) async {
    final tid = '${convId}_${attempt}_${iter}_${c.id}';
    _post({
      'type': 'chat.tool',
      'tid': tid,
      'name': c.name,
      'args': c.arguments,
      'status': 'running',
    });
    Map<String, Object?> argMap;
    try {
      argMap = (jsonDecode(c.arguments.isEmpty ? '{}' : c.arguments) as Map)
          .cast<String, Object?>();
    } catch (_) {
      argMap = {};
    }

    String resultStr;
    bool ok;
    String summary;
    String? diff;
    String? path;
    // 감독자 관측치. **진전**은 파일·계획이 실제로 바뀐 것만 센다(읽기·검색은 아니다).
    var progress = false;
    var errorSig = '';
    final changesBefore = _fileChangeSeq;
    // 호출 내역(네이티브 창)에 남길 기록. 결과 원문은 아래에서 채운다.
    final logRec = toolCalls.start(
      id: tid,
      scope: _nativeToolNames.contains(c.name) ? 'delegate' : 'main',
      name: c.name,
      args: c.arguments,
    );
    if (_planToolNames.contains(c.name)) {
      _status('Plan: ${c.name}…');
      final res = await _runPlanTool(c.name, argMap);
      ok = res.ok;
      resultStr = res.result;
      summary = res.summary;
      // 계획을 실제로 고쳤으면 진전이다 — 방향을 바꾸는 것도 전진이기 때문이다.
      progress = res.ok;
      if (!res.ok) errorSig = errorSignature(res.summary);
    } else if (_nativeToolNames.contains(c.name)) {
      final verify = c.name == 'verify_work';
      _status(verify ? 'Sub-agent: verifying…' : 'Sub-agent: working…');
      final prompt = (argMap['prompt'] as String?) ?? '';
      // 도구별 지정 프리셋 → (없으면) 지금 이 프로젝트의 대화 모델 → 기본 프리셋.
      final subCfg = _workspace.configForTool(c.name);
      final text = await _runSubAgent(store, convId, subCfg, registry,
          workspace, prompt, verify, c.name, tid, assistantMessageId);
      ok = true;
      // **위임 결과임을 표시한다.** 다른 도구 결과와 모양이 같으면 작은 모델이
      // "내가 직접 한 작업" 으로 오해하기 쉽다. 시스템 프롬프트가 이 키를 설명한다.
      resultStr = jsonEncode({
        'ok': true,
        'delegated_to': verify ? 'verification sub-agent' : 'sub-agent',
        'result': text,
      });
      summary = _snippet(text);
      // 다음 턴을 위해 **위임했다는 사실만** 남긴다(결과 원문은 넣지 않는다 —
      // 길어서 컨텍스트를 갉아먹는다. 내용은 턴 요약이 전달한다).
      if (assistantMessageId != null) {
        await store.addMessageDelegation(
          assistantMessageId,
          tool: c.name,
          task: _clip(prompt, 160),
        );
      }
      // 위임은 그 자체로는 진전이 아니다 — **서브에이전트가 실제로 무언가를 바꿨을
      // 때만** 진전으로 센다. 같은 프롬프트를 반복 위임하는 것은 반복 탐지가 잡는다.
      progress = _fileChangeSeq != changesBefore;
    } else {
      _status('Tool: ${c.name}…');
      final res = registry == null
          ? const ToolCallResult(ok: false, error: 'No tools available')
          : await registry.call(c.name, argMap,
              workspace: workspace, workingDirectory: workspace);
      // 파일을 바꾼 도구면 이력에 남긴다(다음 턴 상태 요약의 재료).
      await _recordFileChange(c.name, argMap, res);
      ok = res.ok;
      resultStr = _toolResultString(res);
      summary = _toolSummary(res);
      progress = res.ok && _fileChangeSeq != changesBefore;
      if (!res.ok) errorSig = errorSignature(res.error ?? res.reason ?? summary);
      // 변경 도구(edit/replace/write/create)의 diff 를 추출해 카드에 표시.
      if (res.ok && res.result is Map) {
        final r = (res.result as Map).cast<String, Object?>();
        if (r['diff'] is String) diff = r['diff'] as String;
        if (r['path'] is String) path = r['path'] as String;
      }
    }

    toolCalls.finish(logRec, ok: ok, result: resultStr, summary: summary);
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.tool,
      content: resultStr,
      toolCallId: c.id,
      toolName: c.name,
    );
    messages.add({'role': 'tool', 'tool_call_id': c.id, 'content': resultStr});
    final donePayload = <String, Object?>{
      'type': 'chat.tool',
      'tid': tid,
      'name': c.name,
      'status': 'done',
      'ok': ok,
      'summary': summary,
    };
    if (diff != null) donePayload['diff'] = diff;
    if (path != null) donePayload['path'] = path;
    _post(donePayload);

    return _supervisor?.observe(StepObs(
      tool: c.name,
      args: c.arguments,
      errorSig: errorSig,
      progress: progress,
    ));
  }

  /// 감독자 개입을 대화에 알리고, 모델에 주입할 user 메시지를 [messages] 에 넣는다.
  ///
  /// **왜 user 인가**: 대화 중간의 system 은 로컬 템플릿이 거부한다
  /// (§`message_shape.dart`). 도구 결과 뒤에 user 를 붙이는 것은 규격에 맞는다.
  /// 화면에는 한 줄만 남긴다 — 모델이 갑자기 방향을 바꾸는 이유가 보이지 않으면
  /// 사용자는 그걸 오작동으로 읽는다.
  void _applyIntervention(
      List<Map<String, Object?>> messages, Intervention iv) {
    messages.add({'role': 'user', 'content': iv.message});
    _post({
      'type': 'chat.supervisor',
      'action': iv.action,
      'level': iv.level,
      'reason': iv.reason,
      'message': iv.message,
      'halt': iv.halt,
    });
  }

  /// 서브 LLM 분기: 별도 컨텍스트로 프롬프트를 처리한다(메인 대화창에 미표시).
  /// 파이썬 도구는 쓸 수 있으나 네이티브(서브에이전트) 도구는 제외해 재귀를 막는다.
  /// 내부 도구 호출은 호출 내역(chat.activity)에만 기록한다.
  Future<String> _runSubAgent(
    ConversationStore store,
    int parentConvId,
    LlmConfig cfg,
    ToolRegistry? registry,
    String? workspace,
    String prompt,
    bool verify,
    String toolName,
    String tid,
    int? parentMessageId,
  ) async {
    if (prompt.trim().isEmpty) return '(empty prompt)';
    // 부모 도구 버블(tid)을 클릭하면 볼 수 있는 실시간 전사(transcript)용 식별자.
    final parentTid = tid;
    // 이 도구가 실제로 쓰는 프리셋(도구별 지정 → 프로젝트 대화 모델 → 기본).
    final presetId = _workspace.resolvedPresetIdForTool(toolName);
    // 위임 도구(run_subagent/verify_work)는 빼서 재귀를 막고, 계획 도구는
    // `note_write` 하나만 준다(§_subPlanToolNames — 계획의 주인은 메인이다).
    final subTools = <Map<String, Object?>>[
      ...?registry?.openAiTools,
      if (_playbook != null) ..._subPlanTools,
    ];
    // 이 서브에이전트만의 감독자. 마지막 단계는 "사용자에게 묻기" 가 아니라
    // **부모에게 보고하기** 다 — 서브에이전트 앞에는 사용자가 없다.
    final subSup = Supervisor.forSubAgent(enabled: _workspace.supervisor);
    final procCtx = _runningProcessContext();
    // 서브에이전트는 매번 빈 컨텍스트로 시작한다 — 이미 만들어 둔 파일을 다시
    // 만들거나 같은 조사를 반복하지 않도록 프로젝트 상태를 함께 넣어 준다.
    final stateCtx = await _projectStateContext();
    // 최근 사용자 메시지의 첨부를 서브 컨텍스트에 동반한다:
    // 경로 목록(모든 종류 — 도구로 읽기 가능) + 멀티모달이면 이미지 인라인.
    final atts = await _latestUserAttachments(store, parentConvId);
    final attCtx = _attachmentContext(atts);
    final imageParts = <Map<String, Object?>>[
      if (cfg.multimodal)
        for (final a in atts)
          if (a['url'] is String && (a['url'] as String).startsWith('data:image'))
            {
              'type': 'image_url',
              'image_url': {'url': a['url']},
            },
    ];
    final subMessages = <Map<String, Object?>>[
      // 여기도 system 을 여러 개 쌓지 않는다(§systemHead — 로컬 템플릿이 거부한다).
      ...systemHead([
        verify ? _verifySystemFor(registry) : _subAgentSystemFor(registry),
        // 서브에이전트는 매번 빈 컨텍스트로 시작하므로 계획이 **여기서 더 중요하다**.
        if (_playbook != null) kSubAgentPlanningNote,
        _planContext(forSubAgent: true),
        stateCtx,
        procCtx,
        attCtx,
      ]),
      if (imageParts.isEmpty)
        {'role': 'user', 'content': prompt}
      else
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            ...imageParts,
          ],
        },
    ];

    var finalText = '';
    var sub = 0;
    var subTokens = 0; // 이 서브에이전트가 쓴 총 토큰(여러 턴 합)

    // 부모 도구 버블(tid)에 실시간 진행(경과/토큰)을 갱신해 표시한다.
    final subStart = DateTime.now();
    var lastEmit = subStart;
    void emitProgress(int curChars) {
      final now = DateTime.now();
      if (now.difference(lastEmit).inMilliseconds < 300) return;
      lastEmit = now;
      final ms = now.difference(subStart).inMilliseconds;
      final approx = subTokens + (curChars / 4).round();
      _post({
        'type': 'chat.tool',
        'tid': tid,
        'name': toolName,
        'status': 'running',
        'args': '${(ms / 1000).toStringAsFixed(1)}s · ~$approx tok',
      });
    }

    // 서브에이전트의 작업 지시(프롬프트)를 전사 시작으로 보낸다.
    _post({'type': 'chat.sub', 'tid': parentTid, 'prompt': prompt});

    // 무응답(멈춤) 중에도 살아있음을 보이도록 1초마다 경과 시간을 버블/전사에 갱신.
    // (응답이 오기 시작하면 emitProgress 가 토큰 수까지 표시한다.)
    final heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = DateTime.now().difference(subStart).inSeconds;
      _post({
        'type': 'chat.tool', 'tid': tid, 'name': toolName,
        'status': 'running', 'args': '${s}s',
      });
      _post({'type': 'chat.sub', 'tid': parentTid, 'wait': s});
    });

    try {
      for (var iter = 0; iter < _maxSubIterations; iter++) {
        if (_cancelRequested) throw const _GenerationStopped();
        if (iter > 0) {
          _post({'type': 'chat.sub', 'tid': parentTid, 'turn': true});
        }
        final turn = await _withLlmRetry(
          () => _runSubModelTurn(cfg, presetId, subMessages, subTools,
              onContent: emitProgress,
              onDelta: (t) =>
                  _post({'type': 'chat.sub', 'tid': parentTid, 'delta': t}),
              onReasoning: (t) =>
                  _post({'type': 'chat.sub', 'tid': parentTid, 'reasoning': t})),
          reason: 'Sub-agent connection issue',
        );
        finalText = turn.content;
        subTokens += turn.totalTokens;
        emitProgress(0);
        if (turn.toolCalls.isEmpty) break;
        subMessages.add({
          'role': 'assistant',
          'content': turn.content.isEmpty ? null : turn.content,
          'tool_calls': [
            for (final c in turn.toolCalls)
              {
                'id': c.id,
                'type': 'function',
                'function': {'name': c.name, 'arguments': c.arguments},
              },
          ],
        });
        Intervention? iv;
        final changesBeforeRound = _fileChangeSeq;
        for (final c in turn.toolCalls) {
          // 중지를 눌렀으면 남은 도구 호출은 시작하지 않는다(빠른 중지).
          if (_cancelRequested) throw const _GenerationStopped();
          final tid = 'sub_${parentConvId}_${sub++}_${c.id}';
          // 호출 내역(네이티브 창)에도 남긴다. 실제 파일 작업 대부분이 여기라
          // 결과 원문을 볼 수 있어야 하는 곳도 사실상 여기다.
          final logRec = toolCalls.start(
            id: tid,
            scope: verify ? 'verify' : 'subagent',
            name: c.name,
            args: c.arguments,
          );
          _post({
            'type': 'chat.activity',
            'tid': tid,
            'name': c.name,
            'args': c.arguments,
            'status': 'running',
          });
          Map<String, Object?> argMap;
          try {
            argMap = (jsonDecode(c.arguments.isEmpty ? '{}' : c.arguments) as Map)
                .cast<String, Object?>();
          } catch (_) {
            argMap = {};
          }
          final bool subOk;
          final String subResultStr;
          final String subSummary;
          var subProgress = false;
          var subErrorSig = '';
          if (_planToolNames.contains(c.name)) {
            // 계획 도구(= note_write)는 PLAYBOOK 으로 간다. 파이썬을 거치지 않는다.
            final r = await _runPlanTool(c.name, argMap);
            subOk = r.ok;
            subResultStr = r.result;
            subSummary = r.summary;
            subProgress = r.ok;
            if (!r.ok) subErrorSig = errorSignature(r.summary);
          } else {
            final res = registry == null
                ? const ToolCallResult(ok: false, error: 'No tools available')
                : await registry.call(c.name, argMap,
                    workspace: workspace, workingDirectory: workspace);
            // 실제 파일 작업은 대부분 여기(서브에이전트)서 일어난다 — 반드시 기록.
            await _recordFileChange(c.name, argMap, res);
            subOk = res.ok;
            subResultStr = _toolResultString(res);
            subSummary = _toolSummary(res);
            subProgress = res.ok && _fileChangeSeq != changesBeforeRound;
            if (!res.ok) {
              subErrorSig = errorSignature(res.error ?? res.reason ?? subSummary);
            }
          }
          toolCalls.finish(logRec,
              ok: subOk, result: subResultStr, summary: subSummary);
          subMessages.add({
            'role': 'tool',
            'tool_call_id': c.id,
            'content': subResultStr,
          });
          _post({
            'type': 'chat.activity',
            'tid': tid,
            'name': c.name,
            'status': 'done',
            'ok': subOk,
            'summary': subSummary,
          });
          // 실시간 전사에도 이 도구 호출/결과를 한 줄로 남긴다.
          _post({
            'type': 'chat.sub',
            'tid': parentTid,
            'role': 'tool',
            'name': c.name,
            'ok': subOk,
            'summary': subSummary,
          });
          iv = subSup.observe(StepObs(
                tool: c.name,
                args: c.arguments,
                errorSig: subErrorSig,
                progress: subProgress,
              )) ??
              iv;
        }
        iv ??=
            subSup.roundDone(progress: _fileChangeSeq != changesBeforeRound);
        if (iv != null) {
          // 서브에이전트의 개입은 대화창에 카드로 남기지 않는다 — 전사(chat.sub)에만
          // 한 줄 남긴다. 메인 대화에 서브의 내부 사정을 흘리지 않는다는 기존 원칙 그대로.
          subMessages.add({'role': 'user', 'content': iv.message});
          _post({
            'type': 'chat.sub',
            'tid': parentTid,
            'role': 'supervisor',
            'name': iv.action,
            'summary': iv.reason,
          });
          if (iv.halt) {
            // 도구를 거두고 한 번만 더 돌려 **부모에게 보고**하게 한다.
            final closing = await _withLlmRetry(
              () => _runSubModelTurn(cfg, presetId, subMessages, null,
                  onContent: emitProgress,
                  onDelta: (t) =>
                      _post({'type': 'chat.sub', 'tid': parentTid, 'delta': t})),
              reason: 'Sub-agent connection issue',
            );
            finalText = closing.content;
            subTokens += closing.totalTokens;
            break;
          }
        }
      }
    } on _GenerationStopped {
      // 중지는 "서브에이전트 실패" 가 아니다. 여기서 문자열로 바꿔 돌려주면 부모
      // 루프가 정상 결과로 알고 **남은 도구 호출을 계속 실행**한다 → 중지가 늦어진다.
      heartbeat.cancel();
      rethrow;
    } catch (e) {
      return 'sub-agent error: $e';
    } finally {
      heartbeat.cancel();
    }

    // 하위 컨텍스트로 기록(메인 대화에는 미표시). 분기 원점 메시지(parent_message_id)
    // 를 같이 남겨, 그 메시지가 삭제되면 이 기록도 함께 정리되게 한다.
    try {
      final subConvId = await store.createSubConversation(
        parentConversationId: parentConvId,
        parentMessageId: parentMessageId,
        title: verify ? 'verify' : 'subagent',
      );
      await store.addMessage(
          conversationId: subConvId, role: MessageRole.user, content: prompt);
      await store.addMessage(
        conversationId: subConvId,
        role: MessageRole.assistant,
        content: finalText,
        model: cfg.model,
        provider: cfg.connection.name,
        api: 'chat/completions',
        pipeline: verify ? 'verify' : 'subagent',
        metadata: subTokens > 0
            ? jsonEncode({'usage': {'total': subTokens}})
            : null,
      );
    } catch (_) {}

    return finalText.isEmpty ? '(no result)' : finalText;
  }

  // ===== 턴 요약 (답변 확정 후 백그라운드 별도 호출) =====

  static const String _turnSummarySystem =
      'You compress ONE turn of an AI coding session into a compact note that a '
      'later turn will use INSTEAD of the full reply. Keep only what is needed '
      'to continue: key decisions, files/commands changed, important results, '
      'and open threads. Output ONLY the note — no preamble, no headings, a few '
      'sentences at most.';

  /// 요약을 만들 만한 턴인지. 도구를 쓰지 않았고 답변도 짧으면 원문이 이미
  /// 충분히 작으므로 호출을 아낀다.
  static const int _summarizeMinChars = 400;

  /// 진행 중인 백그라운드 턴 요약. 다음 턴 컨텍스트를 만들기 전에 기다린다.
  final List<Future<void>> _pendingSummaries = [];

  /// 사용자가 "건너뛰기" 를 누르면 완료되어 대기를 끊는다.
  Completer<void>? _summarySkip;

  /// 답변을 확정한 뒤 턴 요약을 **백그라운드로** 만든다(사용자 대기 없음).
  ///
  /// 요약은 이 턴이 아니라 **다음 턴 컨텍스트**에서 처음 쓰이므로 늦어도 된다.
  /// 응답 스트림에 섞지 않으니 본문이 오염될 수 없다(예전 `<turn_summary>` 마커
  /// 방식의 근본 문제였다).
  void _scheduleTurnSummary(ConversationStore store, int messageId,
      String answer, List<String> toolsUsed, String userRequest) {
    if (toolsUsed.isEmpty && answer.length < _summarizeMinChars) return;
    if (answer.trim().isEmpty && toolsUsed.isEmpty) return;
    // Completer 로 등록해 두고 작업이 끝나면 스스로 빠진다(자기 Future 를 참조하는
    // late 변수보다 초기화 순서가 안전하다).
    final done = Completer<void>();
    _pendingSummaries.add(done.future);
    unawaited(() async {
      try {
        final buf = StringBuffer();
        if (userRequest.isNotEmpty) buf.writeln('[request] $userRequest');
        if (toolsUsed.isNotEmpty) {
          buf.writeln('[tools used] ${toolsUsed.join(', ')}');
        }
        buf.writeln('[reply]\n$answer');
        final turn = await _runSubModelTurn(
          _workspace.configForConversation(),
          _workspace.resolvedPresetIdForConversation(),
          [
            {'role': 'system', 'content': _turnSummarySystem},
            {'role': 'user', 'content': buf.toString()},
          ],
          null,
        );
        final text = turn.content.trim();
        // 메시지가 이미 지워졌으면(사용자가 그 위를 수정) store 가 무시한다.
        if (text.isNotEmpty) await store.updateMessageSummary(messageId, text);
      } catch (_) {
        // 요약 실패는 무시한다 — 다음 턴은 원문을 컨텍스트로 쓰면 된다.
      } finally {
        _pendingSummaries.remove(done.future);
        if (!done.isCompleted) done.complete();
      }
    }());
  }

  /// 진행 중인 턴 요약이 있으면 끝날 때까지 기다린다.
  ///
  /// 답변 직후 사용자가 바로 다음 요청을 보내면(특히 위 메시지를 고쳐 다시 진행)
  /// 요약이 아직 안 끝났을 수 있다. 그때만 상태 풍선에 "요약 중"을 띄우고,
  /// 사용자가 **건너뛰기**로 대기를 끊을 수 있게 한다(요약 자체는 계속 돌아
  /// 다음다음 턴에서 쓰인다).
  Future<void> _awaitTurnSummaries() async {
    if (_pendingSummaries.isEmpty) return;
    final skip = Completer<void>();
    _summarySkip = skip;
    _status('Summarizing previous turn…', skippable: true);
    try {
      await Future.any([
        Future.wait(List<Future<void>>.from(_pendingSummaries)),
        skip.future,
      ]);
    } catch (_) {
      // 개별 요약 실패는 이미 내부에서 삼킨다.
    } finally {
      _summarySkip = null;
    }
  }

  /// 웹의 "건너뛰기" — 요약 대기를 즉시 끝낸다.
  void _handleSummarySkip() {
    final skip = _summarySkip;
    if (skip != null && !skip.isCompleted) skip.complete();
  }

  /// 가장 최근 사용자 메시지 본문(없으면 '').
  Future<String> _lastUserRequest(ConversationStore store, int convId) async {
    for (final m in (await store.messages(convId)).reversed) {
      if (m.role == MessageRole.user && m.content.trim().isNotEmpty) {
        return m.content;
      }
    }
    return '';
  }

  /// 앞에서 [max] 자까지만 남긴다(요약 프롬프트 입력 길이 제한).
  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  // ===== 프로젝트 상태 요약 (폴더 구조 + 파일 변경 이력) =====

  /// 파일을 바꾸는 기본 도구 → 이력에 남길 동작 이름.
  /// 여기 없는 도구(읽기/검색/명령)는 기록하지 않는다.
  static const Map<String, String> _mutatingTools = {
    'create_file': 'created',
    'create_directory': 'created',
    'write_file': 'modified',
    'edit_file': 'modified',
    'replace_lines': 'modified',
    'delete_path': 'deleted',
    'move_path': 'moved',
  };

  /// 상태 요약 전체 길이 상한(문자). 넘으면 잘라서 붙인다.
  static const int _maxStateChars = 1800;

  /// 상태 요약에 넣을 최근 변경 파일 수.
  static const int _maxStateChanges = 25;

  /// 폴더 구조 스캔 캐시 TTL. 변경 이력은 DB 에서 매번 새로 읽고(싸다),
  /// 디스크를 걷는 구조 스캔만 잠깐 재사용한다(한 턴에 서브에이전트가 여러 번
  /// 호출돼도 같은 스캔을 반복하지 않게).
  static const Duration _outlineTtl = Duration(seconds: 20);

  List<String>? _outlineCache;
  DateTime? _outlineAt;

  /// 도구 실행 결과에서 바뀐 경로를 뽑아 대화 DB 에 기록한다.
  ///
  /// 도구를 거쳐야만 파일이 바뀌므로(시스템 프롬프트 규칙) 이 지점이 가장 정확하다.
  /// 기록 실패가 대화를 막지 않도록 예외는 삼킨다.
  Future<void> _recordFileChange(
      String toolName, Map<String, Object?> args, ToolCallResult res) async {
    final action = _mutatingTools[toolName];
    if (action == null || !res.ok) return;
    final store = _store;
    if (store == null) return;
    final r = res.result is Map
        ? (res.result as Map).cast<String, Object?>()
        : const <String, Object?>{};
    // move_path 는 dst/src, 나머지는 path. 결과에 없으면 인자에서 찾는다.
    final raw = (r['dst'] ?? r['path'] ?? args['dst'] ?? args['path']);
    if (raw is! String || raw.isEmpty) return;
    try {
      await store.recordFileChange(
          path: _relPath(raw), action: action, tool: toolName);
      // 감독자의 "진전" 판정 재료. 위임(run_subagent)이 실제로 무언가를 바꿨는지는
      // 이 값이 호출 전후로 움직였는지로 본다 — 서브에이전트 안에서도 같은 함수를
      // 지나므로 한 곳만 세면 된다.
      _fileChangeSeq++;
      if (toolName == 'move_path') {
        // 원본 경로는 사라졌다는 사실도 남긴다.
        final src = (r['src'] ?? args['src']);
        if (src is String && src.isNotEmpty) {
          await store.recordFileChange(
              path: _relPath(src), action: 'moved', tool: toolName);
        }
      }
    } catch (_) {
      // 이력은 부가 정보다 — 실패해도 작업 자체는 계속한다.
    }
  }

  /// 프로젝트 루트 기준 상대 경로(밖이거나 실패하면 원래 경로).
  String _relPath(String path) {
    final root = _workspace.projectPath;
    if (root == null || root.isEmpty) return path;
    try {
      if (!p.isWithin(root, path)) return path;
      // 윈도우 구분자는 '/' 로 통일 — 같은 파일이 두 행으로 갈리지 않게.
      return p.relative(path, from: root).replaceAll('\\', '/');
    } catch (_) {
      return path;
    }
  }

  /// 에이전트에 주입할 프로젝트 상태 요약(끔/프로젝트 없음이면 null).
  ///
  /// 이미 만들어 둔 파일을 다시 만들거나 같은 조사를 반복하지 않도록,
  /// **현재 폴더 구조 + 이 프로젝트에서 도구가 바꾼 파일 목록**을 알려 준다.
  /// 길이는 [_maxStateChars] 로 제한한다.
  Future<String?> _projectStateContext() async {
    if (!_workspace.projectState) return null;
    final root = _workspace.projectPath;
    if (root == null || root.isEmpty) return null;

    final buf = StringBuffer(
      'Current project state (auto-generated; use it to avoid redoing work '
      'that is already done).\n',
    );

    // 1) 폴더 구조 — 디스크를 직접 보므로 IDE 밖 변경도 반영된다(짧은 TTL 캐시).
    final now = DateTime.now();
    if (_outlineCache == null ||
        _outlineAt == null ||
        now.difference(_outlineAt!) > _outlineTtl) {
      try {
        _outlineCache = await _fs.outline(root);
        _outlineAt = now;
      } catch (_) {
        _outlineCache = const [];
        _outlineAt = now;
      }
    }
    final outline = _outlineCache ?? const <String>[];
    if (outline.isNotEmpty) {
      buf.writeln('\n[Folders]');
      for (final line in outline) {
        buf.writeln(line);
      }
    }

    // 2) 이 프로젝트에서 도구가 바꾼 파일(대화 DB 기록 — 정확).
    final store = _store;
    if (store != null) {
      List<FileChange> changes = const [];
      try {
        changes = await store.recentFileChanges(limit: _maxStateChanges);
      } catch (_) {}
      if (changes.isNotEmpty) {
        buf.writeln('\n[Files already changed by tools in this project]');
        for (final c in changes) {
          final n = c.edits > 1 ? ' x${c.edits}' : '';
          buf.writeln('${c.action}: ${c.path}$n');
        }
        buf.writeln(
          'Do NOT recreate or re-investigate these from scratch — read the '
          'current file if you need its contents.',
        );
      }
    }

    var text = buf.toString().trimRight();
    if (text.length > _maxStateChars) {
      text = '${text.substring(0, _maxStateChars)}\n… (state truncated)';
    }
    return text;
  }

  // ======================================================= 계획 메모리(하니스)

  /// 계획 메모리를 디스크에서 다시 읽는다(꺼져 있거나 프로젝트가 없으면 null).
  ///
  /// **매 생성마다 다시 읽는 것이 중요하다** — 파일이 정본이고, 사용자가 에디터에서
  /// 직접 고쳤을 수 있다(그러라고 파일로 뒀다).
  Future<Playbook?> _reloadPlaybook() async {
    final root = _workspace.projectPath;
    if (!_workspace.planMemory || root == null || root.isEmpty) {
      _playbook = null;
      return null;
    }
    final pb = Playbook.forProject(root);
    await pb.load();
    _playbook = pb;
    return pb;
  }

  /// 계획 카드(웹)를 갱신한다. 계획 메모리가 꺼져 있으면 빈 것을 보내 카드를 감춘다.
  ///
  /// `path` 는 **파일이 실제로 있을 때만** 실린다 — 트리 헤더의 "계획 파일 열기"
  /// 버튼이 이걸 보고 나타난다. 내용 유무(`plan`)와 별개다: `.collabo` 안에만 생기는
  /// 파일이라 사용자가 존재 자체를 모르고 지나치는 게 이 버튼을 단 이유다.
  void _pushPlan() {
    final pb = _playbook;
    _post({
      'type': 'chat.plan',
      'plan': pb == null || pb.isEmpty ? null : pb.toJson(),
      'path': pb != null && pb.fileExists ? pb.path : null,
    });
  }

  /// 매 턴 컨텍스트에 고정할 계획 블록(비었으면 null).
  ///
  /// 메인은 `_buildContextMessages`, 서브에이전트는 `_runSubAgent` 가 이걸 쓴다.
  /// 서브에이전트는 **매번 빈 컨텍스트로 시작**하므로 오히려 여기가 더 중요하다.
  String? _planContext({required bool forSubAgent}) {
    final digest = _playbook?.digest();
    if (digest == null) return null;
    final head = forSubAgent
        ? 'The main agent is working to this plan. Your task is one part of it. '
            'Do not restate or rewrite the plan — if you learn something worth '
            'keeping, record it with `note_write`.'
        : 'Your goal and plan for this task (file: $kPlaybookPath — it survives '
            'summarisation, so trust it over your memory of earlier turns). '
            'Keep it current with `update_plan` as you go.';
    return '$head\n\n$digest';
  }

  /// 계획 도구 한 건 실행(네이티브 — 파이썬으로 가지 않는다).
  Future<({bool ok, String result, String summary})> _runPlanTool(
      String name, Map<String, Object?> args) async {
    final pb = _playbook;
    if (pb == null) {
      return (
        ok: false,
        result: jsonEncode({'ok': false, 'error': 'Plan memory is off.'}),
        summary: 'plan memory off',
      );
    }
    try {
      switch (name) {
        case 'set_goal':
          final goal = (args['goal'] as String?)?.trim() ?? '';
          if (goal.isEmpty) {
            return _planErr('`goal` is required (one sentence).');
          }
          await pb.setGoal(goal);
          final steps = _asStringList(args['steps']);
          if (steps.isNotEmpty) await pb.setPlan(steps);
          _pushPlan();
          // 결과에 파일 경로를 같이 준다 — "정말 파일로 떨어졌나" 를 도구 카드와
          // 호출 내역에서 바로 확인할 수 있게(쓰기 실패는 아래 catch 가 잡는다).
          return _planOk(
            {
              'goal': pb.goalText,
              'steps': pb.openSteps.length,
              'file': kPlaybookPath,
            },
            'goal set${steps.isEmpty ? '' : ' · ${steps.length} steps'}',
          );

        case 'update_plan':
          final steps = _asStringList(args['steps']);
          if (steps.isNotEmpty) {
            await pb.setPlan(steps);
            _pushPlan();
            return _planOk({'steps': steps.length}, '${steps.length} steps');
          }
          final ref = (args['step'] ?? args['ref'] ?? '').toString().trim();
          if (ref.isEmpty) {
            return _planErr(
                'Give either `steps` (replace the plan) or `step` + `status`.');
          }
          final item = await pb.updateStep(
            ref,
            (args['status'] as String?) ?? 'DONE',
            note: (args['note'] as String?) ?? '',
          );
          if (item == null) {
            return _planErr(
                'No plan step matches "$ref". Current steps: ${pb.openSteps}');
          }
          _pushPlan();
          return _planOk(
            {'step': item.text, 'status': item.marker, 'open': pb.openSteps},
            '${item.marker}: ${_clip(item.text, 40)}',
          );

        case 'note_write':
          final text = (args['text'] as String?)?.trim() ?? '';
          if (text.isEmpty) return _planErr('`text` is required (one line).');
          final item = await pb.note(
            (args['section'] as String?) ?? 'working_model',
            text,
            marker: (args['marker'] as String?) ?? '',
          );
          if (item == null) return _planErr('Nothing to record.');
          _pushPlan();
          return _planOk(
            {'marker': item.marker, 'text': item.text},
            '[${item.marker}] ${_clip(item.text, 40)}',
          );
      }
    } catch (e) {
      return _planErr('$e');
    }
    return _planErr('Unknown plan tool: $name');
  }

  ({bool ok, String result, String summary}) _planOk(
          Map<String, Object?> result, String summary) =>
      (ok: true, result: jsonEncode({'ok': true, 'result': result}), summary: summary);

  ({bool ok, String result, String summary}) _planErr(String error) =>
      (ok: false, result: jsonEncode({'ok': false, 'error': error}), summary: error);

  /// 배열 인자를 관대하게 읽는다 — 모델이 JSON 문자열이나 문자열 하나로 보내는 일이
  /// 잦다(§note 2026-08-14 "문자열로 보내는 모델 받아 주기" 와 같은 노선).
  List<String> _asStringList(Object? raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return [
        for (final e in raw)
          if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
      ];
    }
    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return const [];
      if (s.startsWith('[')) {
        try {
          return _asStringList(jsonDecode(s));
        } catch (_) {
          // 배열처럼 생겼지만 JSON 이 아니면 아래 줄 단위 해석으로 떨어진다.
        }
      }
      // 줄바꿈으로 나눠 온 경우도 받는다(한 줄이면 항목 하나).
      return [
        for (final line in s.split('\n'))
          if (line.trim().isNotEmpty)
            line.trim().replaceFirst(RegExp(r'^\s*(?:[-*]|\d+[.)])\s*'), ''),
      ];
    }
    return const [];
  }

  /// 부모 대화에서 **가장 최근 사용자 메시지**의 첨부 목록을 꺼낸다.
  /// (현재 작업의 근거가 되는 첨부만 동반 — 과거 턴의 첨부는 제외.)
  Future<List<Map<String, Object?>>> _latestUserAttachments(
      ConversationStore store, int convId) async {
    for (final m in (await store.messages(convId)).reversed) {
      if (m.role != MessageRole.user) continue;
      return _attachmentsFromMeta(m.metadata);
    }
    return const [];
  }

  /// 첨부 목록을 서브에이전트용 컨텍스트 문구로 만든다(없으면 null).
  /// 종류(kind)에 무관하게 경로를 알려 도구로 읽게 한다 — 이미지 외 형식도
  /// 같은 레코드로 확장된다.
  String? _attachmentContext(List<Map<String, Object?>> atts) {
    if (atts.isEmpty) return null;
    final lines = atts.map((a) {
      final kind = (a['kind'] as String?) ?? 'file';
      final name = (a['name'] as String?) ?? '';
      final path = (a['path'] as String?) ?? '';
      return '- [$kind] $name${path.isEmpty ? ' (inline only)' : ' — $path'}';
    }).join('\n');
    return 'The user attached the following file(s) for this task. Saved '
        'copies live inside the workspace (under .collabo/attach), so you can '
        'read them with the file tools:\n$lines';
  }

  /// 현재 실행 중인 백그라운드 명령 목록을 서브에이전트에게 줄 컨텍스트
  /// 문구로 만든다(없으면 null). 중복 실행을 막고, 기존 명령을 run_wait/
  /// check_command 로 이어받을 수 있게 한다.
  String? _runningProcessContext() {
    final reg = _workspace.backgroundProcesses..refresh();
    final running = reg.processes.where((e) => e.isRunning).toList();
    if (running.isEmpty) return null;
    final now = DateTime.now();
    final lines = running.map((e) {
      final dur = e.startedAt == null
          ? ''
          : ' (running ${now.difference(e.startedAt!).inSeconds}s)';
      var cmd = e.command.replaceAll('\n', ' ');
      if (cmd.length > 200) cmd = '${cmd.substring(0, 200)}…';
      return '- id=${e.id}$dur: $cmd';
    }).join('\n');
    return 'Background commands currently RUNNING in this workspace:\n$lines\n'
        'Use check_command or run_wait with an id to inspect/wait on one, and '
        'stop_command only if you decide it must be terminated. Do NOT start a '
        'duplicate command if a running one already covers the same task.';
  }

  /// 서브 LLM 한 턴(조용히 스트리밍, 화면 표시 없음).
  /// 내용 + 도구 호출 + 이 호출의 총 토큰(usage)을 반환.
  Future<({String content, List<ToolCall> toolCalls, int totalTokens})>
      _runSubModelTurn(
    LlmConfig cfg,
    String presetId,
    List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools, {
    void Function(int chars)? onContent,
    void Function(String text)? onDelta,
    void Function(String text)? onReasoning,
  }) async {
    // 보내는 모양은 **가장 엄격한 템플릿 기준**을 지킨다(§message_shape.dart).
    // 릴리스에서는 제거되므로, 규칙을 어기는 조합은 개발/테스트에서 잡힌다.
    assert(chatShapeProblem(messages) == null,
        'bad chat shape: ${chatShapeProblem(messages)}');
    final content = StringBuffer();
    var reasoningLen = 0;
    var toolCalls = const <ToolCall>[];
    var totalTokens = 0;
    await for (final ev in _withResponseTimeout(
        _providerFor(cfg).streamChat(cfg: cfg, messages: messages, tools: tools),
        cfg,
        presetId)) {
      switch (ev) {
        case LlmContent(:final text):
          content.write(text);
          onContent?.call(content.length + reasoningLen);
          onDelta?.call(text);
        case LlmReasoning(:final text):
          // reasoning(사고) 토큰도 진행/전사에 반영한다(이게 와도 멈춤 아님).
          reasoningLen += text.length;
          onContent?.call(content.length + reasoningLen);
          onReasoning?.call(text);
        case LlmToolCalls(:final calls):
          toolCalls = calls;
        case LlmUsage():
          totalTokens = ev.total;
      }
    }
    return (content: content.toString(), toolCalls: toolCalls, totalTokens: totalTokens);
  }

  // ===== 상태 풍선 / 재시도 (타임아웃·백오프) =====

  /// 진행 상태를 대화창 풍선으로 표시한다(빈 문자열이면 제거). 작업이 끝나면 지운다.
  /// [skippable] 이면 풍선에 "건너뛰기" 버튼이 붙는다(턴 요약 대기 전용).
  void _status(String text, {bool skippable = false}) =>
      _post({'type': 'status', 'text': text, 'skippable': skippable});

  /// 상태 풍선을 지운다. 단, 처리할 큐가 남아 있으면(곧 이어서 생성) 유지한다.
  void _clearStatus() {
    if (_queue.isNotEmpty) return;
    _post({'type': 'status', 'text': ''});
  }

  /// 상태 풍선에 띄울 짧은 오류 문구.
  String _briefErr(Object e) {
    var s = e.toString().replaceAll('\n', ' ').trim();
    if (s.startsWith('Exception: ')) s = s.substring('Exception: '.length);
    return s.length > 80 ? '${s.substring(0, 80)}…' : s;
  }

  /// 재시도 전 2~5초 대기(시도할수록 약간 증가). 매초 상태 풍선을 갱신해
  /// 남은 시간을 보여준다(과도한 즉시 재시도 방지).
  Future<void> _retryDelay(int nextAttempt, int maxAttempts, String reason) async {
    final secs = nextAttempt.clamp(2, 5); // 2~5초
    for (var r = secs; r > 0; r--) {
      if (_cancelRequested) return; // 중지 요청 시 대기 즉시 종료
      _status('$reason — retrying in ${r}s ($nextAttempt/$maxAttempts)');
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  /// LLM 스트림에 **두 단계 시간 상한**을 걸고, 지나가는 김에 **속도를 잰다**.
  ///
  /// 모든 LLM 스트림이 이 한 곳을 지난다(메인·서브·트리아지·요약·압축) — 그래서
  /// 상한도 측정도 여기 한 군데에만 둔다.
  ///
  /// | 단계 | 언제 | 상한 |
  /// |---|---|---|
  /// | 프리필 | 요청 → **첫 이벤트** | `cfg.firstResponseTimeout` (**기본 없음**) |
  /// | 생성 | 첫 이벤트 → 스트림 끝 | `토큰 예산 ÷ 실측 tok/s` (§`stream_budget.dart`) |
  ///
  /// **프리필에는 기본 상한이 없다.** 그 구간에서는 서버가 아무것도 내보내지 않아
  /// "열심히 일하는 중" 과 "죽은 연결" 을 시계로 구분할 수 없다 — 구분도 못 하면서
  /// 멀쩡한 작업을 죽이는 쪽이 훨씬 큰 피해다.
  ///
  /// **생성 상한은 갱신되지 않는다(총량 예산).** 이벤트가 올 때마다 다시 감는
  /// *유휴* 타이머였다면 무한 반복 출력을 영원히 못 잡는다 — 토큰은 계속 오니까.
  /// 총량으로 잡으면 반복은 반드시 걸리고, 정상적으로 느린 작업은 속도에 비례해
  /// 상한이 함께 늘어나므로 걸리지 않는다.
  Stream<LlmEvent> _withResponseTimeout(
      Stream<LlmEvent> source, LlmConfig cfg, String presetId) {
    late StreamController<LlmEvent> ctrl;
    StreamSubscription<LlmEvent>? sub;
    Timer? timer;
    DateTime? firstAt;
    var chars = 0;
    LlmUsage? usage;

    // "중지" 신호를 받으면 이 스트림을 _GenerationStopped 오류로 끊는다.
    void abort() {
      timer?.cancel();
      if (!ctrl.isClosed) {
        ctrl.addError(const _GenerationStopped());
        sub?.cancel();
        ctrl.close();
      }
    }

    void fail(Object error) {
      timer?.cancel();
      if (!ctrl.isClosed) {
        ctrl.addError(error);
        sub?.cancel();
        ctrl.close();
      }
    }

    /// 이 응답의 실측치를 프리셋 속도계에 넣는다(표본 판정은 SpeedMeter 가 한다).
    void measure() {
      final started = firstAt;
      if (started == null) return;
      final ms = DateTime.now().difference(started).inMilliseconds;
      // usage 가 오면 확정값, 아니면 길이/4 근사(§note 남은 작업 "정확한 토크나이저").
      final tokens = usage?.completion ?? (chars / 4).round();
      unawaited(_workspace.observeSpeed(presetId,
          completionTokens: tokens, elapsedMs: ms));
    }

    ctrl = StreamController<LlmEvent>(
      onListen: () {
        // 이미 중지 요청이 들어와 있으면 곧바로 끊는다.
        if (_cancelRequested) {
          abort();
          return;
        }
        _streamAborters.add(abort);
        final prefill = cfg.firstResponseTimeout;
        if (prefill != null) {
          timer = Timer(prefill,
              () => fail(TimeoutException('LLM response timeout', prefill)));
        }
        sub = source.listen(
          (e) {
            if (firstAt == null) {
              // 응답이 시작됐다 — 프리필 타이머를 놓아 주고 생성 예산을 건다.
              firstAt = DateTime.now();
              timer?.cancel();
              final limit = _workspace.streamingLimitFor(presetId);
              if (limit != null) {
                timer = Timer(
                    limit,
                    () => fail(LlmBudgetExceeded(
                        _workspace.budgetReasonFor(presetId, limit))));
              } else {
                timer = null;
              }
            }
            switch (e) {
              case LlmContent(:final text):
                chars += text.length;
              case LlmReasoning(:final text):
                chars += text.length;
              case LlmUsage():
                usage = e;
              case LlmToolCalls():
                break;
            }
            ctrl.add(e);
          },
          onError: (Object e, StackTrace st) {
            timer?.cancel();
            ctrl.addError(e, st);
          },
          onDone: () {
            timer?.cancel();
            measure(); // 정상 종료한 응답만 표본으로 쓴다
            ctrl.close();
          },
        );
      },
      // done/error/break/외부중지 등 모든 종료 경로에서 여기로 와 정리된다.
      onCancel: () {
        timer?.cancel();
        _streamAborters.remove(abort);
        return sub?.cancel();
      },
    );
    return ctrl.stream;
  }

  /// LLM 호출을 타임아웃/오류 시 백오프 후 재시도한다(상태 표시 포함).
  /// 모든 시도가 실패하면 마지막 오류를 다시 던진다.
  Future<T> _withLlmRetry<T>(
    Future<T> Function() op, {
    required String reason,
    int maxAttempts = _maxAttempts,
  }) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await op();
      } catch (e) {
        // 중지 요청이면 재시도하지 않고 즉시 전파한다.
        if (e is _GenerationStopped || _cancelRequested) rethrow;
        // 예산 초과도 재시도 대상이 아니다 — 같은 조건이면 또 같은 자리에서 걸리고,
        // 그동안의 토큰만 두 배로 나간다. 사용자가 설정을 고치는 게 맞다.
        if (e is LlmBudgetExceeded) rethrow;
        if (attempt >= maxAttempts) rethrow;
        await _retryDelay(attempt + 1, maxAttempts, '$reason: ${_briefErr(e)}');
      }
    }
  }

  static String _snippet(String s) {
    final t = s.replaceAll('\n', ' ').trim();
    return t.length > 120 ? '${t.substring(0, 120)}…' : t;
  }

  /// 실패한 시도에서 추가된 메시지를 지우고 화면을 다시 동기화한다.
  /// 실패/중지한 시도가 남긴 기록을 걷어낸다.
  ///
  /// [baselineId] 는 **생성이 시작되기 전** 마지막 메시지(보통 사용자 메시지)다.
  /// 그 뒤에 생긴 것(어시스턴트 턴, 도구 결과, 하위 대화)이 이번 요청의 산물이므로
  /// 통째로 지운다.
  ///
  /// 예전에는 "이번 시도에서 만든 첫 assistant 메시지" 를 기준으로 지웠는데,
  /// **첫 모델 호출이 곧바로 실패하면 그 기준이 정해지지 않아**(null) 아무것도
  /// 지우지 못했다. 경계를 시도 밖에서 한 번 잡아 두면 어디서 실패하든 정확히 걷힌다.
  Future<void> _cleanupAttempt(
      ConversationStore store, int convId, int? baselineId) async {
    if (baselineId != null) {
      await store.deleteMessagesAfter(convId, baselineId);
    }
    // 스트리밍 중이던 부분 카드도 지우도록 항상 기록을 다시 보낸다.
    await _pushHistory();
  }

  /// 모델 한 턴을 스트리밍 실행(화면 표시 + DB 저장). 결과 레코드를 반환.
  Future<({String content, List<ToolCall> toolCalls, int id, int elapsedMs})>
      _runModelTurn(
    ConversationStore store,
    int convId,
    LlmConfig cfg,
    String presetId,
    List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  ) async {
    // 보내는 모양은 **가장 엄격한 템플릿 기준**을 지킨다(§message_shape.dart).
    assert(chatShapeProblem(messages) == null,
        'bad chat shape: ${chatShapeProblem(messages)}');
    _post({'type': 'chat.begin'});
    final start = DateTime.now();
    final content = StringBuffer();
    final reasoning = StringBuffer();
    LlmUsage? usage;
    var toolCalls = const <ToolCall>[];
    // 현재 단계(connecting → reasoning/streaming → done). 매초 ticker 가 이 값으로
    // 통계를 갱신해, 전송 대기·리즈닝처럼 이벤트가 뜸한 동안에도 진행이 살아 보이게 한다.
    var phase = 'connecting';

    void emitStats(String status) {
      final ms = DateTime.now().difference(start).inMilliseconds;
      // 본문이 없고 리즈닝만 진행 중일 때도 토큰이 움직이도록 둘을 합쳐 추정한다.
      final approxTokens =
          usage?.completion ?? ((content.length + reasoning.length) / 4).round();
      final speed = ms > 0 ? approxTokens / (ms / 1000) : 0;
      _post({
        'type': 'chat.stats',
        'status': status,
        'tokens': approxTokens, // 받은(완료) 토큰
        'sent': usage?.prompt ?? 0, // 보낸(프롬프트) 토큰 — usage 도착 후 확정
        'speed': double.parse(speed.toStringAsFixed(1)),
        'elapsedMs': ms,
        'exact': usage != null,
      });
    }

    emitStats(phase);
    // 요청을 보내고 첫 데이터가 오기 전까지는 대기, 데이터가 오기 시작하면 수신 중.
    _status('Waiting for response…');
    var receiving = false;
    void markReceiving() {
      if (receiving) return;
      receiving = true;
      _status('Receiving response…');
    }

    // 이벤트가 없는 동안에도 경과 시간/토큰이 살아 움직이도록 매초 통계를 보낸다.
    final ticker =
        Timer.periodic(const Duration(seconds: 1), (_) => emitStats(phase));
    try {
      await for (final ev in _withResponseTimeout(
          _providerFor(cfg).streamChat(cfg: cfg, messages: messages, tools: tools),
          cfg,
          presetId)) {
        switch (ev) {
          case LlmContent(:final text):
            content.write(text);
            markReceiving();
            phase = 'streaming';
            // 본문은 그대로 흘린다. 턴 요약은 응답에 섞지 않고 답변 확정 뒤
            // 별도 호출로 만든다(_scheduleTurnSummary) — 홀드백/마커 파싱 없음.
            _post({'type': 'chat.delta', 'content': text});
            emitStats(phase);
          case LlmReasoning(:final text):
            reasoning.write(text);
            markReceiving();
            phase = 'reasoning';
            _post({'type': 'chat.delta', 'reasoning': text});
            emitStats(phase);
          case LlmUsage():
            usage = ev;
          case LlmToolCalls(:final calls):
            toolCalls = calls;
        }
      }
    } finally {
      ticker.cancel();
    }

    // 응답 본문 = 사용자에게 보이는 답변 그대로. 턴 요약(metadata.summary)은
    // 여기서 만들지 않고, 답변을 확정한 뒤 백그라운드 호출이 채워 넣는다.
    final body = content.toString();
    final meta = jsonEncode({
      // 공백만 있는 추론(일부 서버가 흘리는 빈 reasoning)은 저장하지 않는다.
      if (reasoning.toString().trim().isNotEmpty)
        'reasoning': reasoning.toString(),
      if (usage != null)
        'usage': {
          'prompt': usage.prompt,
          'completion': usage.completion,
          'total': usage.total,
        },
    });
    final id = await store.addMessage(
      conversationId: convId,
      role: MessageRole.assistant,
      content: body,
      model: cfg.model,
      provider: cfg.connection.name,
      api: 'chat/completions',
      pipeline: 'main',
      toolCalls: toolCalls.isEmpty
          ? null
          : jsonEncode([
              for (final c in toolCalls)
                {'id': c.id, 'name': c.name, 'arguments': c.arguments},
            ]),
      metadata: meta,
    );
    final elapsedMs = DateTime.now().difference(start).inMilliseconds;
    emitStats('done');
    _post({
      'type': 'chat.done',
      'id': id,
      'elapsedMs': elapsedMs,
      'empty': body.isEmpty,
    });
    return (
      content: body,
      toolCalls: toolCalls,
      id: id,
      elapsedMs: elapsedMs,
    );
  }

  /// Python/기본 모듈이 준비됐으면 도구 레지스트리를 구성한다(아니면 null).
  Future<ToolRegistry?> _buildToolRegistry() async {
    // 실효 파이썬(venv 준비 시 venv)으로 도구를 실행해야, venv 에 설치한 패키지
    // (mcp 등)를 도구가 실제로 임포트할 수 있다(base 로 돌면 못 찾는다).
    // 전제조건은 WorkspaceController.toolsReady 한 곳에서 판단한다(헤더의 설정
    // 안내 버튼도 같은 값을 쓰므로, 안내와 실제 동작이 어긋나지 않는다).
    if (!_workspace.toolsReady) return null;
    final registry = ToolRegistry(
      runner: ToolRunner(
        _workspace.effectivePython!,
        // 중지를 눌렀을 때 곧바로 끊을 수 있도록 실행 중인 도구를 추적한다.
        onProcessStart: (proc) {
          _toolProcesses.add(proc);
          proc.exitCode.whenComplete(() => _toolProcesses.remove(proc));
        },
      ),
      baseScripts: _workspace.baseToolModulePaths,
      adaptersDir: _workspace.toolAdaptersDir!,
    );
    try {
      await registry.load(_workspace.toolSources,
          workingDirectory: _workspace.projectPath,
          // 설정에서 꺼 둔 도구는 목록에도 프롬프트에도 실리지 않는다
          // (메인·서브에이전트가 같은 레지스트리를 쓰므로 한 곳이면 충분하다).
          disabled: _workspace.disabledTools);
    } catch (_) {
      return null;
    }
    return registry;
  }

  String _toolResultString(ToolCallResult res) {
    if (res.ok) return jsonEncode({'ok': true, 'result': res.result});
    return jsonEncode({
      'ok': false,
      if (res.error != null) 'error': res.error,
      if (res.needsElevation) 'needs_elevation': true,
      if (res.reason != null) 'reason': res.reason,
    });
  }

  String _toolSummary(ToolCallResult res) {
    if (res.ok) return 'ok';
    if (res.needsElevation) return 'elevation required';
    return res.error ?? 'error';
  }

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
    void fail(String message) =>
        _post({'type': 'file.saved', 'path': path, 'ok': false, 'message': message});
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
      unawaited(_pushChatMeta());
    }
  }

  void _post(Map<String, Object?> msg) {
    _view.postMessage(jsonEncode(msg));
  }

  Future<void> dispose() async {
    _workspace.removeListener(_onWorkspaceChanged);
    // 남아 있는 도구 프로세스를 정리한다(프로젝트 전환·종료 시 고아 프로세스 방지).
    for (final proc in _toolProcesses.toList()) {
      proc.kill();
    }
    _toolProcesses.clear();
    await _msgSub?.cancel();
    await _watchSub?.cancel();
    _flushTimer?.cancel();
    _defaultProvider.dispose();
    for (final p in _providers.values) {
      p.dispose();
    }
  }
}

/// 예전(인라인 마커) 방식으로 저장된 본문에서 `<turn_summary>` 흔적을 걷어낸다.
///
/// 턴 요약은 이제 응답에 섞지 않고 별도 호출로 만들지만, **그 이전 대화 기록에는
/// 마커가 그대로 남아 있다**(본문으로 저장됐다). 표시·컨텍스트 재사용 시 이걸로
/// 정리한다. 새 대화에는 애초에 나타나지 않는다.
///
/// - 짝이 맞는 블록은 통째로 제거한다.
/// - 짝이 없는 태그는 **태그만** 지우고 내용은 남긴다 — 닫히지 않은 경우 그 뒤가
///   실제 답변일 수 있어, 통째로 지우면 답변을 잃는다.
String stripTurnSummary(String raw) {
  // 대부분의 메시지엔 마커가 없다 — 대소문자 무시로 한 번만 확인하고 빠져나간다.
  if (!_turnSummaryProbe.hasMatch(raw)) return raw;
  return raw
      .replaceAll(_turnSummaryBlock, '')
      .replaceAll(_turnSummaryStray, '')
      .trimLeft();
}

final RegExp _turnSummaryProbe = RegExp('turn_summary', caseSensitive: false);
final RegExp _turnSummaryBlock =
    RegExp(r'<turn_summary>[\s\S]*?</turn_summary>\s*', caseSensitive: false);
final RegExp _turnSummaryStray =
    RegExp(r'</?turn_summary>\s*', caseSensitive: false);

/// 사용자가 "중지"를 눌러 생성을 강제로 끊을 때 스트림에 실어 보내는 신호.
/// (재시도 대상 오류와 구분하기 위한 내부 전용 예외)
class _GenerationStopped implements Exception {
  const _GenerationStopped();
  @override
  String toString() => 'Generation stopped by user';
}
