import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// 한글 같은 **조합형 입력(IME)** 이 쪼개지지 않는 터미널 뷰.
///
/// xterm.dart(4.0.0)의 `TerminalView` 를 그대로 쓰되 **글자 입력만** 여기서 받는다.
///
/// 왜 (1): xterm 의 입력기(`CustomTextEdit`)는 글자 하나가 확정될 때마다 입력 상태를 빈 값으로
/// 되돌린다(`setEditingState('')`). macOS 는 그 순간 조합 중이면 조합을 버린다
/// (`FlutterTextInputPlugin.setEditingState` → `discardMarkedText`). 한글 IME 는 "한" 을 확정하는
/// **같은 키에서** 다음 "ㄱ" 조합을 시작하므로, 되돌리기가 늘 그 조합과 부딪친다 — "한글" 이
/// "한ㄱㅡㄹ" 처럼 쪼개진다.
///
/// 왜 (2): IME 가 조합 중인 글자를 **표시(marked text) 없이 확정 글자처럼 넣고 다음 키에서 바꿔
/// 치우는** 경우가 있다(macOS 에서 본 것: `cat > f` 에 치면 초성이 먼저 가고 조합이 뒤에 붙었다).
/// 확정된 줄 알고 보내면 터미널엔 "ㅎ ⌫ 하 ⌫ 한" 이 간다. busybox 줄 편집기는 ⌫ 로 글자 하나를
/// 지워 멀쩡해 보이지만, 커널 줄 규칙(cat·read)은 바이트/칸 단위라 화면과 내용이 깨진다.
/// → **끝의 한글 한 글자는 다음 글자가 붙거나 터미널 키(Enter 등)를 칠 때까지 보내지 않는다**
///   (그동안은 조합 글자처럼 커서 자리에 밑줄로 보인다). 한글 뒤에 무엇이든 오면 그 글자는 더
///   바뀌지 않는다 — 두벌식에서 앞 음절을 고치는 것은 바로 다음 음절이 생길 때뿐이다.
///
/// 그래서:
///  - xterm 은 하드웨어 키만 받게 하고(`hardwareKeyboardOnly`) 입력 연결은 우리가 붙인다.
///  - **조합 중에는 입력 상태를 절대 건드리지 않는다.** 터미널에는 확정된 글자만, 이미 보낸
///    것과의 차이로 보낸다(IME 가 보낸 글자를 고치면 그만큼 지우고 다시 보낸다).
///  - 비우기는 IME 가 관여하지 않는 키(Enter·방향키·Ctrl 조합 …)를 터미널이 받을 때만.
///  - 조합 중인 글자(와 아직 안 보낸 끝 글자)는 커서 자리에 따로 그린다. IME 후보 창도 그 자리.
///
/// 키 분배: 조합 중이면 모든 키가 IME 몫이다. 끝 글자를 잡고 있을 때는 글자 키·Backspace 가 IME 몫
/// (그 글자를 고치거나 지운다)이고 나머지 터미널 키는 잡은 글자를 먼저 보낸 뒤 터미널로 간다.
/// 그 밖에는 글자 키는 IME 로(영문도 IME 를 거쳐 확정 글자로 온다), 나머지는 xterm 으로.
class ImeTerminalView extends StatefulWidget {
  const ImeTerminalView(
    this.terminal, {
    super.key,
    required this.focusNode,
    required this.theme,
    this.textStyle = const TerminalStyle(),
    this.padding,
    this.autofocus = false,
    this.readOnly = false,
    this.shortcuts,
  });

  final Terminal terminal;
  final FocusNode focusNode;
  final TerminalTheme theme;
  final TerminalStyle textStyle;
  final EdgeInsets? padding;
  final bool autofocus;
  final bool readOnly;
  final Map<ShortcutActivator, Intent>? shortcuts;

  @override
  State<ImeTerminalView> createState() => ImeTerminalViewState();
}

class ImeTerminalViewState extends State<ImeTerminalView> with TextInputClient {
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey();

  TextInputConnection? _connection;
  TextEditingValue _value = TextEditingValue.empty;

  /// 입력 상태의 **확정된** 글자(조합 구간을 뺀 것).
  String _committed = '';

  /// 그중 이미 터미널로 보낸 것.
  String _sent = '';

  /// 확정됐지만 아직 안 보낸 끝 한글 한 글자('' 이면 없음).
  String _held = '';

  /// 조합 중인 글자(없으면 null).
  String? _composing;

