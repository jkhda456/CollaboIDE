import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/process/background_process_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late BackgroundProcessRegistry reg;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_proc_');
    reg = BackgroundProcessRegistry();
  });

  tearDown(() async {
    reg.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> writeProc(String id, Map<String, Object?> meta,
      {String stdout = ''}) async {
    final d = Directory(p.join(tmp.path, '.collabo', 'proc', id));
    await d.create(recursive: true);
    await File(p.join(d.path, 'meta.json')).writeAsString(jsonEncode(meta));
    await File(p.join(d.path, 'stdout.log')).writeAsString(stdout);
    await File(p.join(d.path, 'stderr.log')).writeAsString('');
  }

  test('proc 디렉토리를 읽어 목록화하고 실행 중을 먼저 정렬한다', () async {
    await writeProc('aaa', {
      'id': 'aaa', 'pid': 111, 'command': 'echo done', 'cwd': '',
      'started_at': 100, 'status': 'exited', 'exit_code': 0,
    });
    await writeProc('bbb', {
      'id': 'bbb', 'pid': 222, 'command': 'serve', 'cwd': '',
      'started_at': 200, 'status': 'running',
    });
    reg.attachProject(tmp.path);

    expect(reg.processes.length, 2);
    expect(reg.runningCount, 1);
    // 실행 중(bbb)이 먼저.
    expect(reg.processes.first.id, 'bbb');
    final done = reg.processes.firstWhere((e) => e.id == 'aaa');
    expect(done.status, BackgroundStatus.exited);
    expect(done.exitCode, 0);
    expect(done.pid, 111);
  });

  test('sendInput 은 stdin 파일에 개행과 함께 append 한다', () async {
    await writeProc('ccc', {
      'id': 'ccc', 'pid': 333, 'command': 'read', 'cwd': '',
      'started_at': 1, 'status': 'running',
    });
    reg.attachProject(tmp.path);

    await reg.sendInput('ccc', 'hello');
    await reg.sendInput('ccc', 'world\n');
    final stdin = File(p.join(tmp.path, '.collabo', 'proc', 'ccc', 'stdin'));
    expect(await stdin.readAsString(), 'hello\nworld\n');
  });

  test('프로젝트 미첨부/빈 경로면 목록이 비어 있다', () {
    reg.attachProject(null);
    expect(reg.processes, isEmpty);
    expect(reg.runningCount, 0);
  });
}
