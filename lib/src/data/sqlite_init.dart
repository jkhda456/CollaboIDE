import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 데스크톱(Windows/Linux/macOS)에서 sqflite 의 FFI 백엔드를 활성화한다.
///
/// 앱 시작 시 1회 호출하면 메인 DB([AppDatabase])와 프로젝트 대화 DB
/// ([ConversationStore])가 모두 같은 전역 [databaseFactory] 를 공유한다.
void initSqliteFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
