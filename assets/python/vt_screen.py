#!/usr/bin/env python3
"""Collabo IDE - minimal VT100/xterm screen emulator (stdlib only).

`term_runner.py` feeds raw PTY bytes in here and asks for two things:

  * `display()`      - what a human would see on screen right now (the grid).
  * `take_scrolled()`- lines that scrolled off the top since the last call,
                       which the runner appends to `scrollback.txt`.

That split is the whole point. A terminal is not a log: `\\r`, cursor moves and
erase sequences mean the raw byte stream is NOT what the user sees. Progress
bars, `top`, `vim` and even a plain shell prompt all rewrite in place. Handing
the LLM the raw stream would be handing it every intermediate frame.

WHAT IS AND IS NOT IMPLEMENTED

Implemented: cursor movement, erase (display/line/chars), insert/delete
lines and chars, scroll regions, index/reverse-index, save/restore cursor,
tabs, the alternate screen buffer (`?1049` - vim/top/less live there), OSC
window title, and East-Asian wide characters (한글 is two cells).

Deliberately dropped: **all colour and attributes** (SGR is parsed and
thrown away). We hand text to an LLM and to a Flutter panel that renders one
monospace style - carrying per-cell attributes would cost memory and buy
nothing. Also dropped: sixel/graphics, mouse reports, character sets beyond
the default (`ESC ( B`), and double-width/height lines.

Unknown sequences are skipped, never printed. A terminal that prints garbage
for something it did not understand is worse than one that stays quiet.
"""

import unicodedata
from codecs import getincrementaldecoder

# 넓은 글자(한글·CJK·이모지)가 차지한 **두 번째 칸**을 표시하는 센티넬.
# 렌더링할 때 빼면 원래 글자만 남는다.
WIDE_TAIL = "\x00"

DEFAULT_COLS = 120
DEFAULT_ROWS = 32

# 화면에서 밀려난 줄을 얼마나 들고 있을지(runner 가 가져가면 비므로 안전망이다).
MAX_PENDING_SCROLL = 5000


def char_width(ch):
    """글자가 차지하는 칸 수(0=결합 문자, 2=전각)."""
    if ch == WIDE_TAIL:
        return 0
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def render_line(cells):
    """셀 배열 한 줄을 문자열로. 오른쪽 공백은 떼고 센티넬은 지운다."""
    return "".join(c for c in cells if c != WIDE_TAIL).rstrip()


