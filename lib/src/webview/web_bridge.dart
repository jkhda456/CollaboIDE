import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../app/workspace_controller.dart';
import '../conversation/conversation_store.dart';
import '../conversation/models.dart';
import '../fs/file_service.dart';
import '../llm/llm_config.dart';
import '../llm/openai_client.dart';
import '../tools/tool_module.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_runner.dart';
import 'platform_web_view.dart';

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
class WebBridge {
  WebBridge(
    this._view,
    this._workspace, {
    FileService? fileService,
    OpenAiClient? llmClient,
  })  : _fs = fileService ?? FileService(),
        _llm = llmClient ?? OpenAiClient();

  final PlatformWebView _view;
  final WorkspaceController _workspace;
  final FileService _fs;
  final OpenAiClient _llm;

  bool _generating = false;

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
  }

  /// 현재 프로젝트를 바꾼다: 웹에 알리고, 감시자를 재시작하고, 대화 기록을 보낸다.
  Future<void> setProject(String? path) async {
    _projectPath = path;
    await _restartWatcher(path);
    _post({'type': 'project.changed', 'path': path ?? ''});
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
        break;
      case 'dir.list':
        _handleDirList(msg['path'] as String?);
        break;
      case 'file.open':
        _handleFileOpen(msg['path'] as String?, msg['mode'] as String?);
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
      case 'chat.send':
        _handleChatSend(msg['text'] as String?);
        break;
      case 'chat.queue.cancel':
        _handleQueueCancel((msg['id'] as num?)?.toInt());
        break;
      case 'chat.retry':
        _handleChatRetry();
        break;
      case 'chat.truncateFrom':
        _handleTruncate(msg['messageId'] as int?);
        break;
      case 'chat.edit':
        _handleChatEdit(msg['messageId'] as int?, msg['text'] as String?);
        break;
    }
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
                'content': m.content,
                'model': m.model,
                'toolCalls': m.toolCalls,
                'toolName': m.toolName,
                'toolCallId': m.toolCallId,
              })
          .toList(),
    });
    await _pushChatMeta();
  }

  /// 헤더용 메타: 모델명 + 컨텍스트(메인 누적) + 총합(메인 + 서브 LLM 누적).
  Future<void> _pushChatMeta() async {
    final store = _store, convId = _convId;
    var context = 0;
    var total = 0;
    if (store != null && convId != null) {
      context = _sumUsageTotal(await store.messages(convId));
      total = context;
      // 하위 대화(서브에이전트/검증)의 토큰도 총합에 더한다.
      for (final sub in await store.subConversations(convId)) {
        total += _sumUsageTotal(await store.messages(sub.id));
      }
    }
    _post({
      'type': 'chat.meta',
      'model': _workspace.llmConfig.model,
      'contextTokens': context,
      'totalTokens': total,
    });
  }

  /// 메시지들의 metadata.usage.total 합.
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

  Future<void> _handleChatSend(String? text) async {
    final store = _store, convId = _convId;
    if (text == null || text.trim().isEmpty || store == null || convId == null) {
      return;
    }
    // 생성 중이면 드롭하지 않고 대기 큐에 넣는다(끝나면 순서대로 처리).
    if (_generating) {
      _queue.add({'id': ++_queueSeq, 'text': text});
      _emitQueue();
      return;
    }
    await _sendAndDrain(store, convId, text);
  }

  /// 메시지를 보내고 생성한다. 끝난 뒤 큐에 쌓인 메시지가 있으면 순서대로 이어서 처리.
  Future<void> _sendAndDrain(
      ConversationStore store, int convId, String first) async {
    await _sendOne(store, convId, first);
    await _drainQueue(store, convId);
  }

  Future<void> _sendOne(
      ConversationStore store, int convId, String text) async {
    final userId = await store.addMessage(
      conversationId: convId,
      role: MessageRole.user,
      content: text,
    );
    _post({'type': 'chat.message', 'id': userId, 'role': 'user', 'content': text});
    await _generate(store, convId);
  }

  /// 생성이 끝난 뒤 대기 큐를 순서대로 비운다(재시도/수정 경로에서도 호출).
  Future<void> _drainQueue(ConversationStore store, int convId) async {
    while (_queue.isNotEmpty) {
      final text = _queue.removeAt(0)['text'] as String;
      _emitQueue();
      await _sendOne(store, convId, text);
    }
  }

  /// 현재 대기 큐 상태를 웹으로 전달한다(상태 풍선 칩/모달 갱신용).
  void _emitQueue() => _post({'type': 'chat.queue', 'items': _queue});

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

  static const int _maxToolIterations = 20;
  static const int _maxAttempts = 3;
  static const int _maxSubIterations = 8;

  /// 요청 후 첫 응답(첫 토큰)이 이 시간 안에 안 오면 멈춘 것으로 보고 재시작한다.
  static const Duration _firstResponseTimeout = Duration(seconds: 30);

  /// 스트리밍 도중 이벤트 사이 간격이 이 시간을 넘으면 멈춘 것으로 보고 끊는다.
  static const Duration _llmIdleTimeout = Duration(seconds: 60);

  /// 네이티브로 처리하는 도구(서브 LLM 분기). 파이썬으로 보내지 않는다.
  static const Set<String> _nativeToolNames = {'run_subagent', 'verify_work'};

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

  static const String _subAgentSystem =
      'You are a focused sub-agent in Collabo IDE. Complete the given task using '
      'the available tools (file read/search/edit, commands). Work only within '
      'the project. Return a concise result of what you did or found.';

  static const String _verifySystem =
      'You are a verification sub-agent in Collabo IDE. Using the available '
      'read/search tools, inspect the project and verify whether the described '
      'work was completed correctly. Be concise. End with a clear verdict: '
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
    final cfg = _workspace.llmConfig;
    if (!cfg.isConfigured) {
      _post({
        'type': 'chat.error',
        'message': 'LLM is not configured. Enter connection info in settings.'
      });
      return;
    }
    _generating = true;
    _status('Preparing…');

    final registry = await _buildToolRegistry();
    // 파이썬 도구 + 네이티브 서브에이전트 도구를 메인 LLM 에 제공.
    final tools = <Map<String, Object?>>[
      if (registry != null) ...registry.openAiTools,
      ..._nativeTools,
    ];
    final workspace = _workspace.projectPath;

    // 사전 평가: 서브에이전트가 마지막 요청을 보고 "자기 차례가 있는지" 한 줄 피드백.
    // 이 한 줄을 메인 컨텍스트에 넣어 메인 에이전트가 그걸 참고해 답을 쓰게 한다.
    final triage = await _triageRequest(store, convId, cfg);

    try {
      for (var attempt = 0; attempt < _maxAttempts; attempt++) {
        int? firstId; // 이번 시도에 생성한 첫 DB 메시지(오류 정리용)
        try {
          final messages = await _buildContextMessages(store, convId);
          if (triage != null) {
            messages.add({
              'role': 'system',
              'content': 'Sub-agent pre-assessment of the latest request: '
                  '$triage\nUse this when deciding whether to delegate via '
                  '`run_subagent`.',
            });
          }
          var converged = false;
          for (var iter = 0; iter < _maxToolIterations; iter++) {
            // 실제 대기/수신 상태는 _runModelTurn 이 직접 풍선에 표시한다.
            final turn = await _runModelTurn(store, convId, cfg, messages, tools);
            firstId ??= turn.id;
            if (turn.toolCalls.isEmpty) {
              converged = true;
              break;
            }
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
            for (final c in turn.toolCalls) {
              await _runToolCall(store, convId, cfg, registry, workspace,
                  messages, attempt, iter, c);
            }
          }
          // 비수렴(반복 한도 초과)이어도 수행한 작업은 그대로 두고 종료한다.
          if (!converged) {
            _post({'type': 'chat.notice', 'text': 'reached step limit ($_maxToolIterations)'});
          }
          await _pushChatMeta();
          return;
        } catch (e) {
          // 통신/타임아웃 등 오류는 재시도(이미 추가된 이번 시도 기록은 정리).
          await _cleanupAttempt(store, convId, firstId);
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
      _clearStatus();
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
        () => _runSubModelTurn(cfg, [
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
  Future<List<Map<String, Object?>>> _buildContextMessages(
      ConversationStore store, int convId) async {
    final messages = <Map<String, Object?>>[];
    final prompt = _workspace.systemPrompt.trim();
    if (prompt.isNotEmpty) messages.add({'role': 'system', 'content': prompt});
    for (final m in await store.messages(convId)) {
      final role = switch (m.role) {
        MessageRole.user => 'user',
        MessageRole.assistant => 'assistant',
        MessageRole.system => 'system',
        _ => null,
      };
      if (role != null && m.content.isNotEmpty) {
        messages.add({'role': role, 'content': m.content});
      }
    }
    return messages;
  }

  /// 도구 한 건 실행: 화면 표시(running→done) + DB 기록 + 컨텍스트에 결과 추가.
  /// 네이티브 도구(run_subagent/verify_work)는 서브 LLM 으로 처리한다.
  Future<void> _runToolCall(
    ConversationStore store,
    int convId,
    LlmConfig cfg,
    ToolRegistry? registry,
    String? workspace,
    List<Map<String, Object?>> messages,
    int attempt,
    int iter,
    ToolCall c,
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
    if (_nativeToolNames.contains(c.name)) {
      final verify = c.name == 'verify_work';
      _status(verify ? 'Sub-agent: verifying…' : 'Sub-agent: working…');
      final prompt = (argMap['prompt'] as String?) ?? '';
      final text = await _runSubAgent(
          store, convId, cfg, registry, workspace, prompt, verify, c.name, tid);
      ok = true;
      resultStr = jsonEncode({'ok': true, 'result': text});
      summary = _snippet(text);
    } else {
      _status('Tool: ${c.name}…');
      final res = registry == null
          ? const ToolCallResult(ok: false, error: 'No tools available')
          : await registry.call(c.name, argMap,
              workspace: workspace, workingDirectory: workspace);
      ok = res.ok;
      resultStr = _toolResultString(res);
      summary = _toolSummary(res);
      // 변경 도구(edit/replace/write/create)의 diff 를 추출해 카드에 표시.
      if (res.ok && res.result is Map) {
        final r = (res.result as Map).cast<String, Object?>();
        if (r['diff'] is String) diff = r['diff'] as String;
        if (r['path'] is String) path = r['path'] as String;
      }
    }

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
  ) async {
    if (prompt.trim().isEmpty) return '(empty prompt)';
    // 부모 도구 버블(tid)을 클릭하면 볼 수 있는 실시간 전사(transcript)용 식별자.
    final parentTid = tid;
    final subTools = registry?.openAiTools;
    final subMessages = <Map<String, Object?>>[
      {'role': 'system', 'content': verify ? _verifySystem : _subAgentSystem},
      {'role': 'user', 'content': prompt},
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
        if (iter > 0) {
          _post({'type': 'chat.sub', 'tid': parentTid, 'turn': true});
        }
        final turn = await _withLlmRetry(
          () => _runSubModelTurn(cfg, subMessages, subTools,
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
        for (final c in turn.toolCalls) {
          final tid = 'sub_${parentConvId}_${sub++}_${c.id}';
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
          final res = registry == null
              ? const ToolCallResult(ok: false, error: 'No tools available')
              : await registry.call(c.name, argMap,
                  workspace: workspace, workingDirectory: workspace);
          subMessages.add({
            'role': 'tool',
            'tool_call_id': c.id,
            'content': _toolResultString(res),
          });
          _post({
            'type': 'chat.activity',
            'tid': tid,
            'name': c.name,
            'status': 'done',
            'ok': res.ok,
            'summary': _toolSummary(res),
          });
          // 실시간 전사에도 이 도구 호출/결과를 한 줄로 남긴다.
          _post({
            'type': 'chat.sub',
            'tid': parentTid,
            'role': 'tool',
            'name': c.name,
            'ok': res.ok,
            'summary': _toolSummary(res),
          });
        }
      }
    } catch (e) {
      return 'sub-agent error: $e';
    } finally {
      heartbeat.cancel();
    }

    // 하위 컨텍스트로 기록(메인 대화에는 미표시).
    try {
      final subConvId = await store.createSubConversation(
        parentConversationId: parentConvId,
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

  /// 서브 LLM 한 턴(조용히 스트리밍, 화면 표시 없음).
  /// 내용 + 도구 호출 + 이 호출의 총 토큰(usage)을 반환.
  Future<({String content, List<ToolCall> toolCalls, int totalTokens})>
      _runSubModelTurn(
    LlmConfig cfg,
    List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools, {
    void Function(int chars)? onContent,
    void Function(String text)? onDelta,
    void Function(String text)? onReasoning,
  }) async {
    final content = StringBuffer();
    var reasoningLen = 0;
    var toolCalls = const <ToolCall>[];
    var totalTokens = 0;
    await for (final ev in _withResponseTimeout(
        _llm.streamChat(cfg: cfg, messages: messages, tools: tools))) {
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
  void _status(String text) => _post({'type': 'status', 'text': text});

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
      _status('$reason — retrying in ${r}s ($nextAttempt/$maxAttempts)');
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  /// LLM 스트림을 응답 타임아웃으로 감싼다. **첫 이벤트**는 [_firstResponseTimeout]
  /// 안에, 이후 각 이벤트는 [_llmIdleTimeout] 안에 와야 한다. 초과하면
  /// TimeoutException 을 던져(=재시작 신호) 멈춤을 빨리 감지한다.
  Stream<T> _withResponseTimeout<T>(Stream<T> source) {
    late StreamController<T> ctrl;
    StreamSubscription<T>? sub;
    Timer? timer;
    void arm(Duration d) {
      timer?.cancel();
      timer = Timer(d, () {
        ctrl.addError(TimeoutException('LLM response timeout', d));
        sub?.cancel();
        ctrl.close();
      });
    }

    ctrl = StreamController<T>(
      onListen: () {
        arm(_firstResponseTimeout);
        sub = source.listen(
          (e) {
            arm(_llmIdleTimeout); // 첫 이벤트 후엔 idle 기준으로 전환/리셋
            ctrl.add(e);
          },
          onError: (Object e, StackTrace st) {
            timer?.cancel();
            ctrl.addError(e, st);
          },
          onDone: () {
            timer?.cancel();
            ctrl.close();
          },
        );
      },
      onCancel: () {
        timer?.cancel();
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
  Future<void> _cleanupAttempt(
      ConversationStore store, int convId, int? firstId) async {
    if (firstId != null) await store.deleteMessagesFrom(convId, firstId);
    // 스트리밍 중이던 부분 카드도 지우도록 항상 기록을 다시 보낸다.
    await _pushHistory();
  }

  /// 모델 한 턴을 스트리밍 실행(화면 표시 + DB 저장). 결과 레코드를 반환.
  Future<({String content, List<ToolCall> toolCalls, int id, int elapsedMs})>
      _runModelTurn(
    ConversationStore store,
    int convId,
    LlmConfig cfg,
    List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  ) async {
    _post({'type': 'chat.begin'});
    final start = DateTime.now();
    final content = StringBuffer();
    final reasoning = StringBuffer();
    LlmUsage? usage;
    var toolCalls = const <ToolCall>[];

    void emitStats(String status) {
      final ms = DateTime.now().difference(start).inMilliseconds;
      final approxTokens = usage?.completion ?? (content.length / 4).round();
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

    emitStats('connecting');
    // 요청을 보내고 첫 데이터가 오기 전까지는 대기, 데이터가 오기 시작하면 수신 중.
    _status('Waiting for response…');
    var receiving = false;
    void markReceiving() {
      if (receiving) return;
      receiving = true;
      _status('Receiving response…');
    }

    await for (final ev in _withResponseTimeout(
        _llm.streamChat(cfg: cfg, messages: messages, tools: tools))) {
      switch (ev) {
        case LlmContent(:final text):
          content.write(text);
          markReceiving();
          _post({'type': 'chat.delta', 'content': text});
          emitStats('streaming');
        case LlmReasoning(:final text):
          reasoning.write(text);
          markReceiving();
          _post({'type': 'chat.delta', 'reasoning': text});
        case LlmUsage():
          usage = ev;
        case LlmToolCalls(:final calls):
          toolCalls = calls;
      }
    }

    final meta = jsonEncode({
      if (reasoning.isNotEmpty) 'reasoning': reasoning.toString(),
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
      content: content.toString(),
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
      'empty': content.isEmpty,
    });
    return (
      content: content.toString(),
      toolCalls: toolCalls,
      id: id,
      elapsedMs: elapsedMs,
    );
  }

  /// Python/기본 모듈이 준비됐으면 도구 레지스트리를 구성한다(아니면 null).
  Future<ToolRegistry?> _buildToolRegistry() async {
    final interp = _workspace.pythonInterpreter;
    final baseScript = _workspace.baseToolModulePath;
    final adaptersDir = _workspace.toolAdaptersDir;
    if (!_workspace.pythonInstalled ||
        interp == null ||
        baseScript == null ||
        adaptersDir == null) {
      return null;
    }
    final registry = ToolRegistry(
      runner: ToolRunner(interp),
      baseScript: baseScript,
      adaptersDir: adaptersDir,
    );
    try {
      await registry.load(_workspace.toolSources,
          workingDirectory: _workspace.projectPath);
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

  /// + 첨부: 파일 선택 → 텍스트면 내용을, 아니면 경로를 입력창에 삽입.
  Future<void> _handleAttachPick() async {
    final file = await openFile();
    if (file == null) return;
    final path = file.path;
    if (_fs.defaultModeFor(path) == FileViewMode.hex) {
      // 비텍스트(바이너리): 경로만 삽입(도구가 참조해 읽을 수 있게).
      _post({'type': 'composer.insert', 'text': path});
      return;
    }
    try {
      final content = await _fs.readFile(path, mode: FileViewMode.text);
      _post({'type': 'composer.insert', 'text': content.content});
    } catch (_) {
      _post({'type': 'composer.insert', 'text': path});
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

  /// 트리에서 드래그한 항목을 폴더로 이동/복사한다(사용자 동작).
  Future<void> _handleFsMove(String? src, String? dst, {required bool move}) async {
    if (src == null || dst == null || src.isEmpty || dst.isEmpty) return;
    // dst 는 대상 폴더. 실제 목적지 = 폴더/원본이름.
    final destDir = dst;
    final target = p.join(destDir, p.basename(src));
    // 자기 자신/내부로의 이동 방지.
    if (p.equals(src, target)) return;
    if (p.isWithin(src, destDir) || p.equals(src, destDir)) {
      _post({'type': 'fs.error', 'message': 'Cannot move a folder into itself.'});
      return;
    }
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _post({'type': 'fs.error', 'message': 'Target already exists: $target'});
      return;
    }
    try {
      if (move) {
        await _fs.movePath(src, target);
      } else {
        await _fs.copyPath(src, target);
      }
      // 감시자가 양쪽 디렉토리를 갱신하지만, 즉시 반영 위해 명시적으로도 통지.
      _post({
        'type': 'fs.change',
        'paths': [p.dirname(src), destDir],
      });
    } catch (e) {
      _post({'type': 'fs.error', 'message': '$e'});
    }
  }

  Future<void> _handleFileOpen(String? path, String? modeName) async {
    if (path == null || path.isEmpty) return;
    final mode = switch (modeName) {
      'text' => FileViewMode.text,
      'hex' => FileViewMode.hex,
      'md' => FileViewMode.md,
      _ => null,
    };
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
    }
  }

  void _post(Map<String, Object?> msg) {
    _view.postMessage(jsonEncode(msg));
  }

  Future<void> dispose() async {
    await _msgSub?.cancel();
    await _watchSub?.cancel();
    _flushTimer?.cancel();
    _llm.dispose();
  }
}
