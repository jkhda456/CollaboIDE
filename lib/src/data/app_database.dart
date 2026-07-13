import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 앱 전역 메인 DB. 최근 이력(MRU)과 설정을 보관한다.
///
/// 위치: `<appSupport>/collabo.db`. 프로젝트별 대화 기록은 여기 저장하지 않고
/// 각 프로젝트 폴더의 독립 DB 파일에 남긴다(가져오기 가능한 구조).
class AppDatabase {
  AppDatabase._(this.db, this.dbPath);

  final Database db;
  final String dbPath;

  static const int _schemaVersion = 2;
  static const int maxRecentProjects = 5;

  /// 메인 DB 를 연다(없으면 생성). [initSqliteFfi] 가 먼저 호출돼 있어야 한다.
  ///
  /// [path] 를 주면 그 파일을 쓰고, 없으면 `<appSupport>/collabo.db` 를 쓴다
  /// (테스트에서 임시 경로를 주입하기 위함).
  static Future<AppDatabase> open({String? path}) async {
    if (path == null) {
      final support = await getApplicationSupportDirectory();
      path = p.join(support.path, 'collabo.db');
    }
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    return AppDatabase._(db, path);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE recent_projects (
        path           TEXT PRIMARY KEY,
        label          TEXT NOT NULL DEFAULT '',
        last_opened_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _upgradeSchema(Database db, int oldV, int newV) async {
    // v2 는 (이후 제거된) macOS 보안 범위 북마크 컬럼을 위해 도입됐었다.
    // 샌드박스 폐기 후 그 컬럼은 더 쓰지 않으므로 마이그레이션은 no-op 이다
    // (스키마 버전 정합만 유지 — 기존 v2 DB 의 사용 안 하는 bookmark 컬럼은 무해).
  }

  // --- 설정 (KV, 값은 JSON 문자열) ---

  /// 설정 값을 JSON 으로 저장한다.
  Future<void> setSetting(String key, Object? value) async {
    await db.insert(
      'settings',
      {'key': key, 'value': jsonEncode(value)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 설정 값을 JSON 으로 읽는다(없으면 null).
  Future<Object?> getSetting(String key) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['value'] as String);
  }

  Future<void> removeSetting(String key) async {
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  // --- 최근 프로젝트 (MRU, 최대 5개) ---

  /// 프로젝트를 최근 목록 맨 위로 올린다(upsert). 5개 초과분은 정리한다.
  Future<void> touchRecentProject(String path, {String label = ''}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'recent_projects',
      {
        'path': path,
        'label': label.isEmpty ? p.basename(path) : label,
        'last_opened_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // 최신 maxRecentProjects 개만 남기고 오래된 것 삭제.
    await db.execute(
      'DELETE FROM recent_projects WHERE path NOT IN ('
      '  SELECT path FROM recent_projects '
      '  ORDER BY last_opened_at DESC LIMIT ?'
      ')',
      [maxRecentProjects],
    );
  }

  /// 최근 프로젝트를 **폴더의 마지막 변경 시각** 기준(최신 우선)으로 반환.
  ///
  /// 단순히 여는 것만으로는 순서가 바뀌지 않는다(열기 시각이 아니라 폴더 mtime 으로 정렬).
  /// 목록에 담을 후보는 최근 연 5개로 유지한다.
  Future<List<RecentProject>> recentProjects() async {
    final rows = await db.query(
      'recent_projects',
      orderBy: 'last_opened_at DESC',
      limit: maxRecentProjects,
    );
    final list = rows.map(RecentProject.fromRow).toList();
    DateTime changedAt(RecentProject r) {
      try {
        return Directory(r.path).statSync().modified;
      } catch (_) {
        return r.lastOpenedAt; // 폴더가 없으면 마지막 연 시각으로 대체
      }
    }
    list.sort((a, b) => changedAt(b).compareTo(changedAt(a)));
    return list;
  }

  Future<void> removeRecentProject(String path) async {
    await db.delete('recent_projects', where: 'path = ?', whereArgs: [path]);
  }

  Future<void> close() => db.close();
}

/// 최근 프로젝트 항목.
class RecentProject {
  const RecentProject({
    required this.path,
    required this.label,
    required this.lastOpenedAt,
  });

  final String path;
  final String label;
  final DateTime lastOpenedAt;

  factory RecentProject.fromRow(Map<String, Object?> row) => RecentProject(
        path: row['path'] as String,
        label: row['label'] as String? ?? '',
        lastOpenedAt:
            DateTime.fromMillisecondsSinceEpoch(row['last_opened_at'] as int),
      );
}
