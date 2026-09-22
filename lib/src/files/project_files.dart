import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../fs/entry_name.dart';
import '../fs/file_service.dart';

/// 파일이 바뀌었다(감시자 · 사용자 조작). [dirs] 는 다시 읽을 부모 디렉토리, [files] 는
/// 바뀐 경로 자체(뷰어가 보고 있는 파일이면 다시 읽는다).
class FsChange {
  const FsChange({this.dirs = const [], this.files = const []});
  final List<String> dirs;
  final List<String> files;
}

/// 사용자가 트리에서 한 조작의 결과. 뷰어가 따라 맞춘다(이름이 바뀐 파일을 계속 보거나,
/// 지워진 파일을 닫는다).
sealed class FsOpEvent {
  const FsOpEvent();
}

class FsCreated extends FsOpEvent {
  const FsCreated(this.path, {required this.isDir});
  final String path;
  final bool isDir;
}

/// 이름 변경과 이동 둘 다(경로가 [from] 에서 [to] 로 바뀌었다).
class FsMoved extends FsOpEvent {
  const FsMoved(this.from, this.to);
  final String from;
  final String to;
}

class FsDeleted extends FsOpEvent {
  const FsDeleted(this.path);
  final String path;
}

/// 트리에 그릴 한 줄(펼친 폴더만 따라 내려간 평면 목록).
class TreeRow {
  const TreeRow(this.entry, this.depth);
  final FsEntry entry;
  final int depth;
}

/// **프로젝트 하나의 파일 트리** — 네이티브 트리 화면의 모델이자, 파일 조작의 유일한 창구.
///
/// 예전에는 이 일을 웹(index.html)이 트리를 그리고 [WebBridge] 가 읽기·감시·조작을 대신해
/// 주는 식으로 나눠 했다. 모바일 준비로 트리를 네이티브로 옮기면서 **상태(목록 캐시·펼침·
/// 선택·검색)와 가드가 한 곳**에 모였다. 세션([ProjectSession])이 소유한다 — 화면이
/// 없어도 감시는 돈다(에이전트가 먼저 일을 시작할 수 있다).
///
/// - **펼친 폴더만** 읽어 둔다. 감시자가 바뀐 디렉토리를 알려 오면 **이미 읽어 둔 것만**
///   다시 읽는다 — 그래서 트리가 접히지 않는다(예전 웹 트리와 같은 규칙).
/// - 사용자 조작(이동·복사·만들기·이름 변경·삭제)은 **전부 [_resolveUserPath] 를 지난다**:
///   프로젝트 안 · 심링크 풀어 비교 · 형제 prefix 차단 · `.collabo` 금지 · 루트는 부모로만.
/// - 실패 이유는 [errors] 로, 결과는 [events] 로 나간다(뷰어가 따라 맞춘다).
class ProjectFiles extends ChangeNotifier {
  ProjectFiles(this.root, {FileService? fileService})
      : fs = fileService ?? FileService();

  /// 프로젝트 루트. 세션의 정체라 바뀌지 않는다.
  final String root;
  final FileService fs;

  /// 앱이 관리하는 폴더. 트리에서 옮기거나 지우지 못한다 — 대화 DB·venv·백그라운드
  /// 명령 레지스트리가 **열린 채로** 사라질 수 있다.
  static const String appDirName = '.collabo';

  /// 계획 파일(하니스 — `agent/playbook.dart` 의 `kPlaybookPath` 와 같은 자리).
  String get playbookPath => p.join(root, appDirName, 'PLAYBOOK.md');

  final Map<String, List<FsEntry>> _children = {};
  final Set<String> _expanded = {};
  final Set<String> _loading = {};
  String? _selected;
  bool _playbookExists = false;

  String _query = '';
  List<FsEntry>? _results;
  int _searchSeq = 0;

