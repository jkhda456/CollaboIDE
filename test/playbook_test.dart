import 'dart:io';

import 'package:collabo_ide/src/agent/playbook.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late Playbook pb;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('playbook_test');
    pb = Playbook.forProject(dir.path);
    await pb.load();
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  File fileOf(Directory d) => File(p.join(d.path, '.collabo', 'PLAYBOOK.md'));

  test('파일이 없으면 빈 상태 — 오류가 아니다', () {
    expect(pb.isEmpty, isTrue);
    expect(pb.digest(), isNull);
    expect(pb.openSteps, isEmpty);
  });

  test('★ 목표를 정하면 디스크에 실제로 파일이 생긴다', () async {
    // "계획이 파일로 안 떨어지는 것 같다" 는 의심을 고정해 두는 검사다.
    expect(fileOf(dir).existsSync(), isFalse);
    await pb.setGoal('로그인 레이스 컨디션을 고친다');
    await pb.setPlan(['재현 테스트', '락 걸기']);
    expect(fileOf(dir).existsSync(), isTrue);
    final text = fileOf(dir).readAsStringSync();
    expect(text, contains('## GOAL'));
    expect(text, contains('로그인 레이스 컨디션을 고친다'));
    expect(text, contains('- [TODO] 재현 테스트'));
    await pb.updateStep('1', 'DONE');
    expect(fileOf(dir).readAsStringSync(), contains('- [DONE] 재현 테스트'));
  });

  test('fileExists 는 내용 유무가 아니라 파일 유무다', () async {
    // 트리 헤더의 "계획 파일 열기" 버튼이 이 값으로 뜬다. 계획 카드(isEmpty)와
    // 판단 기준이 다르다 — 내용이 비어도 파일이 있으면 열 수 있어야 한다.
    expect(pb.fileExists, isFalse);
    await pb.setGoal('무언가');
    expect(pb.fileExists, isTrue);

    await fileOf(dir).writeAsString('# PLAYBOOK\n'); // 내용만 비운다
    final reloaded = Playbook.forProject(dir.path);
    await reloaded.load();
    expect(reloaded.isEmpty, isTrue);
    expect(reloaded.fileExists, isTrue);
    expect(reloaded.path, endsWith('PLAYBOOK.md'));
  });

  test('★ 쓰기에 실패하면 조용히 넘어가지 않고 던진다', () async {
    // 삼키면 도구가 ok 를 돌려주고 모델은 계획을 적었다고 믿는데 파일에는 아무것도
    // 없다 — 아무도 모르는 채로 계획이 사라진다. `.collabo` 자리에 파일을 놓아 재현.
    final bad = await Directory.systemTemp.createTemp('playbook_bad');
    addTearDown(() {
      try {
        bad.deleteSync(recursive: true);
      } catch (_) {}
    });
    File(p.join(bad.path, '.collabo')).writeAsStringSync('not a directory');
    final broken = Playbook.forProject(bad.path);
    await broken.load(); // 읽기는 관대하다 — 여기서는 안 던진다
    await expectLater(
      broken.setGoal('못 쓸 목표'),
      throwsA(isA<PlaybookWriteException>()),
    );
  });

  test('목표·계획 저장 후 다시 읽어도 그대로', () async {
    await pb.setGoal('로그인 레이스 컨디션을 고친다');
    await pb.setPlan(['재현 테스트를 쓴다', '락을 건다', '테스트를 돌린다']);

    final again = Playbook.forProject(dir.path);
    await again.load();
    expect(again.goalText, '로그인 레이스 컨디션을 고친다');
    expect(again.openSteps.length, 3);
    expect(again.hasPlan, isTrue);
  });

  test('단계 상태 변경 — 번호로도, 텍스트 일부로도', () async {
    await pb.setPlan(['테스트를 쓴다', '락을 건다']);
    expect(await pb.updateStep('1', 'DONE'), isNotNull);
    expect(pb.openSteps, ['락을 건다']);

    final item = await pb.updateStep('락', 'DOING', note: '뮤텍스로');
    expect(item, isNotNull);
    expect(item!.marker, 'DOING');
    expect(item.text, contains('뮤텍스로'));
    // DOING 도 열린 단계다 — 종료 차단이 이걸 본다.
    expect(pb.openSteps.length, 1);
  });

  test('DROP 한 단계는 열린 단계가 아니다', () async {
    await pb.setPlan(['필요 없어진 일']);
    await pb.updateStep('1', 'DROP', note: '요구사항이 바뀜');
    expect(pb.openSteps, isEmpty);
  });

  test('BLOCKED 는 열린 단계가 아니다 — 사용자를 기다리는 상태', () async {
    // 종료 차단을 빠져나가는 **유일한 명시적 경로**다. 답변 문장이 아니라
    // 도구 호출로 표시되므로 모호하지 않다.
    await pb.setPlan(['어느 경로를 쓸지 확인', '그 경로로 작성']);
    await pb.updateStep('1', 'BLOCKED', note: '경로를 사용자에게 물음');
    expect(pb.openSteps, ['그 경로로 작성']);
    expect(pb.blockedSteps, hasLength(1));
    expect(pb.blockedSteps.first, contains('경로를 사용자에게 물음'));
  });

  test('답을 받으면 BLOCKED 를 다시 DOING 으로 되돌릴 수 있다', () async {
    await pb.setPlan(['확인 필요']);
    await pb.updateStep('1', 'BLOCKED');
    await pb.updateStep('1', 'DOING');
    expect(pb.blockedSteps, isEmpty);
    expect(pb.openSteps, hasLength(1));
  });

  test('없는 단계를 가리키면 null', () async {
    await pb.setPlan(['하나']);
    expect(await pb.updateStep('99', 'DONE'), isNull);
    expect(await pb.updateStep('없는 텍스트', 'DONE'), isNull);
  });

  test('메모: 섹션 별칭과 마커 기본값', () async {
    final a = await pb.note('working_model', '이 앱은 SQLite 를 쓴다');
    expect(a!.marker, 'ASSUMED'); // 마커를 안 주면 가장 약한 값

    final b = await pb.note('ruled_out', 'FFI 로 7z 붙이기');
    expect(b!.marker, 'REFUTED'); // RULED OUT 의 기본은 REFUTED

    final c = await pb.note('WORKING MODEL', 'v2 스키마', marker: 'VERIFIED');
    expect(c!.marker, 'VERIFIED');
    expect(pb.section(kSecWorkingModel).length, 2);
  });

  test('같은 문장을 다시 적으면 마커만 갱신된다(쌓이지 않는다)', () async {
    await pb.note('working_model', '포트는 8080 이다', marker: 'ASSUMED');
    await pb.note('working_model', '포트는 8080 이다', marker: 'VERIFIED');
    final items = pb.section(kSecWorkingModel);
    expect(items.length, 1);
    expect(items.first.marker, 'VERIFIED');
  });

  test('알 수 없는 섹션은 WORKING MODEL 로 모은다', () async {
    await pb.note('무슨섹션', '아무거나');
    expect(pb.section(kSecWorkingModel).length, 1);
  });

  test('note 로는 GOAL/PLAN 을 못 건드린다(전용 도구만)', () async {
    await pb.setGoal('진짜 목표');
    await pb.note('GOAL', '가짜 목표');
    expect(pb.goalText, '진짜 목표');
    expect(pb.section(kSecWorkingModel).length, 1);
  });

  test('규격 밖 마커는 가장 약한 값으로 강등해 읽는다', () async {
    await fileOf(dir).parent.create(recursive: true);
    await fileOf(dir).writeAsString('''
# PLAYBOOK

## PLAN
- [MAYBE] 이상한 마커
- 마커가 아예 없는 줄

## WORKING MODEL
- [TOTALLY_SURE] 확신에 찬 헛소리
''');
    await pb.load();
    final steps = pb.section(kSecPlan);
    expect(steps.length, 2);
    expect(steps.every((s) => s.marker == 'TODO'), isTrue);
    expect(pb.section(kSecWorkingModel).first.marker, 'ASSUMED');
  });

  test('CRLF 로 저장된 파일도 읽는다', () async {
    await fileOf(dir).parent.create(recursive: true);
    await fileOf(dir)
        .writeAsString('# PLAYBOOK\r\n\r\n## GOAL\r\n- [ASSUMED] 윈도우에서 쓴 파일\r\n');
    await pb.load();
    expect(pb.goalText, '윈도우에서 쓴 파일');
  });

  test('digest 는 상한을 넘으면 잘리고 전문 위치를 알려 준다', () async {
    await pb.setPlan([for (var i = 0; i < 200; i++) '단계 $i 아주 긴 설명이 붙는다']);
    final d = pb.digest(limit: 300)!;
    expect(d.length, lessThan(400));
    expect(d, contains(kPlaybookPath));
  });

  test('curate: 넘치면 VERIFIED 는 남기고 가정부터 접는다', () async {
    final small = Playbook(fileOf(dir), maxChars: 400);
    for (var i = 0; i < 12; i++) {
      await small.note('working_model', '검증된 사실 $i', marker: 'VERIFIED');
    }
    for (var i = 0; i < 12; i++) {
      await small.note('working_model', '그냥 가정 $i', marker: 'ASSUMED');
    }
    final items = small.section(kSecWorkingModel);
    final verified = items.where((i) => i.marker == 'VERIFIED').length;
    final assumed = items.where((i) => i.marker == 'ASSUMED').length;
    expect(verified, 12, reason: 'VERIFIED 는 20건까지 보존된다');
    expect(assumed, lessThanOrEqualTo(6), reason: '가정부터 접힌다');
  });

  test('계획을 다시 세우면 예전 단계는 남지 않는다', () async {
    await pb.setPlan(['옛 방향 1', '옛 방향 2']);
    await pb.updateStep('1', 'DONE');
    await pb.setPlan(['새 방향']);
    expect(pb.section(kSecPlan).length, 1);
    expect(pb.openSteps, ['새 방향']);
  });

  test('toJson: 웹 계획 카드가 쓰는 모양', () async {
    await pb.setGoal('목표');
    await pb.setPlan(['하나', '둘']);
    await pb.updateStep('1', 'DONE');
    await pb.note('ruled_out', '안 되는 방법');
    final j = pb.toJson();
    expect(j['goal'], '목표');
    expect((j['steps'] as List).length, 2);
    expect(((j['steps'] as List).first as Map)['marker'], 'DONE');
    final notes = j['notes'] as Map;
    expect((notes['ruled_out'] as List).length, 1);
  });
}
