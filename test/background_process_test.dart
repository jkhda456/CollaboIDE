import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/process/background_process_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// `.collabo/proc` 레지스트리의 **Dart 쪽 끝**을 잠근다.
///
/// 파일을 쓰는 것은 파이썬(`proc_runner.py` / `term_runner.py`)이고 읽는 것은
/// 여기다. 한쪽만 바뀌면 조용히 어긋나는 자리라, 파이썬 테스트(`test_term.py`)가
/// 키 이름이 나가는지를 보고 이 테스트가 그 키를 읽어 내는지를 본다
/// (웹 검색 통로에서 쓴 것과 같은 방식 — §note 2 "테스트").
void main() {
  late Directory tmp;
  late Directory procRoot;
  late BackgroundProcessRegistry reg;

  /// procdir 하나를 손으로 만든다(파이썬이 쓰는 모양 그대로).
  String makeProc(String id, Map<String, Object?> meta) {
    final dir = Directory(p.join(procRoot.path, id))..createSync(recursive: true);
    File(p.join(dir.path, 'meta.json')).writeAsStringSync(jsonEncode(meta));
    return dir.path;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_proc_');
    procRoot = Directory(p.join(tmp.path, '.collabo', 'proc'))
      ..createSync(recursive: true);
    reg = BackgroundProcessRegistry();
    reg.attachProject(tmp.path);
  });

  tearDown(() async {
    reg.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('명령은 kind 없이도 읽힌다 (예전 기록 호환)', () {
    makeProc('a', {
      'id': 'a',
      'pid': 111,
      'command': 'npm test',
      'cwd': tmp.path,
      'status': 'running',
      'started_at': 1700000000.0,
    });
    reg.refresh();

    final proc = reg.processes.single;
    expect(proc.kind, BackgroundKind.command);
    expect(proc.isTerminal, isFalse);
    expect(proc.isRunning, isTrue);
    expect(proc.label, 'npm test', reason: '이름이 없으면 명령을 보여 준다');
    expect(reg.runningCount, 1);
  });

  test('터미널은 kind 로 갈라지고 이름·PTY 여부를 읽는다', () {
    makeProc('t', {
      'id': 't',
      'kind': 'terminal',
      'pid': 222,
      'command': '/bin/zsh',
      'name': 'server',
      'pty': false,
      'cwd': tmp.path,
      'cols': 120,
      'rows': 32,
      'status': 'running',
      'started_at': 1700000000.0,
    });
    reg.refresh();

    final proc = reg.processes.single;
    expect(proc.kind, BackgroundKind.terminal);
    expect(proc.isTerminal, isTrue);
    expect(proc.name, 'server');
    expect(proc.label, 'server', reason: '이름을 붙였으면 이름이 이긴다');
    expect(proc.hasPty, isFalse, reason: '폴백이면 화면에 그 사실을 적어야 한다');
    // 터미널이 읽는 파일들의 자리(파이썬이 쓰는 이름과 같아야 한다).
    expect(p.basename(proc.screenPath), 'screen.json');
    expect(p.basename(proc.scrollbackPath), 'scrollback.txt');
    expect(p.basename(proc.ctrlPath), 'ctrl');
  });

  test('pty 키가 없으면 PTY 가 있는 것으로 본다', () {
    makeProc('t', {'id': 't', 'kind': 'terminal', 'status': 'running'});
    reg.refresh();
    expect(reg.processes.single.hasPty, isTrue);
  });

  test('명령과 터미널이 한 목록에 같이 온다 (실행 중이 먼저)', () {
    makeProc('done', {
      'id': 'done',
      'command': 'ls',
      'status': 'exited',
      'exit_code': 0,
      'started_at': 1700000100.0,
    });
    makeProc('live', {
      'id': 'live',
      'kind': 'terminal',
      'command': 'zsh',
      'status': 'running',
      'started_at': 1700000000.0,
    });
    reg.refresh();

    expect(reg.processes.map((e) => e.id), ['live', 'done'],
        reason: '진행 상태 화면은 돌고 있는 것을 위에 둔다');
    expect(reg.runningCount, 1);
  });

  /// ★ 터미널에서 Enter 는 **CR** 이다. LF 를 보내면 셸이 줄을 실행하지 않고
  /// 그대로 앉아 있어, 사용자에게는 "입력이 먹지 않는다" 로 보인다.
  test('입력 줄 끝은 명령이면 LF, 터미널이면 CR', () async {
    makeProc('cmd', {'id': 'cmd', 'command': 'python', 'status': 'running'});
    makeProc('term', {'id': 'term', 'kind': 'terminal', 'status': 'running'});
    reg.refresh();

    await reg.sendInput('cmd', 'print(1)');
    await reg.sendInput('term', 'ls -al');

    final cmdIn = File(p.join(procRoot.path, 'cmd', 'stdin')).readAsStringSync();
    final termIn = File(p.join(procRoot.path, 'term', 'stdin')).readAsStringSync();
    expect(cmdIn, 'print(1)\n');
    expect(termIn, 'ls -al\r');
  });

  test('sendRaw 는 아무것도 덧붙이지 않는다 (ctrl-c·방향키)', () async {
    makeProc('term', {'id': 'term', 'kind': 'terminal', 'status': 'running'});
    reg.refresh();

    await reg.sendRaw('term', '\x03');
    await reg.sendRaw('term', '\x1b[A');

    final data = File(p.join(procRoot.path, 'term', 'stdin')).readAsStringSync();
    expect(data, '\x03\x1b[A',
        reason: '줄바꿈이 붙으면 ctrl-c 뒤에 엔터를 한 번 더 치는 셈이 된다');
  });

  test('창 크기 변경은 ctrl 통로에 줄 단위 JSON 으로 나간다', () async {
    makeProc('term', {'id': 'term', 'kind': 'terminal', 'status': 'running'});
    reg.refresh();

    await reg.resizeTerminal('term', 100, 30);

    final ctrl = File(p.join(procRoot.path, 'term', 'ctrl')).readAsStringSync();
    expect(ctrl, '{"resize":[100,30]}\n',
        reason: '파이썬 term_runner 가 이 모양으로 읽는다');
  });

  test('명령에는 창 크기라는 것이 없어 아무것도 쓰지 않는다', () async {
    makeProc('cmd', {'id': 'cmd', 'command': 'ls', 'status': 'running'});
    reg.refresh();

    await reg.resizeTerminal('cmd', 100, 30);

    expect(File(p.join(procRoot.path, 'cmd', 'ctrl')).existsSync(), isFalse);
  });

  test('끝난 터미널에는 크기 변경을 보내지 않는다', () async {
    makeProc('term', {'id': 'term', 'kind': 'terminal', 'status': 'exited'});
    reg.refresh();

    await reg.resizeTerminal('term', 80, 24);

    expect(File(p.join(procRoot.path, 'term', 'ctrl')).existsSync(), isFalse);
  });

  test('깨진 meta.json 은 목록에서 조용히 빠진다', () {
    final dir = Directory(p.join(procRoot.path, 'broken'))..createSync();
    File(p.join(dir.path, 'meta.json')).writeAsStringSync('{not json');
    makeProc('good', {'id': 'good', 'command': 'ls', 'status': 'running'});
    reg.refresh();

    expect(reg.processes.map((e) => e.id), ['good']);
  });
}
