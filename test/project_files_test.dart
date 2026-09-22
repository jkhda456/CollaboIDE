import 'dart:async';
import 'dart:io';

import 'package:collabo_ide/src/files/project_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 네이티브 트리의 모델([ProjectFiles]) — 예전 `web_bridge_fs_test` 의 가드 검사를 그대로
/// 옮기고(웹 메시지 대신 직접 부른다), 트리 상태(펼침·선택·검색·감시)를 더했다.
///
/// 가드의 핵심은 "프로젝트 안이고 `.collabo` 가 아닌 것만 건드린다" 이다. 통과하면 실제로
/// 반영되는지, 막히면 **디스크가 그대로인지** 양쪽을 확인한다.
void main() {
  late Directory tmp;
  late Directory project;
  late ProjectFiles files;
  late List<String> errors;
  late List<FsOpEvent> events;
  late List<FsChange> changes;
  final subs = <StreamSubscription<Object?>>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_files_');
    project = Directory(p.join(tmp.path, 'proj'));
    await project.create();
    files = ProjectFiles(project.path);
    errors = [];
    events = [];
    changes = [];
    subs
      ..add(files.errors.listen(errors.add))
      ..add(files.events.listen(events.add))
      ..add(files.changes.listen(changes.add));
  });

  tearDown(() async {
    for (final s in subs) {
      await s.cancel();
    }
    subs.clear();
    files.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> until(bool Function() ok, String what) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(ok(), isTrue, reason: 'timed out: $what');
  }

  group('새로 만들기', () {
    test('폴더 안에 파일을 만들고 알린다 — 만든 파일이 선택된다', () async {
      final made = await files.create(project.path, 'note.md', dir: false);
      expect(made, p.join(project.path, 'note.md'));
      expect(File(made!).existsSync(), isTrue);
      final e = events.single as FsCreated;
      expect(e.isDir, isFalse);
      expect(p.equals(e.path, made), isTrue);
      expect(files.selected, made);
    });

    test('폴더도 만든다', () async {
      await files.create(project.path, 'src', dir: true);
      expect((events.single as FsCreated).isDir, isTrue);
      expect(Directory(p.join(project.path, 'src')).existsSync(), isTrue);
    });

    test('하위 폴더에 만들면 그 폴더가 펼쳐지고 새 파일이 보인다 — 한 번도 안 펼친 폴더여도', () async {
      final sub = Directory(p.join(project.path, 'sub'))..createSync();
      await files.start();
      await files.create(sub.path, 'a.txt', dir: false);
      expect(files.isExpanded(sub.path), isTrue);
      await until(() => files.visibleRows.any((r) => r.entry.name == 'a.txt'),
          'the never-opened folder to be read');
    });

    test('이미 있는 이름은 덮어쓰지 않는다', () async {
      final f = File(p.join(project.path, 'note.md'))..writeAsStringSync('원본');
      expect(await files.create(project.path, 'note.md', dir: false), isNull);
      expect(errors, isNotEmpty);
      expect(f.readAsStringSync(), '원본');
    });

    test('이름 규칙(경로 구분자·예약어)을 어기면 만들지 않는다', () async {
      for (final name in ['a/b', '..', 'CON', 'end.', '']) {
        errors.clear();
        expect(await files.create(project.path, name, dir: false), isNull, reason: name);
        expect(errors, isNotEmpty, reason: '이름 "$name" 은 막혀야 한다');
      }
      expect(project.listSync(), isEmpty);
    });

    test('프로젝트 밖 폴더에는 만들지 않는다', () async {
      expect(await files.create(tmp.path, 'evil.txt', dir: false), isNull);
      expect(errors, isNotEmpty);
      expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
    });
  });

  group('이름 변경 · 이동', () {
    test('같은 폴더 안에서 이름을 바꾸고 알린다', () async {
      final f = File(p.join(project.path, 'old.md'))..writeAsStringSync('내용');
      final to = await files.rename(f.path, 'new.md');
      expect(to, p.join(project.path, 'new.md'));
      final e = events.single as FsMoved;
      expect(p.equals(e.from, f.path), isTrue);
      expect(p.equals(e.to, to!), isTrue);
      expect(f.existsSync(), isFalse);
      expect(File(to).readAsStringSync(), '내용');
    });

    test('이미 있는 이름으로는 바꾸지 않는다', () async {
      final a = File(p.join(project.path, 'a.md'))..writeAsStringSync('A');
      final b = File(p.join(project.path, 'b.md'))..writeAsStringSync('B');
      expect(await files.rename(a.path, 'b.md'), isNull);
      expect(errors, isNotEmpty);
      expect(a.readAsStringSync(), 'A');
      expect(b.readAsStringSync(), 'B');
    });

    test('프로젝트 루트 자신은 바꿀 수 없다', () async {
      expect(await files.rename(project.path, 'other'), isNull);
      expect(errors, isNotEmpty);
      expect(project.existsSync(), isTrue);
    });

    test('펼쳐 둔 폴더의 이름을 바꿔도 펼침·선택이 따라간다', () async {
      final dir = Directory(p.join(project.path, 'src'))..createSync();
      File(p.join(dir.path, 'main.dart')).writeAsStringSync('x');
      await files.start();
      files.toggle(dir.path);
      files.select(p.join(dir.path, 'main.dart'));
      final to = await files.rename(dir.path, 'lib');
      expect(files.isExpanded(to!), isTrue);
      expect(files.selected, p.join(to, 'main.dart'));
      expect(files.isExpanded(dir.path), isFalse);
      await until(
          () => files.visibleRows.any((r) => r.depth == 1 && r.entry.path == p.join(to, 'main.dart')),
          'the renamed folder to show its contents again');
    });

    test('폴더로 옮기고(이동) 복사한다', () async {
      final f = File(p.join(project.path, 'a.txt'))..writeAsStringSync('A');
      final dst = Directory(p.join(project.path, 'dst'))..createSync();
      final copied = await files.move(f.path, dst.path, copy: true);
      expect(File(copied!).readAsStringSync(), 'A');
      expect(f.existsSync(), isTrue, reason: '복사는 원본을 남긴다');
      File(copied).deleteSync();
      final moved = await files.move(f.path, dst.path);
      expect(File(moved!).readAsStringSync(), 'A');
      expect(f.existsSync(), isFalse);
      expect(events.whereType<FsMoved>().length, 1, reason: '복사는 FsMoved 를 내지 않는다');
    });

    test('폴더를 자기 안으로는 옮길 수 없다', () async {
      final dir = Directory(p.join(project.path, 'a'))..createSync();
      final inner = Directory(p.join(dir.path, 'b'))..createSync();
      expect(await files.move(dir.path, inner.path), isNull);
      expect(errors, isNotEmpty);
    });
  });

  group('삭제', () {
    test('파일을 지우고 알린다', () async {
      final f = File(p.join(project.path, 'note.md'))..writeAsStringSync('내용');
      expect(await files.delete(f.path), isTrue);
      expect(p.equals((events.single as FsDeleted).path, f.path), isTrue);
      expect(f.existsSync(), isFalse);
    });

    test('폴더는 안에 든 것까지 지우고, 그 안의 선택·펼침도 버린다', () async {
      final dir = Directory(p.join(project.path, 'src'))..createSync();
      File(p.join(dir.path, 'main.dart')).writeAsStringSync('void main() {}');
      await files.start();
      files.toggle(dir.path);
      files.select(p.join(dir.path, 'main.dart'));
      expect(await files.delete(dir.path), isTrue);
      expect(dir.existsSync(), isFalse);
      expect(files.selected, isNull);
      expect(files.isExpanded(dir.path), isFalse);
    });

    test('프로젝트 루트는 지울 수 없다', () async {
      expect(await files.delete(project.path), isFalse);
      expect(errors, isNotEmpty);
      expect(project.existsSync(), isTrue);
    });

    test('프로젝트 밖은 지울 수 없다', () async {
      final outside = File(p.join(tmp.path, 'outside.md'))..writeAsStringSync('원본');
      expect(await files.delete(outside.path), isFalse);
      expect(outside.existsSync(), isTrue);
    });

    test('형제 prefix 경로(proj-evil)도 프로젝트 밖으로 본다', () async {
      final sibling = Directory(p.join(tmp.path, 'proj-evil'))..createSync();
      expect(await files.delete(sibling.path), isFalse);
      expect(errors, isNotEmpty);
      expect(sibling.existsSync(), isTrue);
    });
  });

  group('.collabo 는 앱이 관리한다', () {
    late Directory collabo;

    setUp(() async {
      collabo = Directory(p.join(project.path, '.collabo'))..createSync();
      File(p.join(collabo.path, 'conversation.db')).writeAsStringSync('db');
    });

    test('폴더 자체를 지울 수 없다', () async {
      expect(await files.delete(collabo.path), isFalse);
      expect(collabo.existsSync(), isTrue);
    });

    test('안에 든 파일도 지울 수 없다', () async {
      final db = File(p.join(collabo.path, 'conversation.db'));
      expect(await files.delete(db.path), isFalse);
      expect(db.existsSync(), isTrue);
    });

    test('이름도 바꿀 수 없다', () async {
      expect(await files.rename(collabo.path, 'x'), isNull);
      expect(collabo.existsSync(), isTrue);
    });

    test('드래그로 옮길 수도 없다', () async {
      final dst = Directory(p.join(project.path, 'sub'))..createSync();
      expect(await files.move(collabo.path, dst.path), isNull);
      expect(collabo.existsSync(), isTrue);
      expect(Directory(p.join(dst.path, '.collabo')).existsSync(), isFalse);
    });
  });

  group('트리 상태', () {
    test('루트를 읽고, 폴더는 펼칠 때 읽는다 — 펼친 것만 평면 목록에 나온다', () async {
      final src = Directory(p.join(project.path, 'src'))..createSync();
      File(p.join(src.path, 'a.dart')).writeAsStringSync('');
      File(p.join(project.path, 'README.md')).writeAsStringSync('');
      await files.start();
      List<String> names() => [for (final r in files.visibleRows) '${r.depth}:${r.entry.name}'];
      expect(names(), containsAll(['0:src', '0:README.md']));
      expect(names(), isNot(contains('1:a.dart')));
      files.toggle(src.path);
      await until(() => names().contains('1:a.dart'), 'the folder to load');
      files.toggle(src.path);
      expect(names(), isNot(contains('1:a.dart')), reason: '접으면 사라진다(캐시는 남는다)');
    });

    test('reveal 은 조상 폴더를 펼치고 그 파일을 선택한다', () async {
      final deep = Directory(p.join(project.path, 'a', 'b'))..createSync(recursive: true);
      final f = File(p.join(deep.path, 'x.txt'))..writeAsStringSync('');
      await files.start();
      files.reveal(f.path);
      expect(files.isExpanded(p.join(project.path, 'a')), isTrue);
      expect(files.isExpanded(deep.path), isTrue);
      expect(files.selected, f.path);
      await until(() => files.visibleRows.any((r) => r.entry.name == 'x.txt'), 'the file to show');
    });

    test('파일명 검색 — 빈 검색어면 트리로 돌아간다', () async {
      Directory(p.join(project.path, 'lib')).createSync();
      File(p.join(project.path, 'lib', 'widget_tree.dart')).writeAsStringSync('');
      await files.search('tree');
      expect(files.searching, isTrue);
      expect(files.results!.map((e) => e.name), contains('widget_tree.dart'));
      await files.search('');
      expect(files.searching, isFalse);
    });

    test('밖에서 생긴 파일도 감시자가 트리에 반영하고 알린다', () async {
      await files.start();
      File(p.join(project.path, 'late.txt')).writeAsStringSync('x');
      await until(() => files.visibleRows.any((r) => r.entry.name == 'late.txt'), 'the watcher');
      expect(changes.expand((c) => c.files).any((f) => p.basename(f) == 'late.txt'), isTrue);
    });

    test('계획 파일이 생기면 알아챈다(트리 머리의 바로가기)', () async {
      await files.start();
      expect(files.playbookExists, isFalse);
      Directory(p.join(project.path, '.collabo')).createSync();
      File(files.playbookPath).writeAsStringSync('# PLAYBOOK');
      await until(() => files.playbookExists, 'the playbook to be noticed');
    });
  });
}
