import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../data/sqlite_init.dart' as sqlite;
import 'models.dart';

/// 프로젝트 단위 대화 기록 저장소 (SQLite).
///
/// DB 파일은 프로젝트 폴더 안 `<project>/.collabo/conversation.db` 에 두어
/// 프로젝트와 함께 이동한다. 자기완결형 파일이라 다른 프로젝트로 **가져오기(import)**
/// 할 수 있도록 `meta` 테이블로 종류를 식별한다.
///
/// 데스크톱(Windows/Linux/macOS)에서는 `sqflite_common_ffi` 로 동작하므로
/// 앱 시작 시 [initSqliteFfi] 를 호출해야 한다.
///
/// 스키마 v2: function calling(도구 선언/호출/결과), 처리 출처(모델/provider/API/
/// 파이프라인), 대화 계층(메인 ↔ 하위 컨텍스트, 상위 참조)을 지원한다.
class ConversationStore {
  ConversationStore._(this.db, this.dbPath);

  final Database db;
  final String dbPath;

  static const int _schemaVersion = 4;

  /// `tool_calls` 에 유지할 최대 행 수(DB 전체). 결과 원문이 건당 최대 32KB 라
  /// 무한히 쌓이면 DB 가 커진다 — 오래된 것부터 버린다.
  static const int maxToolCallRows = 1000;

  /// `file_changes` 에 유지할 최대 행 수. 오래된 것부터 버려 DB 가 무한히 크지
  /// 않게 한다(경로 기준 1행이라 실제로는 파일 개수만큼만 쌓인다).
  static const int maxFileChangeRows = 300;

  /// 대화 DB 임을 식별하는 표식(가져오기 검증용).
  static const String dbKind = 'collabo-conversation';

  /// 앱 시작 시 1회. sqflite 의 FFI 백엔드를 활성화한다.
  static void initSqliteFfi() => sqlite.initSqliteFfi();

  /// 프로젝트 경로 기준 DB 파일 경로(`<project>/.collabo/conversation.db`).
  static String dbPathForProject(String projectPath) =>
      p.join(projectPath, '.collabo', 'conversation.db');

