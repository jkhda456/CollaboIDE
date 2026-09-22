import 'dart:async';
import 'dart:convert';

import 'package:collabo_core/collabo_core.dart' show NetworkEvent;
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// 샌드박스 하나의 **터미널(root 셸) + 네트워크 접근 기록.** 샌드박스 화면이 본다.
///
/// 터미널은 xterm.dart 의 [Terminal] **모델**이다(화면은 `TerminalView` 가 그린다).
/// 게스트 콘솔(hvc0)의 원시 바이트를 그대로 흘려 넣으면 이스케이프(커서·지우기·색·대체
/// 화면)를 에뮬레이터가 처리하고, 키 입력은 [Terminal.onOutput] 으로 나와 머신으로 간다 —
/// 진짜 TTY 처럼 입력과 출력이 한 화면에서 맞물린다. 모델이 여기(샌드박스 쪽)에 있으므로
/// 화면을 떠났다 돌아와도 스크롤백이 그대로다.
///
/// ★ [ProjectSandbox] 와 **다른 알림 통로**다. 머신 상태 알림은 세션 → 컨트롤러로 올라가
/// 앱 전체를 다시 그린다. 터미널은 스스로 알리고(Observable), 네트워크 기록은 여기서
/// 짧게 모아서([_flushDelay]) 한 번에 알린다.
class SandboxConsole extends ChangeNotifier {
  SandboxConsole() {
    terminal = Terminal(
      maxLines: maxLines,
      onOutput: (data) => input?.call(data),
      onResize: (cols, rows, _, _) {
        // 안 보이는 패널은 크기를 엉뚱하게 잰다(0 등) — 그런 값은 머신에 보내지 않는다.
        if (cols < 2 || rows < 2) return;
        _size = (cols, rows);
        resized?.call(cols, rows);
      },
    );
  }

  /// 스크롤백 상한(줄).
  static const int maxLines = 10000;

  /// 네트워크 기록 상한(건).
  static const int maxEvents = 300;

  static const Duration _flushDelay = Duration(milliseconds: 60);

  late final Terminal terminal;

  /// 키 입력(에뮬레이터가 만든 바이트열 — 화살표·Ctrl 키 포함)을 머신으로 보내는 곳.
  /// [ProjectSandbox] 가 건다. 머신이 없으면 버려진다.
  void Function(String data)? input;

  /// 화면 크기(열·행)가 바뀌었을 때. [ProjectSandbox] 가 머신 콘솔 크기로 옮긴다.
  void Function(int cols, int rows)? resized;

  /// 마지막으로 잰 화면 크기. 새로 부팅할 때 이 크기로 띄운다(셸의 줄바꿈이 맞게).
  (int, int)? get size => _size;
  (int, int)? _size;

  final List<NetworkEvent> _events = [];
  final _decoder = const Utf8Decoder(allowMalformed: true);
  List<int> _pending = const []; // 조각 경계에서 잘린 UTF-8 바이트
  Timer? _flush;

  /// 네트워크 접근(최근 것이 뒤).
  List<NetworkEvent> get events => List.unmodifiable(_events);

  /// 지금 터미널 버퍼의 글(스크롤백 포함) — 시험·진단용.
  String get text => terminal.buffer.getText();

  /// 머신이 뜨고 내릴 때 — 지난 머신의 출력과 섞이지 않게 흐린 구분선을 긋는다.
  void mark(String banner) {
    terminal.write('\r\n\x1b[2m── $banner ──\x1b[0m\r\n');
  }

  /// 게스트 콘솔에서 온 원시 바이트. 제어열은 에뮬레이터가 처리한다 — 여기서는 조각
  /// 경계에서 잘린 UTF-8 만 이어 붙인다(한글이 두 조각으로 오면 깨지지 않게).
  void addBytes(List<int> bytes) {
    final all = _pending.isEmpty ? bytes : [..._pending, ...bytes];
    var cut = all.length;
    for (var i = all.length - 1; i >= 0 && i >= all.length - 3; i--) {
      final b = all[i];
      if (b & 0xC0 == 0x80) continue; // 이어지는 바이트
      final need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
      if (all.length - i < need) cut = i;
      break;
    }
    _pending = all.sublist(cut);
    if (cut > 0) terminal.write(_decoder.convert(all.sublist(0, cut)));
  }

  void addEvent(NetworkEvent e) {
    _events.add(e);
    if (_events.length > maxEvents) _events.removeRange(0, _events.length - maxEvents);
    _flush ??= Timer(_flushDelay, () {
      _flush = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }
}