class Screen(object):
    """커서 하나와 격자 하나를 가진 아주 작은 터미널."""

    def __init__(self, cols=DEFAULT_COLS, rows=DEFAULT_ROWS):
        self.cols = max(2, int(cols))
        self.rows = max(1, int(rows))
        self.title = ""
        self.alt = False  # 대체 화면(vim/top)에 들어가 있는가
        self._decoder = getincrementaldecoder("utf-8")(errors="replace")
        self._reset_buffers()
        # 파서 상태: 'ground' | 'esc' | 'csi' | 'osc' | 'str'
        self._state = "ground"
        self._param = ""
        self._osc = ""

    # ------------------------------------------------------------------ 버퍼

    def _blank(self):
        return [" "] * self.cols

    def _reset_buffers(self):
        self._grid = [self._blank() for _ in range(self.rows)]
        self._saved_grid = None  # 대체 화면으로 갈 때 넣어 두는 원래 화면
        self.x = 0
        self.y = 0
        self._saved_cursor = (0, 0)
        self._top = 0  # 스크롤 영역(포함)
        self._bottom = self.rows - 1
        self._pending = []  # 위로 밀려난 줄(runner 가 가져간다)
        # 다음 글자가 줄 끝을 넘어갈 때 줄바꿈을 **미루는** 표시.
        # 이게 없으면 마지막 칸을 채우는 순간 한 줄이 통째로 밀려, 폭에 딱 맞는
        # 출력마다 빈 줄이 하나씩 생긴다(실제 터미널의 동작이 이렇다).
        self._wrap_pending = False

    # ------------------------------------------------------------------ 입력

    def feed(self, data):
        """PTY 에서 읽은 바이트를 넣는다. 청크 경계를 넘어가도 상태가 유지된다."""
        if isinstance(data, bytes):
            text = self._decoder.decode(data)
        else:
            text = data
        for ch in text:
            self._feed_char(ch)

    def _feed_char(self, ch):
        state = self._state
        if state == "ground":
            self._ground(ch)
        elif state == "esc":
            self._escape(ch)
        elif state == "csi":
            # 파라미터·중간 문자는 모으고, 종결 문자(0x40~0x7E)를 만나면 실행.
            if "\x40" <= ch <= "\x7e":
                self._state = "ground"
                self._csi(self._param, ch)
                self._param = ""
            elif ch == "\x1b":  # 중간에 끊긴 시퀀스 — 새로 시작한다
                self._state = "esc"
                self._param = ""
            else:
                if len(self._param) < 64:
                    self._param += ch
        elif state == "osc":
            # OSC 는 BEL 또는 ST(ESC \) 로 끝난다.
            if ch == "\x07":
                self._state = "ground"
                self._end_osc()
            elif ch == "\x1b":
                self._state = "osc_esc"
            elif len(self._osc) < 512:
                self._osc += ch
        elif state == "osc_esc":
            self._state = "ground"
            self._end_osc()
            if ch != "\\":
                self._feed_char(ch)  # ST 가 아니었다 — 그 글자는 살린다
        elif state == "str":
            # DCS/APC/PM/SOS: ST 까지 통째로 버린다.
            if ch == "\x1b":
                self._state = "str_esc"
        elif state == "str_esc":
            self._state = "ground" if ch == "\\" else "str"
        elif state == "charset":
            # `ESC ( B` 같은 문자셋 지정 — 지정 글자 하나를 버리고 끝낸다.
            self._state = "ground"

    def _ground(self, ch):
        if ch == "\x1b":
            self._state = "esc"
        elif ch == "\r":
            self.x = 0
            self._wrap_pending = False
        elif ch in "\n\x0b\x0c":
            self._wrap_pending = False
            self._index()
        elif ch == "\b":
            self._wrap_pending = False
            if self.x > 0:
                self.x -= 1
        elif ch == "\t":
            self._wrap_pending = False
            self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
        elif ch == "\x07":
            pass  # BEL — 소리는 낼 곳이 없다
        elif ch < " " or ch == "\x7f":
            pass  # 나머지 제어 문자는 무시
        else:
            self._put(ch)

    def _put(self, ch):
        w = char_width(ch)
        if w == 0:
            # 결합 문자는 앞 글자에 붙인다(별도 칸을 차지하지 않는다).
            px = self.x - 1
            if 0 <= px < self.cols:
                base = self._grid[self.y][px]
                if base != WIDE_TAIL:
                    self._grid[self.y][px] = base + ch
            return
        if self._wrap_pending or self.x + w > self.cols:
            self.x = 0
            self._index()
            self._wrap_pending = False
        row = self._grid[self.y]
        # 전각 글자의 왼쪽 반을 덮어쓰면 오른쪽 반이 미아가 된다 — 지워 준다.
        if row[self.x] == WIDE_TAIL and self.x > 0:
            row[self.x - 1] = " "
        row[self.x] = ch
        if w == 2:
            if self.x + 1 < self.cols:
                row[self.x + 1] = WIDE_TAIL
            self.x += 2
        else:
            self.x += 1
        if self.x >= self.cols:
            # 아직 줄을 넘기지 않는다 — 다음 글자가 올 때 넘긴다.
            self.x = self.cols - 1
            self._wrap_pending = True

    # ------------------------------------------------------------- ESC / CSI

    def _escape(self, ch):
        self._state = "ground"
        if ch == "[":
            self._state = "csi"
            self._param = ""
        elif ch == "]":
            self._state = "osc"
            self._osc = ""
        elif ch in "P^_X":  # DCS / PM / APC / SOS
            self._state = "str"
        elif ch == "7":
            self._saved_cursor = (self.x, self.y)
        elif ch == "8":
            self.x, self.y = self._saved_cursor
            self._clamp()
        elif ch == "D":
            self._index()
        elif ch == "E":
            self.x = 0
            self._index()
        elif ch == "M":
            self._reverse_index()
        elif ch == "c":
            self._reset_buffers()
        elif ch in "()*+":
            self._state = "charset"  # 다음 한 글자(문자셋 지정)를 버린다

    def _end_osc(self):
        # `0;title` / `2;title` 만 쓴다. 나머지(색 지정 등)는 버린다.
        body = self._osc
        self._osc = ""
        if ";" in body:
            code, _, text = body.partition(";")
            if code.strip() in ("0", "2"):
                self.title = text[:200]

    def _csi(self, param, final):
        private = param[:1] if param[:1] in "?><!" else ""
        body = param[len(private):]
        # 중간 문자($ " space 등)는 쓰지 않으므로 떼어 낸다.
        while body and body[-1] in " !\"$'*":
            body = body[:-1]
        args = []
        for part in body.split(";"):
            part = part.strip()
            args.append(int(part) if part.isdigit() else 0)
        if not args:
            args = [0]

        def a(i=0, default=1):
            v = args[i] if i < len(args) else 0
            return v if v else default

        if final == "m":
            return  # SGR(색·속성) — 일부러 버린다
        if final in "hl":
            self._mode(private, args, final == "h")
            return
        if final == "A":
            self.y = max(self._top, self.y - a())
        elif final == "B" or final == "e":
            self.y = min(self._bottom, self.y + a())
        elif final == "C" or final == "a":
            self.x = min(self.cols - 1, self.x + a())
        elif final == "D":
            self.x = max(0, self.x - a())
        elif final == "E":
            self.x = 0
            self.y = min(self._bottom, self.y + a())
        elif final == "F":
            self.x = 0
            self.y = max(self._top, self.y - a())
        elif final in "G`":
            self.x = min(self.cols - 1, a() - 1)
        elif final == "d":
            self.y = min(self.rows - 1, a() - 1)
        elif final in "Hf":
            self.y = min(self.rows - 1, a(0) - 1)
            self.x = min(self.cols - 1, a(1) - 1)
        elif final == "J":
            self._erase_display(args[0])
        elif final == "K":
            self._erase_line(args[0])
        elif final == "L":
            self._insert_lines(a())
        elif final == "M":
            self._delete_lines(a())
        elif final == "P":
            self._delete_chars(a())
        elif final == "@":
            self._insert_chars(a())
        elif final == "X":
            n = min(a(), self.cols - self.x)
            for i in range(n):
                self._grid[self.y][self.x + i] = " "
        elif final == "S":
            self._scroll_up(a())
        elif final == "T":
            self._scroll_down(a())
        elif final == "r":
            top = a(0) - 1
            bottom = (args[1] - 1) if len(args) > 1 and args[1] else self.rows - 1
            if 0 <= top < bottom < self.rows:
                self._top, self._bottom = top, bottom
            else:
                self._top, self._bottom = 0, self.rows - 1
            self.x = 0
            self.y = self._top
        elif final == "s":
            self._saved_cursor = (self.x, self.y)
        elif final == "u":
            self.x, self.y = self._saved_cursor
        # 그 밖(장치 보고 n/c, 마우스 등)은 조용히 버린다.
        self._wrap_pending = False
        self._clamp()

    def _mode(self, private, args, on):
        if private != "?":
            return
        for code in args:
            # 1047/1049/47 = 대체 화면. vim·top·less 가 여기서 산다.
            if code in (47, 1047, 1049):
                self._set_alt(on)

    def _set_alt(self, on):
        if on == self.alt:
            return
        if on:
            self._saved_grid = (self._grid, self.x, self.y)
            self._grid = [self._blank() for _ in range(self.rows)]
            self.x = self.y = 0
        else:
            saved = self._saved_grid
            self._saved_grid = None
            if saved:
                grid, x, y = saved
                # 대체 화면에 있는 동안 크기가 바뀌었을 수 있다.
                self._grid = [self._fit(row) for row in grid[: self.rows]]
                while len(self._grid) < self.rows:
                    self._grid.append(self._blank())
                self.x, self.y = x, y
            else:
                self._grid = [self._blank() for _ in range(self.rows)]
                self.x = self.y = 0
        self.alt = on
        self._clamp()

    # ------------------------------------------------------------ 스크롤·삭제

    def _index(self):
        """커서를 한 줄 아래로. 스크롤 영역 바닥이면 화면을 위로 민다."""
        if self.y == self._bottom:
            self._scroll_up(1)
        elif self.y < self.rows - 1:
            self.y += 1

    def _reverse_index(self):
        if self.y == self._top:
            self._scroll_down(1)
        elif self.y > 0:
            self.y -= 1

    def _scroll_up(self, n):
        n = max(1, min(n, self._bottom - self._top + 1))
        for _ in range(n):
            gone = self._grid.pop(self._top)
            # **대체 화면의 스크롤은 기록하지 않는다.** vim 이 화면을 굴린 것을
            # 로그에 쌓으면 스크롤백이 편집 중간 상태로 가득 찬다.
            if not self.alt and self._top == 0:
                self._pending.append(render_line(gone))
                if len(self._pending) > MAX_PENDING_SCROLL:
                    del self._pending[: len(self._pending) - MAX_PENDING_SCROLL]
            self._grid.insert(self._bottom, self._blank())

    def _scroll_down(self, n):
        n = max(1, min(n, self._bottom - self._top + 1))
        for _ in range(n):
            self._grid.pop(self._bottom)
            self._grid.insert(self._top, self._blank())

    def _insert_lines(self, n):
        if not (self._top <= self.y <= self._bottom):
            return
        n = min(n, self._bottom - self.y + 1)
        for _ in range(n):
            self._grid.pop(self._bottom)
            self._grid.insert(self.y, self._blank())

    def _delete_lines(self, n):
        if not (self._top <= self.y <= self._bottom):
            return
        n = min(n, self._bottom - self.y + 1)
        for _ in range(n):
            self._grid.pop(self.y)
            self._grid.insert(self._bottom, self._blank())

    def _insert_chars(self, n):
        row = self._grid[self.y]
        n = min(n, self.cols - self.x)
        for _ in range(n):
            row.pop()
            row.insert(self.x, " ")

    def _delete_chars(self, n):
        row = self._grid[self.y]
        n = min(n, self.cols - self.x)
        for _ in range(n):
            row.pop(self.x)
            row.append(" ")

    def _erase_line(self, mode):
        row = self._grid[self.y]
        if mode == 1:
            rng = range(0, min(self.x + 1, self.cols))
        elif mode == 2:
            rng = range(0, self.cols)
        else:
            rng = range(self.x, self.cols)
        for i in rng:
            row[i] = " "

    def _erase_display(self, mode):
        if mode == 1:
            for yy in range(0, self.y):
                self._grid[yy] = self._blank()
            self._erase_line(1)
        elif mode in (2, 3):
            # `ESC[2J` 는 **화면을 지우는 것이지 기록을 지우는 것이 아니다.**
            # 지워지는 내용을 스크롤백으로 넘겨 둔다 — `clear` 를 쳤다고 방금까지의
            # 출력이 사라지면 에이전트가 결과를 영영 못 읽는다.
            if not self.alt:
                lines = [render_line(r) for r in self._grid]
                while lines and not lines[-1]:
                    lines.pop()
                if lines:
                    self._pending.extend(lines)
            self._grid = [self._blank() for _ in range(self.rows)]
        else:
            self._erase_line(0)
            for yy in range(self.y + 1, self.rows):
                self._grid[yy] = self._blank()

    def _clamp(self):
        self.x = max(0, min(self.x, self.cols - 1))
        self.y = max(0, min(self.y, self.rows - 1))

    # ------------------------------------------------------------------ 출력

    def _fit(self, row):
        row = list(row[: self.cols])
        while len(row) < self.cols:
            row.append(" ")
        return row

    def resize(self, cols, rows):
        """창 크기 변경. 내용은 왼쪽 위 기준으로 자르거나 채운다(재배치 없음)."""
        cols = max(2, int(cols))
        rows = max(1, int(rows))
        if cols == self.cols and rows == self.rows:
            return
        self.cols, self.rows = cols, rows
        self._grid = [self._fit(r) for r in self._grid[:rows]]
        while len(self._grid) < rows:
            self._grid.append(self._blank())
        self._top, self._bottom = 0, rows - 1
        self._wrap_pending = False
        self._clamp()

    def display(self):
        """지금 화면에 보이는 줄들(오른쪽 공백 제거)."""
        return [render_line(row) for row in self._grid]

    def take_scrolled(self):
        """위로 밀려난 줄을 가져가고 비운다(runner 가 파일에 붙인다)."""
        out = self._pending
        self._pending = []
        return out

    def snapshot(self):
        """`screen.json` 에 그대로 실릴 형태."""
        return {
            "cols": self.cols,
            "rows": self.rows,
            "cursor": {"x": self.x, "y": self.y},
            "alt": self.alt,
            "title": self.title,
            "lines": self.display(),
        }
