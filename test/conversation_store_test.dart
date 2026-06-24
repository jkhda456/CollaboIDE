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
