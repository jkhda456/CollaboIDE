// 감독자 개입은 **기록으로 남는다**(앱을 다시 켜도 보인다) — 다만 다음 턴의
// 컨텍스트에는 다시 들어가지 않는다(지난 지시를 계속 따라가지 않게).
//
// 예전에는 개입 줄이 그 순간에만 있었다: 대화를 다시 그리면(프로젝트 다시 열기, 앱 재시작)
// 모델이 왜 방향을 바꿨는지 알 길이 사라졌다.
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/conversation/conversation_store.dart';
import 'package:collabo_ide/src/conversation/models.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  setUpAll(initSqliteFfi);

  late Directory tmp;
  late ConversationStore store;
  late int convId;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_sup_');
    store = await ConversationStore.openForProject(tmp.path);
    convId = await store.createConversation(title: 't');
  });

  tearDown(() async {
    await store.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('개입은 system + pipeline supervisor 로 남고 metadata 에 근거가 있다', () async {
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.user,
      content: '고쳐줘',
    );
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.system,
      content: '[supervisor] Not done yet.',
      pipeline: 'supervisor',
      metadata: jsonEncode({
        'action': 'exit_guard',
        'level': 0,
        'reason': 'finished with open plan steps',
        'halt': false,
      }),
    );

    // 앱을 다시 켠 것과 같다 — 파일에서 다시 읽는다.
    await store.close();
    store = await ConversationStore.openForProject(tmp.path);
    final msgs = await store.messages(convId);

    expect(msgs, hasLength(2));
    final sup = msgs.last;
    expect(sup.role, MessageRole.system);
    expect(sup.pipeline, 'supervisor');
    expect(sup.content, contains('[supervisor]'));
    final meta = jsonDecode(sup.metadata!) as Map;
    expect(meta['action'], 'exit_guard');
    expect(meta['reason'], contains('open plan steps'));
  });

  test('대화 DB 파일에 그대로 있다(다음 실행에서 읽힌다)', () async {
    await store.addMessage(
      conversationId: convId,
      role: MessageRole.system,
      content: '[supervisor] You are going in circles.',
      pipeline: 'supervisor',
    );
    expect(File(p.join(tmp.path, '.collabo', 'conversation.db')).existsSync(), isTrue);
    final again = await store.messages(convId);
    expect(again.single.pipeline, 'supervisor');
  });
}