  /// 프로젝트의 대화 DB 를 연다(없으면 생성).
  static Future<ConversationStore> openForProject(String projectPath) async {
    final path = dbPathForProject(projectPath);
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    // 고아 하위 대화 정리: 분기 원점 메시지가 없는(과거 버전이 남긴
    // parent_message_id NULL 포함) 서브에이전트 기록은 열 때 걷어낸다.
    await db.delete(
      'conversations',
      where: "kind = 'sub' AND (parent_message_id IS NULL "
          'OR parent_message_id NOT IN (SELECT id FROM messages))',
    );
    return ConversationStore._(db, path);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.insert('meta', {'key': 'kind', 'value': dbKind});
    await db.insert('meta', {'key': 'schema_version', 'value': '$version'});

    await db.execute('''
      CREATE TABLE conversations (
        id                     INTEGER PRIMARY KEY AUTOINCREMENT,
        title                  TEXT NOT NULL DEFAULT '',
        kind                   TEXT NOT NULL DEFAULT 'main',
        parent_conversation_id INTEGER
          REFERENCES conversations(id) ON DELETE CASCADE,
        parent_message_id      INTEGER,
        tools                  TEXT,
        metadata               TEXT,
        created_at             INTEGER NOT NULL,
        updated_at             INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL
          REFERENCES conversations(id) ON DELETE CASCADE,
        role            TEXT NOT NULL,
        content         TEXT NOT NULL,
        model           TEXT,
        provider        TEXT,
        api             TEXT,
        pipeline        TEXT,
        tool_calls      TEXT,
        tool_call_id    TEXT,
        tool_name       TEXT,
        process_id      TEXT,
        metadata        TEXT,
        created_at      INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_conv '
      'ON messages(conversation_id, created_at)',
    );
    await db.execute(
      'CREATE INDEX idx_conv_parent '
      'ON conversations(parent_conversation_id)',
    );
    await _createFileChanges(db);
    await _createToolCalls(db);
  }

  /// v4: 도구 호출 내역(인자 + 결과 원문) — 호출 내역 창이 앱을 다시 켠 뒤에도 보이게.
  /// 예전에는 메모리에만 있어서, 배지(대화 기록에서 다시 센 숫자)는 남는데 창은 비었다.
  static Future<void> _createToolCalls(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tool_calls (
        seq             INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL
          REFERENCES conversations(id) ON DELETE CASCADE,
        call_id         TEXT NOT NULL,
        scope           TEXT NOT NULL,
        name            TEXT NOT NULL,
        args            TEXT NOT NULL,
        result          TEXT NOT NULL DEFAULT '',
        summary         TEXT NOT NULL DEFAULT '',
        ok              INTEGER,
        started_at      INTEGER NOT NULL,
        finished_at     INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tool_calls_conv '
      'ON tool_calls(conversation_id, started_at)',
    );
  }

  /// v3: 도구가 바꾼 파일 이력. 신규 생성(onCreate)과 업그레이드(onUpgrade)가
  /// 같은 DDL 을 쓰도록 분리해 둔다.
  static Future<void> _createFileChanges(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS file_changes (
        path       TEXT PRIMARY KEY,
        action     TEXT NOT NULL,
        tool       TEXT,
        edits      INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_file_changes_at '
      'ON file_changes(updated_at)',
    );
  }

  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // v1 → v2: 대화 계층 + 메시지 처리/도구 필드 추가.
      await db.execute(
        "ALTER TABLE conversations ADD COLUMN kind TEXT NOT NULL DEFAULT 'main'",
      );
      await db.execute(
          'ALTER TABLE conversations ADD COLUMN parent_conversation_id INTEGER');
      await db.execute(
          'ALTER TABLE conversations ADD COLUMN parent_message_id INTEGER');
      await db.execute('ALTER TABLE conversations ADD COLUMN tools TEXT');
      await db.execute('ALTER TABLE conversations ADD COLUMN metadata TEXT');
      for (final col in ['model', 'provider', 'api', 'pipeline', 'tool_calls',
        'tool_call_id', 'tool_name']) {
        await db.execute('ALTER TABLE messages ADD COLUMN $col TEXT');
      }
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_conv_parent '
        'ON conversations(parent_conversation_id)',
      );
      await db.update('meta', {'value': '2'}, where: 'key = ?',
          whereArgs: ['schema_version']);
    }
    if (oldVersion < 3) {
      // v2 → v3: 파일 변경 이력(에이전트 상태 요약용).
      await _createFileChanges(db);
    }
    if (oldVersion < 4) {
      // v3 → v4: 도구 호출 내역.
      await _createToolCalls(db);
    }
    await db.update('meta', {'value': '$newVersion'}, where: 'key = ?',
        whereArgs: ['schema_version']);
  }

  // --- 파일 변경 이력 (에이전트 상태 요약용) ---

  /// 도구가 파일을 바꿨을 때 기록한다(경로 기준 1행, 재변경 시 [FileChange.edits] 증가).
  ///
  /// [path] 는 **프로젝트 루트 기준 상대 경로**를 넣는다(주입 길이 절약).
  /// 실패해도 대화 흐름을 막지 않도록 호출측에서 예외를 삼킨다.
  Future<void> recordFileChange({
    required String path,
    required String action,
    String? tool,
  }) async {
    if (path.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // UPSERT 대신 update→insert: 구버전 SQLite 에서도 동작한다.
    final updated = await db.rawUpdate(
      'UPDATE file_changes SET action = ?, tool = ?, edits = edits + 1, '
      'updated_at = ? WHERE path = ?',
      [action, tool, now, path],
    );
    if (updated == 0) {
      await db.insert('file_changes', {
        'path': path,
        'action': action,
        'tool': tool,
        'edits': 1,
        'updated_at': now,
      });
      // 새 경로가 들어왔을 때만 상한을 확인하면 충분하다.
      // rowid 보조 정렬 — 같은 밀리초에 여러 건이 들어와도 순서가 확정된다.
      await db.rawDelete(
        'DELETE FROM file_changes WHERE path NOT IN '
        '(SELECT path FROM file_changes ORDER BY updated_at DESC, rowid DESC '
        'LIMIT ?)',
        [maxFileChangeRows],
      );
    }
  }

  /// 최근 변경된 파일 목록(최신순, 최대 [limit] 건).
  Future<List<FileChange>> recentFileChanges({int limit = 30}) async {
    final rows = await db.query(
      'file_changes',
      // rowid 보조 정렬 — 같은 밀리초에 기록된 항목의 순서를 확정한다.
      orderBy: 'updated_at DESC, rowid DESC',
      limit: limit,
    );
    return rows.map(FileChange.fromRow).toList();
  }

  /// 파일 변경 이력을 모두 지운다(프로젝트 상태 요약 초기화용).
  Future<void> clearFileChanges() => db.delete('file_changes');

  // --- 도구 호출 내역 (호출 내역 창) ---

  /// 호출 시작을 남기고 행 번호를 돌려준다. 결과는 [finishToolCall] 이 채운다.
  Future<int> insertToolCall({
    required int conversationId,
    required String callId,
    required String scope,
    required String name,
    required String args,
    required DateTime startedAt,
  }) async {
    final seq = await db.insert('tool_calls', {
      'conversation_id': conversationId,
      'call_id': callId,
      'scope': scope,
      'name': name,
      'args': args,
      'started_at': startedAt.millisecondsSinceEpoch,
    });
    await db.rawDelete('DELETE FROM tool_calls WHERE seq <= ?',
        [seq - maxToolCallRows]);
    return seq;
  }

  Future<void> finishToolCall(
    int seq, {
    required bool ok,
    required String result,
    required String summary,
    required DateTime finishedAt,
  }) =>
      db.update(
        'tool_calls',
        {
          'ok': ok ? 1 : 0,
          'result': result,
          'summary': summary,
          'finished_at': finishedAt.millisecondsSinceEpoch,
        },
        where: 'seq = ?',
        whereArgs: [seq],
      );

  /// 대화의 도구 호출 내역(오래된 것부터). [since] 이후(포함)에 시작한 것만,
  /// 가장 최근 [limit] 건.
  Future<List<ToolCallRow>> toolCalls(
    int conversationId, {
    DateTime? since,
    int limit = 300,
  }) async {
    final rows = await db.query(
      'tool_calls',
      where: 'conversation_id = ? AND started_at >= ?',
      whereArgs: [conversationId, since?.millisecondsSinceEpoch ?? 0],
      orderBy: 'seq DESC',
      limit: limit,
    );
    return rows.reversed.map(ToolCallRow.fromRow).toList();
  }

  // --- conversations ---

  /// 새 대화 스레드를 만들고 ID 를 반환.
  Future<int> createConversation({
    String title = '',
    ConversationKind kind = ConversationKind.main,
    int? parentConversationId,
    int? parentMessageId,
    String? tools,
    String? metadata,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.insert('conversations', {
      'title': title,
      'kind': kind.name,
      'parent_conversation_id': parentConversationId,
      'parent_message_id': parentMessageId,
      'tools': tools,
      'metadata': metadata,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// 상위 대화에서 분기한 **하위 대화(컨텍스트)** 를 만든다.
  /// 개별 처리를 별도 호출로 진행해 메인 컨텍스트를 절약하는 전략에 쓰인다.
  Future<int> createSubConversation({
    required int parentConversationId,
    int? parentMessageId,
    String title = '',
    String? tools,
    String? metadata,
  }) =>
      createConversation(
        title: title,
        kind: ConversationKind.sub,
        parentConversationId: parentConversationId,
        parentMessageId: parentMessageId,
        tools: tools,
        metadata: metadata,
      );

  /// 메인(최상위) 대화 목록을 최근 갱신순으로 반환.
  Future<List<Conversation>> listMainConversations() async {
    final rows = await db.query(
      'conversations',
      where: 'parent_conversation_id IS NULL',
      orderBy: 'updated_at DESC',
    );
    return rows.map(Conversation.fromRow).toList();
  }

  /// 특정 대화의 하위 대화 목록.
  Future<List<Conversation>> subConversations(int parentConversationId) async {
    final rows = await db.query(
      'conversations',
      where: 'parent_conversation_id = ?',
      whereArgs: [parentConversationId],
      orderBy: 'created_at ASC',
    );
    return rows.map(Conversation.fromRow).toList();
  }

  /// 전체 대화 목록(메인 + 하위) 최근 갱신순.
  Future<List<Conversation>> listConversations() async {
    final rows = await db.query('conversations', orderBy: 'updated_at DESC');
    return rows.map(Conversation.fromRow).toList();
  }

  Future<Conversation?> conversation(int id) async {
    final rows =
        await db.query('conversations', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Conversation.fromRow(rows.first);
  }

  Future<void> renameConversation(int id, String title) async {
    await db.update(
      'conversations',
      {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteConversation(int id) async {
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  // --- messages ---

  /// 대화에 메시지를 추가하고 ID 를 반환. 대화의 updated_at 도 갱신한다.
  ///
  /// JSON 성격의 필드([tools]는 대화에, [toolCalls]/[metadata]/[pipeline])는
  /// 호출부에서 직렬화한 문자열로 전달한다.
  Future<int> addMessage({
    required int conversationId,
    required MessageRole role,
    required String content,
    String? model,
    String? provider,
    String? api,
    String? pipeline,
    String? toolCalls,
    String? toolCallId,
    String? toolName,
    String? processId,
    String? metadata,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return db.transaction((txn) async {
      final id = await txn.insert('messages', {
        'conversation_id': conversationId,
        'role': role.name,
        'content': content,
        'model': model,
        'provider': provider,
        'api': api,
        'pipeline': pipeline,
        'tool_calls': toolCalls,
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        'process_id': processId,
        'metadata': metadata,
        'created_at': now,
      });
      await txn.update(
        'conversations',
        {'updated_at': now},
        where: 'id = ?',
        whereArgs: [conversationId],
      );
      return id;
    });
  }

  /// 특정 메시지부터(그 메시지 포함) 이후의 메시지를 삭제한다.
  /// 대화 내용 수정/재시도 시, 수정 지점 이후를 잘라낼 때 쓴다.
  /// 삭제되는 메시지에서 분기한 하위 대화(서브에이전트 기록)도 함께 지운다.
  Future<void> deleteMessagesFrom(int conversationId, int messageId) async {
    await db.transaction((txn) async {
      await txn.delete(
        'conversations',
        where: 'parent_conversation_id = ? AND parent_message_id >= ?',
        whereArgs: [conversationId, messageId],
      );
      await txn.delete(
        'messages',
        where: 'conversation_id = ? AND id >= ?',
        whereArgs: [conversationId, messageId],
      );
    });
  }

  /// 특정 메시지 **이후**(그 메시지는 유지)의 메시지를 삭제한다.
  /// 인플레이스 수정 시, 수정한 메시지는 두고 그 아래만 재생성할 때 쓴다.
  /// 삭제되는 메시지에서 분기한 하위 대화(서브에이전트 기록)도 함께 지운다.
  Future<void> deleteMessagesAfter(int conversationId, int messageId) async {
    await db.transaction((txn) async {
      await txn.delete(
        'conversations',
        where: 'parent_conversation_id = ? AND parent_message_id > ?',
        whereArgs: [conversationId, messageId],
      );
      await txn.delete(
        'messages',
        where: 'conversation_id = ? AND id > ?',
        whereArgs: [conversationId, messageId],
      );
    });
  }

  /// 메시지 한 건을 삭제한다(체크포인트 원복 등 단일 행 대상에 사용).
  /// 그 메시지에서 분기한 하위 대화(서브에이전트 기록)도 함께 지운다.
  Future<void> deleteMessage(int id) async {
    await db.transaction((txn) async {
      await txn.delete(
        'conversations',
        where: 'parent_message_id = ?',
        whereArgs: [id],
      );
      await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 메시지가 속한 **턴 구간 전체**를 삭제한다(대화창의 삭제 버튼용).
  ///
  /// 한 턴은 DB 에 여러 행으로 저장된다: 도구 호출을 실은 중간 assistant 행들
  /// (본문 없음 — 화면 미표시) + `role=tool` 결과 행들 + 최종 assistant 행.
  /// 한 행만 지우면 나머지(에이전트 작업 기록)가 남으므로 구간째 지운다.
  ///
  /// 경계는 user 메시지/체크포인트다:
  /// - user 메시지를 지우면: 그 메시지부터 다음 경계 직전까지(응답 포함).
  /// - assistant/tool 을 지우면: 직전 경계 다음부터 다음 경계 직전까지
  ///   (질문 user 메시지는 유지).
  /// 구간 안의 체크포인트 행은 남기고, 구간 메시지에서 분기한 하위 대화
  /// (서브에이전트 기록)도 함께 지운다.
  Future<void> deleteTurn(int conversationId, int messageId) async {
    final all = await messages(conversationId);
    final idx = all.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    bool isBoundary(Message m) =>
        m.role == MessageRole.user || m.pipeline == 'checkpoint';
    var start = idx;
    if (all[idx].role != MessageRole.user) {
      while (start > 0 && !isBoundary(all[start - 1])) {
        start--;
      }
    }
    var end = idx + 1;
    while (end < all.length && !isBoundary(all[end])) {
      end++;
    }
    final ids = [
      for (var i = start; i < end; i++)
        if (all[i].pipeline != 'checkpoint') all[i].id,
    ];
    if (ids.isEmpty) return;
    final ph = List.filled(ids.length, '?').join(',');
    await db.transaction((txn) async {
      await txn.delete(
        'conversations',
        where: 'parent_conversation_id = ? AND parent_message_id IN ($ph)',
        whereArgs: [conversationId, ...ids],
      );
      await txn.delete('messages', where: 'id IN ($ph)', whereArgs: ids);
    });
  }

  /// 메시지 본문을 수정한다.
  Future<void> updateMessageContent(int messageId, String content) async {
    await db.update(
      'messages',
      {'content': content},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 이 메시지가 **위임한 작업**을 metadata 에 한 줄 남긴다.
  ///
  /// 위임(`run_subagent`/`verify_work`)의 결과 원문은 컨텍스트에 넣지 않는다 —
  /// 길어서 메인 컨텍스트를 갉아먹는다. 대신 **"위임했다는 사실"** 만 남겨,
  /// 다음 턴에서 에이전트가 "그 단계는 다른 에이전트가 했고 상세는 여기 없다" 를
  /// 알 수 있게 한다(실제 내용은 턴 요약과 프로젝트 상태가 전달한다).
  ///
  /// 도구만 부른 턴은 assistant 본문이 비어 컨텍스트에서 통째로 사라지는데,
  /// 이 표시가 그 자리를 대신한다.
  Future<void> addMessageDelegation(
    int messageId, {
    required String tool,
    required String task,
  }) async {
    final meta = await _readMetadata(messageId);
    if (meta == null) return; // 이미 삭제된 메시지
    final list = <Object?>[
      ...((meta['delegated'] as List?) ?? const []),
      {'tool': tool, 'task': task},
    ];
    // 한 턴에 여러 번 위임할 수 있지만 무한정 쌓이지 않게 최근 것만 남긴다.
    meta['delegated'] = list.length > 8 ? list.sublist(list.length - 8) : list;
    await db.update(
      'messages',
      {'metadata': jsonEncode(meta)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 메시지의 metadata 를 읽는다(없거나 깨졌으면 빈 맵, 메시지 자체가 없으면 null).
  Future<Map<String, Object?>?> _readMetadata(int messageId) async {
    final rows = await db.query(
      'messages',
      columns: ['metadata'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['metadata'] as String?;
    if (raw == null || raw.isEmpty) return <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      // 깨진 metadata 는 새로 쓴다.
    }
    return <String, Object?>{};
  }

  /// 메시지 metadata 의 `summary` 만 갱신한다(reasoning/usage 등 기존 키는 보존).
  ///
  /// 턴 요약은 답변을 내보낸 뒤 **백그라운드로** 만들어지므로, 도착 시점에 대상
  /// 메시지가 이미 사라졌을 수 있다(사용자가 그 위를 수정/삭제하고 다시 진행).
  /// 그 경우 조용히 아무 일도 하지 않는다.
  Future<void> updateMessageSummary(int messageId, String summary) async {
    final rows = await db.query(
      'messages',
      columns: ['metadata'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return; // 이미 삭제된 메시지 — 늦게 온 요약은 버린다.
    var meta = <String, Object?>{};
    final raw = rows.first['metadata'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) meta = decoded.cast<String, Object?>();
      } catch (_) {
        // 깨진 metadata 는 새로 쓴다(요약을 잃는 것보다 낫다).
      }
    }
    if (summary.isEmpty) {
      meta.remove('summary');
    } else {
      meta['summary'] = summary;
    }
    await db.update(
      'messages',
      {'metadata': jsonEncode(meta)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 대화의 메시지를 시간순으로 반환.
  Future<List<Message>> messages(int conversationId) async {
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(Message.fromRow).toList();
  }

  // --- 가져오기 (import) ---

  /// 주어진 파일이 collabo 대화 DB 인지 검증한다(읽기 전용으로 잠깐 열어 확인).
  static Future<bool> isConversationDb(String path) async {
    Database? probe;
    try {
      probe = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final rows = await probe.query(
        'meta',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['kind'],
        limit: 1,
      );
      return rows.isNotEmpty && rows.first['value'] == dbKind;
    } catch (_) {
      return false;
    } finally {
      await probe?.close();
    }
  }

  /// 외부 대화 DB 파일의 모든 대화/메시지를 이 저장소로 병합해 가져온다.
  ///
  /// ID 는 새로 부여되며, 대화 계층(parent_conversation_id)과 분기 메시지
  /// 참조(parent_message_id)도 새 ID 로 재매핑한다. 가져온 대화 수를 반환.
  Future<int> importFrom(String sourcePath) async {
    if (!await isConversationDb(sourcePath)) {
      throw ArgumentError('대화 DB 파일이 아닙니다: $sourcePath');
    }
    final convIdMap = <int, int>{};
    final msgIdMap = <int, int>{};
    var imported = 0;

    await db.execute('ATTACH DATABASE ? AS src', [sourcePath]);
    try {
      // 1) 대화 삽입(부모 참조는 아직 비움) + ID 매핑.
      final convRows =
          await db.rawQuery('SELECT * FROM src.conversations ORDER BY id');
      for (final c in convRows) {
        final oldId = c['id'] as int;
        final newId = await db.insert('conversations', {
          'title': c['title'],
          'kind': c['kind'] ?? 'main',
          'tools': c['tools'],
          'metadata': c['metadata'],
          'created_at': c['created_at'],
          'updated_at': c['updated_at'],
        });
        convIdMap[oldId] = newId;
        imported++;
      }

      // 2) 메시지 삽입(대화 ID 재매핑) + 메시지 ID 매핑.
      final msgRows =
          await db.rawQuery('SELECT * FROM src.messages ORDER BY id');
      for (final m in msgRows) {
        final newConvId = convIdMap[m['conversation_id'] as int];
        if (newConvId == null) continue;
        final newId = await db.insert('messages', {
          'conversation_id': newConvId,
          'role': m['role'],
          'content': m['content'],
          'model': m['model'],
          'provider': m['provider'],
          'api': m['api'],
          'pipeline': m['pipeline'],
          'tool_calls': m['tool_calls'],
          'tool_call_id': m['tool_call_id'],
          'tool_name': m['tool_name'],
          'process_id': m['process_id'],
          'metadata': m['metadata'],
          'created_at': m['created_at'],
        });
        msgIdMap[m['id'] as int] = newId;
      }

      // 3) 대화의 부모 참조를 새 ID 로 갱신.
      for (final c in convRows) {
        final newId = convIdMap[c['id'] as int]!;
        final newParentConv = convIdMap[c['parent_conversation_id'] as int?];
        final newParentMsg = msgIdMap[c['parent_message_id'] as int?];
        if (newParentConv != null || newParentMsg != null) {
          await db.update(
            'conversations',
            {
              'parent_conversation_id': newParentConv,
              'parent_message_id': newParentMsg,
            },
            where: 'id = ?',
            whereArgs: [newId],
          );
        }
      }
    } finally {
      await db.execute('DETACH DATABASE src');
    }
    return imported;
  }

  Future<void> close() => db.close();
}
