import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/conversation/conversation_store.dart';
import 'package:collabo_ide/src/conversation/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory projectDir;

  setUpAll(ConversationStore.initSqliteFfi);

  setUp(() async {
    projectDir = await Directory.systemTemp.createTemp('collabo_conv_');
  });

  tearDown(() async {
    if (await projectDir.exists()) {
      await projectDir.delete(recursive: true);
    }
  });

  test('DB는 프로젝트 폴더의 .collabo 아래에 만들어진다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    expect(File(store.dbPath).existsSync(), isTrue);
    expect(store.dbPath, endsWith('.collabo${Platform.pathSeparator}conversation.db'));
  });

  group('턴 요약 metadata (백그라운드로 나중에 채워진다)', () {
    test('summary 를 넣어도 기존 metadata(usage 등)는 보존된다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '답변',
        metadata: jsonEncode({
          'usage': {'total': 42},
          'reasoning': '생각',
        }),
      );

      await store.updateMessageSummary(id, '이 턴 요약');

      final m = (await store.messages(convId)).single;
      final meta = jsonDecode(m.metadata!) as Map;
      expect(meta['summary'], '이 턴 요약');
      expect((meta['usage'] as Map)['total'], 42, reason: '기존 키를 덮으면 안 된다');
      expect(meta['reasoning'], '생각');
    });

    test('metadata 가 없던 메시지에도 붙는다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '답변',
      );

      await store.updateMessageSummary(id, '요약');
      final m = (await store.messages(convId)).single;
      expect((jsonDecode(m.metadata!) as Map)['summary'], '요약');
    });

    test('이미 지워진 메시지에 대한 늦은 요약은 조용히 무시한다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '답변',
      );
      await store.deleteMessage(id);

      // 사용자가 위 메시지를 고쳐 다시 진행한 뒤 요약이 도착하는 상황.
      await store.updateMessageSummary(id, '늦게 온 요약');
      expect(await store.messages(convId), isEmpty);
    });
  });

  group('위임 표시 metadata (결과가 아니라 사실만 남긴다)', () {
    test('위임을 기록해도 기존 metadata 는 보존된다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '', // 도구만 부른 턴 — 본문이 비어 있다
        metadata: jsonEncode({
          'usage': {'total': 7},
        }),
      );

      await store.addMessageDelegation(id,
          tool: 'run_subagent', task: 'lib/foo.dart 의 오타 수정');

      final meta =
          jsonDecode((await store.messages(convId)).single.metadata!) as Map;
      final list = meta['delegated'] as List;
      expect(list, hasLength(1));
      expect((list.first as Map)['tool'], 'run_subagent');
      expect((list.first as Map)['task'], 'lib/foo.dart 의 오타 수정');
      expect((meta['usage'] as Map)['total'], 7, reason: '기존 키를 덮으면 안 된다');
    });

    test('요약과 함께 있어도 서로 지우지 않는다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '완료했습니다',
      );

      await store.addMessageDelegation(id, tool: 'verify_work', task: '검증');
      await store.updateMessageSummary(id, '턴 요약');

      final meta =
          jsonDecode((await store.messages(convId)).single.metadata!) as Map;
      expect(meta['summary'], '턴 요약');
      expect(meta['delegated'], hasLength(1));
    });

    test('여러 번 위임하면 쌓이되 8건으로 제한된다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '',
      );

      for (var i = 0; i < 10; i++) {
        await store.addMessageDelegation(id, tool: 'run_subagent', task: '작업 $i');
      }

      final meta =
          jsonDecode((await store.messages(convId)).single.metadata!) as Map;
      final list = meta['delegated'] as List;
      expect(list, hasLength(8), reason: '무한정 쌓이면 컨텍스트를 갉아먹는다');
      expect((list.last as Map)['task'], '작업 9', reason: '최근 것이 남아야 한다');
    });

    test('삭제된 메시지에는 조용히 아무 일도 하지 않는다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final convId = await store.createConversation();
      final id = await store.addMessage(
        conversationId: convId,
        role: MessageRole.assistant,
        content: '',
      );
      await store.deleteMessage(id);

      await store.addMessageDelegation(id, tool: 'run_subagent', task: 'x');

      expect((await store.messages(convId)), isEmpty);
    });
  });

  group('파일 변경 이력 (에이전트 상태 요약용)', () {
    test('같은 파일을 여러 번 고쳐도 1행으로 유지하고 edits 만 올린다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      await store.recordFileChange(
          path: 'lib/main.dart', action: 'created', tool: 'create_file');
      await store.recordFileChange(
          path: 'lib/main.dart', action: 'modified', tool: 'edit_file');
      await store.recordFileChange(
          path: 'lib/app.dart', action: 'created', tool: 'create_file');

      final changes = await store.recentFileChanges();
      expect(changes, hasLength(2), reason: '경로 기준 1행이어야 DB 가 안 불어난다');
      final main = changes.firstWhere((c) => c.path == 'lib/main.dart');
      expect(main.edits, 2);
      expect(main.action, 'modified', reason: '최신 동작으로 갱신');
      expect(main.tool, 'edit_file');
    });

    test('최신순으로 돌려주고 limit 을 지킨다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      for (var i = 0; i < 5; i++) {
        await store.recordFileChange(path: 'f$i.txt', action: 'created');
      }
      final changes = await store.recentFileChanges(limit: 3);
      expect(changes, hasLength(3));
      // 마지막에 기록한 것이 맨 앞.
      expect(changes.first.path, 'f4.txt');
    });

    test('상한을 넘으면 오래된 항목부터 버린다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      final total = ConversationStore.maxFileChangeRows + 10;
      for (var i = 0; i < total; i++) {
        await store.recordFileChange(path: 'f$i.txt', action: 'created');
      }
      final all = await store.recentFileChanges(limit: total);
      expect(all.length, lessThanOrEqualTo(ConversationStore.maxFileChangeRows));
      expect(all.first.path, 'f${total - 1}.txt');
    });

    test('초기화하면 비워진다', () async {
      final store = await ConversationStore.openForProject(projectDir.path);
      addTearDown(store.close);

      await store.recordFileChange(path: 'a.txt', action: 'created');
      await store.clearFileChanges();
      expect(await store.recentFileChanges(), isEmpty);
    });
  });

  test('대화와 메시지를 기록하고 시간순으로 읽는다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final convId = await store.createConversation(title: '첫 대화');
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.user,
      content: '안녕',
    );
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.process,
      content: 'stdout line',
      processId: 'p1',
    );

    final msgs = await store.messages(convId);
    expect(msgs, hasLength(2));
    expect(msgs.first.role, MessageRole.user);
    expect(msgs.last.role, MessageRole.process);
    expect(msgs.last.processId, 'p1');

    final convos = await store.listConversations();
    expect(convos.single.title, '첫 대화');
  });

  test('대화 삭제 시 메시지도 함께 삭제된다(FK cascade)', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final convId = await store.createConversation();
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.assistant,
      content: '응답',
    );

    await store.deleteConversation(convId);
    expect(await store.messages(convId), isEmpty);
    expect(await store.listConversations(), isEmpty);
  });

  test('대화 DB 파일을 식별하고 다른 프로젝트로 가져온다(import)', () async {
    // 원본 프로젝트에 대화 한 건 기록.
    final src = await ConversationStore.openForProject(projectDir.path);
    final convId = await src.createConversation(title: '원본 대화');
    await src.addMessage(
      conversationId: convId,
      role: MessageRole.user,
      content: '가져올 메시지',
    );
    final srcDbPath = src.dbPath;
    await src.close();

    // 자기완결형 파일이므로 대화 DB 로 식별돼야 한다.
    expect(await ConversationStore.isConversationDb(srcDbPath), isTrue);

    // 새 프로젝트로 가져오기.
    final destDir = await Directory.systemTemp.createTemp('collabo_dest_');
    addTearDown(() => destDir.delete(recursive: true));
    final dest = await ConversationStore.openForProject(destDir.path);
    addTearDown(dest.close);

    final count = await dest.importFrom(srcDbPath);
    expect(count, 1);

    final convos = await dest.listConversations();
    expect(convos.single.title, '원본 대화');
    final msgs = await dest.messages(convos.single.id);
    expect(msgs.single.content, '가져올 메시지');
  });

  test('대화 DB 가 아닌 파일은 거부한다', () async {
    final bogus = File(p.join(projectDir.path, 'not_a_db.txt'));
    await bogus.writeAsString('hello');
    expect(await ConversationStore.isConversationDb(bogus.path), isFalse);
  });

  test('하위 대화는 상위 대화/메시지를 참조한다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final mainId = await store.createConversation(title: '메인', tools: '[]');
    final msgId = await store.addMessage(
      conversationId: mainId,
      role: MessageRole.user,
      content: '이걸 별도로 처리해줘',
    );
    final subId = await store.createSubConversation(
      parentConversationId: mainId,
      parentMessageId: msgId,
      title: '하위 처리',
    );

    final sub = await store.conversation(subId);
    expect(sub!.kind, ConversationKind.sub);
    expect(sub.parentConversationId, mainId);
    expect(sub.parentMessageId, msgId);

    // 목록 구분.
    expect((await store.listMainConversations()).map((c) => c.id), [mainId]);
    expect((await store.subConversations(mainId)).map((c) => c.id), [subId]);
  });

  test('메시지 삭제 시 그 메시지에서 분기한 하위 대화도 함께 삭제된다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final mainId = await store.createConversation(title: '메인');
    final keepMsg = await store.addMessage(
        conversationId: mainId, role: MessageRole.user, content: '유지');
    final delMsg = await store.addMessage(
        conversationId: mainId, role: MessageRole.assistant, content: '삭제 대상');
    final keepSub = await store.createSubConversation(
        parentConversationId: mainId, parentMessageId: keepMsg, title: 'keep');
    final delSub = await store.createSubConversation(
        parentConversationId: mainId, parentMessageId: delMsg, title: 'del');
    await store.addMessage(
        conversationId: delSub, role: MessageRole.user, content: 'sub 기록');

    // 단건 삭제: delMsg 에 매달린 하위 대화(delSub)와 그 메시지만 사라진다.
    await store.deleteMessage(delMsg);
    expect((await store.subConversations(mainId)).map((c) => c.id), [keepSub]);
    expect(await store.messages(delSub), isEmpty); // FK cascade
    expect(await store.conversation(delSub), isNull);
    expect(await store.conversation(keepSub), isNotNull);
  });

  test('truncate/이후 삭제 시 잘려나간 메시지의 하위 대화도 함께 삭제된다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final mainId = await store.createConversation(title: '메인');
    final first = await store.addMessage(
        conversationId: mainId, role: MessageRole.user, content: '1');
    final second = await store.addMessage(
        conversationId: mainId, role: MessageRole.assistant, content: '2');
    final third = await store.addMessage(
        conversationId: mainId, role: MessageRole.assistant, content: '3');
    final subFirst = await store.createSubConversation(
        parentConversationId: mainId, parentMessageId: first, title: 's1');
    final subSecond = await store.createSubConversation(
        parentConversationId: mainId, parentMessageId: second, title: 's2');
    final subThird = await store.createSubConversation(
        parentConversationId: mainId, parentMessageId: third, title: 's3');

    // second 이후(그 메시지는 유지) 삭제 → third 의 하위 대화만 사라진다.
    await store.deleteMessagesAfter(mainId, second);
    expect((await store.subConversations(mainId)).map((c) => c.id),
        [subFirst, subSecond]);

    // second 부터(포함) 삭제 → second 의 하위 대화도 사라진다.
    await store.deleteMessagesFrom(mainId, second);
    expect((await store.subConversations(mainId)).map((c) => c.id), [subFirst]);
    expect(await store.conversation(subThird), isNull);
    expect((await store.messages(mainId)).map((m) => m.id), [first]);
  });

  test('턴 삭제 시 도구 호출/결과·중간 행·하위 대화가 함께 삭제된다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final mainId = await store.createConversation(title: '메인');
    // 1턴: user → (중간 assistant: tool_calls) → tool 결과 → 최종 assistant.
    final userMsg = await store.addMessage(
        conversationId: mainId, role: MessageRole.user, content: '작업해줘');
    final midAssistant = await store.addMessage(
        conversationId: mainId,
        role: MessageRole.assistant,
        content: '',
        toolCalls: '[{"id":"t1","name":"run_subagent"}]');
    final subId = await store.createSubConversation(
        parentConversationId: mainId,
        parentMessageId: midAssistant,
        title: 'subagent');
    await store.addMessage(
        conversationId: mainId,
        role: MessageRole.tool,
        content: '{"ok":true}',
        toolCallId: 't1',
        toolName: 'run_subagent');
    final finalAssistant = await store.addMessage(
        conversationId: mainId, role: MessageRole.assistant, content: '끝냈어요');
    // 다음 턴(유지 대상).
    final nextUser = await store.addMessage(
        conversationId: mainId, role: MessageRole.user, content: '다음 질문');

    // 화면에 보이는 최종 assistant 카드를 삭제 → 턴 구간 전체가 사라진다.
    await store.deleteTurn(mainId, finalAssistant);
    expect((await store.messages(mainId)).map((m) => m.id), [userMsg, nextUser]);
    expect(await store.conversation(subId), isNull);
    expect(await store.subConversations(mainId), isEmpty);

    // user 메시지를 삭제하면 그 메시지부터 다음 경계 전까지(응답 포함) 사라진다.
    await store.addMessage(
        conversationId: mainId, role: MessageRole.assistant, content: '답변');
    await store.deleteTurn(mainId, nextUser);
    expect((await store.messages(mainId)).map((m) => m.id), [userMsg]);
  });

  test('열 때 분기 원점이 사라진 고아 하위 대화를 정리한다', () async {
    var store = await ConversationStore.openForProject(projectDir.path);
    final mainId = await store.createConversation(title: '메인');
    final msgId = await store.addMessage(
        conversationId: mainId, role: MessageRole.user, content: '유지');
    final keepSub = await store.createSubConversation(
        parentConversationId: mainId, parentMessageId: msgId, title: 'keep');
    // 과거 버전이 남긴 형태: parent_message_id 없음 → 고아.
    final orphan = await store.createSubConversation(
        parentConversationId: mainId, title: 'legacy');
    await store.close();

    store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);
    expect(await store.conversation(orphan), isNull);
    expect(await store.conversation(keepSub), isNotNull);
  });

  test('메시지에 모델/provider/API/도구 호출 필드가 기록된다', () async {
    final store = await ConversationStore.openForProject(projectDir.path);
    addTearDown(store.close);

    final convId = await store.createConversation();
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.assistant,
      content: '',
      model: 'claude-opus-4-8',
      provider: 'anthropic',
      api: 'messages',
      pipeline: 'main',
      toolCalls: '[{"id":"t1","name":"read_file"}]',
    );
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.tool,
      content: '파일 내용',
      toolCallId: 't1',
      toolName: 'read_file',
    );

    final msgs = await store.messages(convId);
    expect(msgs.first.model, 'claude-opus-4-8');
    expect(msgs.first.provider, 'anthropic');
    expect(msgs.first.api, 'messages');
    expect(msgs.first.toolCalls, contains('read_file'));
    expect(msgs.last.role, MessageRole.tool);
    expect(msgs.last.toolCallId, 't1');
  });

  test('가져오기: 대화 계층(부모 참조)을 새 ID 로 재매핑한다', () async {
    final src = await ConversationStore.openForProject(projectDir.path);
    final mainId = await src.createConversation(title: '메인');
    final msgId = await src.addMessage(
      conversationId: mainId,
      role: MessageRole.user,
      content: 'x',
    );
    await src.createSubConversation(
      parentConversationId: mainId,
      parentMessageId: msgId,
      title: '하위',
    );
    final srcPath = src.dbPath;
    await src.close();

    final destDir = await Directory.systemTemp.createTemp('collabo_dest2_');
    addTearDown(() => destDir.delete(recursive: true));
    final dest = await ConversationStore.openForProject(destDir.path);
    addTearDown(dest.close);

    expect(await dest.importFrom(srcPath), 2);

    final mains = await dest.listMainConversations();
    expect(mains.single.title, '메인');
    final subs = await dest.subConversations(mains.single.id);
    expect(subs.single.title, '하위');
    // 부모 참조가 가져온 새 ID 를 가리켜야 한다(원본 ID 가 아님).
    expect(subs.single.parentConversationId, mains.single.id);
    expect(subs.single.parentMessageId, isNotNull);
  });
}