  /// 커서 칸(이 위젯 기준 좌표). 미리보기와 IME 후보 창 자리.
  Rect? _caret;

  /// IME 가 표시한 조합이 있다.
  bool get isComposing => _composing != null;

  /// 커서 자리에 그릴 것 — 잡아 둔 끝 글자 + 조합 중인 글자.
  String get preview => _held + (_composing ?? '');

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    widget.terminal.addListener(_onTerminalChange);
    if (widget.focusNode.hasFocus) _attach();
  }

  @override
  void didUpdateWidget(ImeTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChange);
      widget.terminal.addListener(_onTerminalChange);
    }
    if (oldWidget.terminal != widget.terminal || oldWidget.readOnly != widget.readOnly) {
      _detach();
      _onFocusChange();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    widget.terminal.removeListener(_onTerminalChange);
    _detach(notify: false);
    super.dispose();
  }

  void _onFocusChange() {
    if (widget.focusNode.hasFocus && !widget.readOnly) {
      _attach();
    } else {
      _detach();
    }
  }

  /// 터미널 화면이 바뀌면(에코가 와서 커서가 움직이면) 미리보기 자리를 따라 옮긴다.
  void _onTerminalChange() {
    if (preview.isNotEmpty) _placeIme();
  }

  void _attach() {
    if (widget.readOnly) return;
    final c = _connection;
    if (c != null && c.attached) {
      c.show();
      return;
    }
    _clearState();
    _connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.text,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    )
      ..show()
      ..setEditingState(_value);
    _placeIme();
  }

  void _detach({bool notify = true}) {
    // 초점을 잃으면 잡아 둔 끝 글자는 확정이다 — 버리지 않고 보낸다.
    if (_held.isNotEmpty) _emit(_committed);
    final c = _connection;
    _connection = null;
    if (c != null && c.attached) c.close();
    final hadPreview = preview.isNotEmpty;
    _clearState();
    if (notify && hadPreview && mounted) setState(() {});
  }

  void _clearState() {
    _value = TextEditingValue.empty;
    _committed = '';
    _sent = '';
    _held = '';
    _composing = null;
  }

  /// 잡아 둔 끝 글자를 보내고 입력 상태를 비운다 — **조합 중이 아닐 때만**(macOS 는 조합을 버린다).
  void _flushAndReset() {
    if (isComposing) return;
    if (_held.isNotEmpty) {
      _emit(_committed);
      _held = '';
      setState(() {});
    }
    if (_value.text.isEmpty) return;
    _value = TextEditingValue.empty;
    _committed = '';
    _sent = '';
    _connection?.setEditingState(_value);
  }

  // ------------------------------------------------------------ 키

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.readOnly) return KeyEventResult.ignored;
    // 조합 중인 키는 전부 IME 몫이다(Backspace 는 조합을 지우고, Enter 는 확정한다).
    if (isComposing) return KeyEventResult.skipRemainingHandlers;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final modified = keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed;
    final ch = event.character;
    final printable = ch != null && ch.isNotEmpty && ch.runes.every((r) => r >= 0x20 && r != 0x7f);
    if (!modified && printable) {
      // 글자는 IME 를 거쳐 확정 글자로 온다(updateEditingValue). 여기서 보내면 두 번 간다.
      return KeyEventResult.skipRemainingHandlers;
    }
    if (_held.isNotEmpty && !modified && event.logicalKey == LogicalKeyboardKey.backspace) {
      // 아직 안 보낸 끝 글자를 고치는 키 — IME(입력 상태)가 처리하고 차이로 반영된다.
      return KeyEventResult.skipRemainingHandlers;
    }
    if (modified || _terminalKeys.contains(event.logicalKey)) {
      // 터미널 키 — xterm 이 보낸다. 잡아 둔 글자를 **먼저** 보내고(순서), 입력 상태를 비운다.
      _flushAndReset();
    }
    // 그 밖의 키(문자 없는 키 — Windows 한글 IME 의 Process 키, 한/영 등)는 손대지 않고 넘긴다.
    return KeyEventResult.ignored;
  }

  static final Set<LogicalKeyboardKey> _terminalKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.insert,
  };

  // ------------------------------------------------------------ IME

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    final before = preview;
    _value = value;
    final text = value.text;
    final c = value.composing;
    final composing = c.isValid && !c.isCollapsed && c.end <= text.length;
    _committed = composing ? text.substring(0, c.start) + text.substring(c.end) : text;
    _composing = composing ? c.textInside(text) : null;
    _sync();
    if (preview != before) {
      setState(() {});
      _placeIme();
    }
  }

  /// 확정 글자를 터미널로 — 끝의 한글 한 글자는 (표시된 조합이 없으면) 아직 바뀔 수 있어 잡아 둔다.
  void _sync() {
    var target = _committed;
    _held = '';
    if (!isComposing && target.isNotEmpty) {
      final last = target.runes.last;
      if (_isHangul(last)) {
        final cut = target.length - String.fromCharCode(last).length;
        _held = target.substring(cut);
        target = target.substring(0, cut);
      }
    }
    _emit(target);
  }

  static bool _isHangul(int r) =>
      (r >= 0xAC00 && r <= 0xD7A3) || // 완성형 음절
      (r >= 0x3130 && r <= 0x318F) || // 호환용 자모(ㄱ, ㅏ …)
      (r >= 0x1100 && r <= 0x11FF) || // 첫가끝 자모
      (r >= 0xA960 && r <= 0xA97F) ||
      (r >= 0xD7B0 && r <= 0xD7FF);

  /// [target] 을 이미 보낸 것과 비교해 **차이만** 터미널로 보낸다.
  void _emit(String target) {
    if (target == _sent) return;
    var i = 0;
    final n = target.length < _sent.length ? target.length : _sent.length;
    while (i < n && target.codeUnitAt(i) == _sent.codeUnitAt(i)) {
      i++;
    }
    // 서로게이트 쌍 가운데서 자르지 않는다.
    if (i > 0 && i < _sent.length && _isLowSurrogate(_sent.codeUnitAt(i))) i--;
    final removed = _sent.substring(i).runes.length;
    for (var k = 0; k < removed; k++) {
      widget.terminal.keyInput(TerminalKey.backspace);
    }
    final added = target.substring(i);
    if (added.isNotEmpty) widget.terminal.textInput(added);
    _sent = target;
  }

  static bool _isLowSurrogate(int u) => u >= 0xDC00 && u <= 0xDFFF;

  @override
  void performAction(TextInputAction action) {
    // macOS: 조합 중 Enter → IME 가 확정한 뒤 여기로 온다(insertNewline). 확정 글자(잡아 둔 끝
    // 글자 포함)를 먼저 보내고 Enter.
    if (action == TextInputAction.newline || action == TextInputAction.done) {
      _composing = null;
      _flushAndReset();
      widget.terminal.keyInput(TerminalKey.enter);
      setState(() {});
    }
  }

  @override
  void connectionClosed() {
    if (_held.isNotEmpty) _emit(_committed);
    _connection = null;
    _clearState();
    if (mounted) setState(() {});
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  bool _placeScheduled = false;

  /// IME 에 편집 영역과 커서 자리를 알린다(후보 창이 커서 옆에 뜨게) — 그리고 미리보기 자리.
  void _placeIme() {
    if (_placeScheduled) return;
    _placeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placeScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final view = _viewKey.currentState;
      if (box == null || !box.hasSize || view == null) return;
      Rect caret;
      try {
        final g = view.globalCursorRect;
        caret = box.globalToLocal(g.topLeft) & g.size;
      } catch (_) {
        return; // 아직 한 번도 안 그렸다
      }
      final c = _connection;
      if (c != null && c.attached) {
        c.setEditableSizeAndTransform(box.size, box.getTransformTo(null));
        c.setCaretRect(caret);
        c.setComposingRect(caret);
      }
      if (caret != _caret) setState(() => _caret = caret);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final text = preview;
    final caret = _caret;
    return Stack(
      children: [
        Positioned.fill(
          child: TerminalView(
            widget.terminal,
            key: _viewKey,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            theme: widget.theme,
            textStyle: widget.textStyle,
            padding: widget.padding,
            shortcuts: widget.shortcuts,
            readOnly: widget.readOnly,
            // 글자 입력은 이 위젯이 받는다(위 설명). xterm 은 키 이벤트만.
            hardwareKeyboardOnly: true,
            onKeyEvent: _onKeyEvent,
          ),
        ),
        if (text.isNotEmpty && caret != null)
          Positioned(
            left: caret.left,
            top: caret.top,
            child: IgnorePointer(
              child: Text(
                text,
                key: const ValueKey('ime-composing'),
                style: widget.textStyle.toTextStyle(
                  color: widget.theme.foreground,
                  backgroundColor: widget.theme.background,
                  underline: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
