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
