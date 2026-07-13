import 'dart:io';

import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late AppDatabase appDb;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_main_');
    appDb = await AppDatabase.open(path: p.join(tmp.path, 'collabo.db'));
  });

  tearDown(() async {
    await appDb.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('설정을 JSON 으로 저장/조회한다', () async {
    await appDb.setSetting('model', {'provider': 'anthropic', 'name': 'opus'});
    final v = await appDb.getSetting('model') as Map;
    expect(v['provider'], 'anthropic');
    expect(v['name'], 'opus');
    expect(await appDb.getSetting('absent'), isNull);
  });

  test('최근 프로젝트는 MRU 순이며 최대 5개만 유지된다', () async {
    for (var i = 1; i <= 7; i++) {
      await appDb.touchRecentProject('/proj/p$i');
    }
    final recent = await appDb.recentProjects();
    expect(recent, hasLength(AppDatabase.maxRecentProjects));
    // 가장 최근 touch 한 p7 이 맨 위.
    expect(recent.first.path, '/proj/p7');
    // 가장 오래된 p1, p2 는 정리됨.
    expect(recent.map((r) => r.path), isNot(contains('/proj/p1')));
  });

  test('같은 경로를 다시 열면 맨 위로 올라온다', () async {
    await appDb.touchRecentProject('/proj/a');
    await appDb.touchRecentProject('/proj/b');
    await appDb.touchRecentProject('/proj/a');
    final recent = await appDb.recentProjects();
    expect(recent.first.path, '/proj/a');
    expect(recent, hasLength(2));
  });

  test('v1 → v2 마이그레이션: 기존 데이터가 보존된다', () async {
    final dir = await Directory.systemTemp.createTemp('collabo_mig_');
    final path = p.join(dir.path, 'old.db');
    // 구버전(v1) 스키마.
    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
              'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
          await db.execute('CREATE TABLE recent_projects ('
              'path TEXT PRIMARY KEY, label TEXT NOT NULL DEFAULT \'\', '
              'last_opened_at INTEGER NOT NULL)');
        },
      ),
    );
    await v1.insert('recent_projects',
        {'path': '/proj/old', 'label': 'old', 'last_opened_at': 1});
    await v1.close();

    // AppDatabase.open 은 v2 로 업그레이드하며 기존 데이터를 보존한다.
    final migrated = await AppDatabase.open(path: path);
    expect((await migrated.recentProjects()).map((r) => r.path),
        contains('/proj/old'));
    // 업그레이드 후에도 최근 프로젝트를 정상적으로 갱신할 수 있다.
    await migrated.touchRecentProject('/proj/new');
    expect((await migrated.recentProjects()).map((r) => r.path),
        contains('/proj/new'));
    await migrated.close();
    await dir.delete(recursive: true);
  });
}
