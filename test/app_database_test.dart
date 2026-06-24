import 'dart:io';

import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
}