  // 동기 전달 — 조작(create/rename/...)이 돌아올 때는 뷰어·화면이 이미 따라와 있다
  // (비동기면 "만들었는데 뷰어가 아직 옛 파일" 같은 틈이 생긴다). 내보내는 곳은 이
  // 클래스뿐이고 구독자가 여기로 다시 쓰지 않으니 재진입 걱정은 없다.
  final _changes = StreamController<FsChange>.broadcast(sync: true);
  final _events = StreamController<FsOpEvent>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);

  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _flushTimer;
  final Set<String> _pendingDirs = {};
  final Set<String> _pendingFiles = {};
  bool _started = false;
  bool _disposed = false;

  /// 파일 변경(감시자 + 사용자 조작). 뷰어 자동 갱신 · 대화 헤더의 "마지막 변경" 이 듣는다.
  Stream<FsChange> get changes => _changes.stream;

  /// 사용자 조작의 결과.
  Stream<FsOpEvent> get events => _events.stream;

  /// 사용자에게 보일 실패 이유(영어 — 경로를 담는다).
  Stream<String> get errors => _errors.stream;

  // ------------------------------------------------------------------ 조회

  /// 그 폴더의 항목(아직 안 읽었으면 null).
  List<FsEntry>? childrenOf(String dir) => _children[dir];
  bool isExpanded(String dir) => _expanded.contains(dir);
  bool isLoading(String dir) => _loading.contains(dir);
  String? get selected => _selected;

  /// 계획 파일이 실제로 있는가(트리 머리의 "계획 파일 열기" 버튼).
  bool get playbookExists => _playbookExists;

  /// 파일명 검색 중인가(검색어가 있으면 트리 대신 결과 목록을 그린다).
  bool get searching => _query.isNotEmpty;
  String get query => _query;

  /// 검색 결과(아직 안 왔으면 null).
  List<FsEntry>? get results => _results;

  /// 펼친 폴더를 따라 내려간 평면 목록. 아직 안 읽은 폴더는 빈 자식으로 본다.
  List<TreeRow> get visibleRows {
    final out = <TreeRow>[];
    void walk(String dir, int depth) {
      for (final e in _children[dir] ?? const <FsEntry>[]) {
        out.add(TreeRow(e, depth));
        if (e.isDir && _expanded.contains(e.path)) walk(e.path, depth + 1);
      }
    }

    walk(root, 0);
    return out;
  }

  // ------------------------------------------------------------------ 수명

  /// 루트를 읽고 감시를 시작한다. 두 번 불러도 한 번만 한다.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      _watchSub = fs.watch(root).listen(_onFsEvent, onError: (_) {});
    } catch (_) {
      // 감시 불가(권한/플랫폼) — 수동 새로고침으로 대체된다.
    }
    await refresh(root);
    await _checkPlaybook();
  }

  /// 그 폴더를 (다시) 읽는다.
  Future<void> refresh(String dir) async {
    if (_disposed) return;
    _loading.add(dir);
    _notify();
    List<FsEntry> entries;
    try {
      entries = await fs.listDirectory(dir);
    } catch (_) {
      entries = const [];
    }
    if (_disposed) return;
    _loading.remove(dir);
    _children[dir] = entries;
    _notify();
  }

  /// 폴더를 펼치거나 접는다. 처음 펼칠 때 읽는다.
  void toggle(String dir) {
    if (_expanded.remove(dir)) {
      _notify();
      return;
    }
    _expanded.add(dir);
    _notify();
    if (!_children.containsKey(dir)) unawaited(refresh(dir));
  }

  /// 그 경로가 보이도록 조상 폴더를 모두 펼친다(만든 파일·계획 파일을 열 때).
  void reveal(String path) {
    var dir = p.dirname(path);
    final chain = <String>[];
    while (p.isWithin(root, dir)) {
      chain.insert(0, dir);
      dir = p.dirname(dir);
    }
    for (final d in chain) {
      _expanded.add(d);
      if (!_children.containsKey(d)) unawaited(refresh(d));
    }
    _selected = path;
    _notify();
  }

  void select(String? path) {
    if (_selected == path) return;
    _selected = path;
    _notify();
  }

  /// 파일명 검색. 빈 검색어면 트리로 돌아간다. 늦게 온 결과(다음 검색어가 이미 왔다)는 버린다.
  Future<void> search(String query) async {
    final q = query.trim();
    final seq = ++_searchSeq;
    _query = q;
    _results = null;
    _notify();
    if (q.isEmpty) return;
    List<FsEntry> found;
    try {
      found = await fs.findByName(root, q);
    } catch (_) {
      found = const [];
    }
    if (_disposed || seq != _searchSeq) return;
    _results = found;
    _notify();
  }

  // ------------------------------------------------------------------ 감시

  /// 변경 이벤트는 영향받은 **부모 디렉토리**(트리 갱신)와 **바뀐 경로**(뷰어 갱신)를 모아
  /// 디바운스 후 한 번에 처리한다.
  void _onFsEvent(FileSystemEvent event) {
    _pendingDirs.add(p.dirname(event.path));
    _pendingFiles.add(event.path);
    if (event is FileSystemMoveEvent && event.destination != null) {
      _pendingDirs.add(p.dirname(event.destination!));
      _pendingFiles.add(event.destination!);
    }
    _flushTimer ??= Timer(const Duration(milliseconds: 200), _flush);
  }

  void _flush() {
    _flushTimer = null;
    final dirs = _pendingDirs.toList();
    final files = _pendingFiles.toList();
    _pendingDirs.clear();
    _pendingFiles.clear();
    if (_disposed || (dirs.isEmpty && files.isEmpty)) return;
    _announce(FsChange(dirs: dirs, files: files));
  }

  /// 변경을 반영한다: **이미 읽어 둔** 폴더만 다시 읽고(트리가 접히지 않게), 구독자에게 알린다.
  void _announce(FsChange change) {
    for (final d in change.dirs.toSet()) {
      if (_children.containsKey(d)) unawaited(refresh(d));
    }
    unawaited(_checkPlaybook());
    if (!_changes.isClosed) _changes.add(change);
  }

  Future<void> _checkPlaybook() async {
    final exists = await File(playbookPath).exists();
    if (exists != _playbookExists) {
      _playbookExists = exists;
      _notify();
    }
  }

  // ------------------------------------------------------------------ 조작

  void _fail(String message) {
    if (!_errors.isClosed) _errors.add(message);
  }

  void _emit(FsOpEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  /// 심링크를 푼 루트(가드가 비교에 쓴다).
  String? _realRoot;

  /// 가드가 준 **실제 경로**를 트리가 쓰는 **루트 기준 경로**로 되돌린다.
  ///
  /// 루트가 심링크 아래 있으면(macOS 의 `/var` → `/private/var` 가 흔하다) 둘이 달라서,
  /// 되돌리지 않으면 트리 캐시·선택·뷰어 경로가 서로 어긋난다.
  String _display(String real) {
    final rr = _realRoot;
    if (rr == null) return real;
    if (p.equals(real, rr)) return root;
    return p.isWithin(rr, real) ? p.join(root, p.relative(real, from: rr)) : real;
  }

  /// 사용자가 트리에서 지시한 경로를 검증한다(이동/복사/생성/이름 변경/삭제 공용).
  ///
  /// 통과하면 **심링크를 푼 실제 경로**, 아니면 null(이유는 [errors] 로 보냈다).
  /// [allowRoot] — 루트 자신은 새로 만들 때의 **부모**로만 된다.
  Future<String?> _resolveUserPath(String? path, {bool allowRoot = false}) async {
    if (path == null || path.isEmpty) return null;
    final String real;
    final String realRoot;
    try {
      realRoot = _realRoot = await Directory(root).resolveSymbolicLinks();
      real = await File(path).absolute.resolveSymbolicLinks();
    } catch (e) {
      // 존재하지 않는 경로도 여기로 온다(resolveSymbolicLinks 가 던진다).
      _fail('$e');
      return null;
    }
    if (p.equals(real, realRoot)) {
      if (allowRoot) return real;
      _fail('The project root cannot be changed here.');
      return null;
    }
    // isWithin 은 형제 prefix 탈출(`/proj-evil` vs `/proj`)을 걸러 준다.
    if (!p.isWithin(realRoot, real)) {
      _fail('Outside the project: $path');
      return null;
    }
    if (p.split(p.relative(real, from: realRoot)).first == appDirName) {
      _fail('$appDirName is managed by the app.');
      return null;
    }
    return real;
  }

  /// 새 이름을 검사해 다듬은 값을 준다. 규칙은 새 프로젝트와 같다(`fs/entry_name.dart`) —
  /// 화면의 입력 창도 같은 함수로 미리 막지만 판정은 여기가 최종이다.
  String? _checkName(String? raw) {
    final name = (raw ?? '').trim();
    if (validateProjectName(name) != null) {
      _fail('Invalid name: ${raw ?? ''}');
      return null;
    }
    return name;
  }

  /// 항목을 폴더로 옮기거나([copy] 면 복사) 한다(트리 드래그). 성공하면 새 경로.
  Future<String?> move(String src, String destDir, {bool copy = false}) async {
    final source = await _resolveUserPath(src);
    if (source == null) return null;
    final dir = await _resolveUserPath(destDir, allowRoot: true);
    if (dir == null) return null;
    final target = p.join(dir, p.basename(source));
    if (p.equals(source, target)) return null; // 제자리
    if (p.isWithin(source, dir) || p.equals(source, dir)) {
      _fail('Cannot move a folder into itself.');
      return null;
    }
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _fail('Target already exists: $target');
      return null;
    }
    try {
      if (copy) {
        await fs.copyPath(source, target);
      } else {
        await fs.movePath(source, target);
      }
    } catch (e) {
      _fail('$e');
      return null;
    }
    final from = _display(source), to = _display(target);
    if (!copy) _followMove(from, to);
    _announce(FsChange(dirs: [p.dirname(from), _display(dir)], files: [from, to]));
    if (!copy) _emit(FsMoved(from, to));
    return to;
  }

  /// 새 파일 / 새 폴더. [parent] 는 만들 곳(폴더). 성공하면 만든 경로.
  Future<String?> create(String parent, String name, {required bool dir}) async {
    final base = await _resolveUserPath(parent, allowRoot: true);
    if (base == null) return null;
    if (FileSystemEntity.typeSync(base) != FileSystemEntityType.directory) {
      _fail('Not a folder: $parent');
      return null;
    }
    final clean = _checkName(name);
    if (clean == null) return null;
    final target = p.join(base, clean);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _fail('Target already exists: $target');
      return null;
    }
    try {
      if (dir) {
        await Directory(target).create();
      } else {
        await File(target).create(); // 빈 파일 — 뷰어가 바로 열어 편집할 수 있다
      }
    } catch (e) {
      _fail('$e');
      return null;
    }
    final shownBase = _display(base), shown = _display(target);
    // 만든 자리가 보이게 부모를 펼친다(루트는 늘 보인다). 한 번도 안 펼친 폴더면 아직
    // 읽지 않았다 — 변경 알림은 **읽어 둔** 폴더만 다시 읽으므로 여기서 직접 읽는다.
    if (!p.equals(shownBase, root)) {
      _expanded.add(shownBase);
      if (!_children.containsKey(shownBase)) unawaited(refresh(shownBase));
    }
    _selected = shown;
    _announce(FsChange(dirs: [shownBase], files: [shown]));
    _emit(FsCreated(shown, isDir: dir));
    return shown;
  }

  /// 이름 변경 — 같은 폴더 안에서만(경로 이동은 드래그로). 성공하면 새 경로.
  Future<String?> rename(String path, String name) async {
    final src = await _resolveUserPath(path);
    if (src == null) return null;
    final clean = _checkName(name);
    if (clean == null) return null;
    final target = p.join(p.dirname(src), clean);
    if (p.equals(src, target)) return null; // 그대로면 조용히 넘어간다
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      _fail('Target already exists: $target');
      return null;
    }
    try {
      await fs.movePath(src, target);
    } catch (e) {
      _fail('$e');
      return null;
    }
    final from = _display(src), to = _display(target);
    _followMove(from, to);
    _announce(FsChange(dirs: [p.dirname(from)], files: [from, to]));
    _emit(FsMoved(from, to));
    return to;
  }

  /// 삭제. **되돌릴 수 없다**(휴지통을 거치지 않는다) — 확인은 화면이 받는다.
  Future<bool> delete(String path) async {
    final target = await _resolveUserPath(path);
    if (target == null) return false;
    try {
      if (FileSystemEntity.typeSync(target) == FileSystemEntityType.directory) {
        await Directory(target).delete(recursive: true);
      } else {
        await File(target).delete();
      }
    } catch (e) {
      _fail('$e');
      return false;
    }
    final shown = _display(target);
    bool gone(String? x) => x != null && (p.equals(x, shown) || p.isWithin(shown, x));
    if (gone(_selected)) _selected = null;
    _expanded.removeWhere(gone);
    _children.removeWhere((k, _) => gone(k));
    _announce(FsChange(dirs: [p.dirname(shown)], files: [shown]));
    _emit(FsDeleted(shown));
    return true;
  }

  /// 이름이 바뀐 경로를 따라 펼침·선택·캐시를 옮긴다(옛 경로의 캐시는 버린다).
  void _followMove(String from, String to) {
    String moved(String x) =>
        p.equals(x, from) ? to : (p.isWithin(from, x) ? p.join(to, p.relative(x, from: from)) : x);
    final sel = _selected;
    if (sel != null) _selected = moved(sel);
    final exp = _expanded.map(moved).toSet();
    _expanded
      ..clear()
      ..addAll(exp);
    _children.removeWhere((k, _) => p.equals(k, from) || p.isWithin(from, k));
    // 펼친 채로 옮겨진 폴더는 새 경로로 다시 읽는다(옛 경로의 캐시는 방금 버렸다).
    for (final d in exp) {
      if ((p.equals(d, to) || p.isWithin(to, d)) && !_children.containsKey(d)) {
        unawaited(refresh(d));
      }
    }
  }

  /// OS 기본(연결) 프로그램 · 탐색기로 연다.
  Future<void> openExternal(String path) async {
    try {
      if (Platform.isWindows) {
        // start 는 cmd 내장 명령. 빈 "" 는 창 제목 인자(경로가 제목으로 먹히지 않게).
        await Process.start('cmd', ['/c', 'start', '', path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else {
        await Process.start('xdg-open', [path]);
      }
    } catch (e) {
      _fail('Failed to open: $e');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    unawaited(_watchSub?.cancel());
    unawaited(_changes.close());
    unawaited(_events.close());
    unawaited(_errors.close());
    super.dispose();
  }
}
