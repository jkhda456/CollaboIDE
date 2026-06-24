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

  static const int _schemaVersion = 2;

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
  Future<void> deleteMessagesFrom(int conversationId, int messageId) async {
    await db.delete(
      'messages',
      where: 'conversation_id = ? AND id >= ?',
      whereArgs: [conversationId, messageId],
    );
  }

  /// 특정 메시지 **이후**(그 메시지는 유지)의 메시지를 삭제한다.
  /// 인플레이스 수정 시, 수정한 메시지는 두고 그 아래만 재생성할 때 쓴다.
  Future<void> deleteMessagesAfter(int conversationId, int messageId) async {
    await db.delete(
      'messages',
      where: 'conversation_id = ? AND id > ?',
      whereArgs: [conversationId, messageId],
    );
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
