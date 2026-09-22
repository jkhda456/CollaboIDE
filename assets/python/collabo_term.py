#!/usr/bin/env python3
"""Collabo IDE - terminal session tool module (fixed base module).

Persistent terminal sessions, in the spirit of GNU `screen`: open one, leave it
running, come back and look at it, type into it, search what scrolled past.
Both the agent and the user share the same sessions - the app's process panel
lists them next to background commands, because they live in the same registry
(`<workspace>/.collabo/proc/<id>/`, with `"kind": "terminal"` in `meta.json`).

WHY THIS EXISTS ALONGSIDE `run_command`

`run_command` is fire-and-forget: it starts something, hands back the output,
and every call is a fresh process with no memory. That is the right shape for
`git status` and the wrong shape for everything stateful - a Python REPL, a
`ssh` session, a database shell, `npm run dev` that you want to watch, or any
program that draws a screen. Those need one process that stays, a real
terminal so `isatty()` is true, and a way to look at *the screen* rather than
at a transcript of every frame that was ever drawn.

WHAT THE MODEL ACTUALLY SEES

Not the raw byte stream. `term_runner.py` renders it through a VT emulator
(`vt_screen.py`) and keeps two things apart:

  * the **screen** - the grid as a human would see it right now, and
  * the **scrollback** - lines that scrolled off the top, ANSI stripped.

A progress bar that redrew itself 400 times is one line on screen, not 400
lines of context. `term_search` then lets the agent find something in a long
scrollback without reading it all back in.

Contract (identical to collabo_tools.py):
  describe:
    python collabo_term.py describe
      -> stdout(JSON): {"module","version","tools":[<OpenAI tool schema>...]}
  call:
    python collabo_term.py call <tool_name>
      <- stdin(JSON): tool arguments (object)
      -> stdout(JSON): {"ok":true,"result":...} | {"ok":false,"error":"..."}

Environment:
  COLLABO_WORKSPACE : project root. Sessions live under <workspace>/.collabo/proc/.
                      Required - with no workspace we refuse to start anything.

SAFETY NOTE: a terminal runs a shell, and a shell goes wherever it likes. The
workspace guard here pins the *starting directory* only, exactly as
`run_command` does; it is not a sandbox. That is a deliberate continuation of
the existing policy, not an oversight.
"""

import json
import os
import re
import subprocess
import sys
import time
import uuid

MODULE_NAME = "collabo_term"
MODULE_VERSION = "0.1.0"

WORKSPACE = os.environ.get("COLLABO_WORKSPACE") or ""

# 이 모듈과 같은 폴더에 있는 detached 터미널 러너.
TERM_RUNNER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "term_runner.py"
)

# 한 번의 결과로 돌려주는 텍스트 상한(컨텍스트 보호).
MAX_TEXT_BYTES = 32 << 10

# `tail` 기본 줄 수.
DEFAULT_TAIL_LINES = 200

# 출력이 멎었다고 볼 시간(초)과 기본 대기 상한(초).
DEFAULT_IDLE = 0.4
DEFAULT_WAIT = 10

# **첫** 출력을 기다려 주는 시간. 아무것도 안 찍는 명령(`cd`)도 있으므로 여기까지만
# 기다리고 넘어간다(§_wait_idle).
FIRST_OUTPUT_GRACE = 3.0

# Windows 프로세스 생성 플래그.
_DETACHED_PROCESS = 0x00000008
_CREATE_NEW_PROCESS_GROUP = 0x00000200


class ToolError(Exception):
    """An error to return to the user/LLM as a failed tool result."""


_TOOLS = {}


def tool(name, description, parameters):
    """Register a tool. `parameters` is a JSON Schema (object)."""

    def deco(func):
        _TOOLS[name] = {
            "schema": {
                "type": "function",
                "function": {
                    "name": name,
                    "description": description,
                    "parameters": parameters,
                },
            },
            "func": func,
        }
        return func

    return deco


# ------------------------------------------------------------------ 레지스트리


def _proc_root():
    """`<workspace>/.collabo/proc` — 백그라운드 명령과 **같은** 레지스트리."""
    if not WORKSPACE:
        raise ToolError("No workspace is set; cannot open a terminal.")
    return os.path.join(os.path.abspath(WORKSPACE), ".collabo", "proc")


def _read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {} if default is None else default


def _session_dirs():
    root = _proc_root()
    out = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for name in names:
        d = os.path.join(root, name)
        meta = _read_json(os.path.join(d, "meta.json"))
        if meta.get("kind") == "terminal":
            out.append((d, meta))
    return out


def _find(args, required=True):
    """id 또는 name 으로 터미널 세션 하나를 찾는다."""
    want = str(args.get("id") or args.get("terminal") or "").strip()
    name = str(args.get("name") or "").strip()
    sessions = _session_dirs()
    if want:
        for d, meta in sessions:
            if meta.get("id") == want:
                return d, meta
    if name:
        for d, meta in sessions:
            if meta.get("name") == name:
                return d, meta
    if not want and not name:
        # 하나뿐이면 그걸로 본다 — 모델이 id 를 빠뜨리는 일이 잦다.
        running = [s for s in sessions if s[1].get("status") == "running"]
        if len(running) == 1:
            return running[0]
        if len(sessions) == 1:
            return sessions[0]
    if not required:
        return None, None
    raise ToolError(
        "No such terminal (give `id` from term_open/term_list). "
        "Open sessions: %s"
        % (", ".join(m.get("id", "?") for _, m in sessions) or "none")
    )


def _resolve_cwd(path):
    """시작 폴더를 워크스페이스 안으로 제한한다(`collabo_tools._resolve` 와 같은 취지)."""
    if not WORKSPACE:
        raise ToolError("No workspace is set.")
    root = os.path.realpath(os.path.abspath(WORKSPACE))
    target = os.path.realpath(os.path.abspath(os.path.join(root, path or ".")))
    if os.path.normcase(target) != os.path.normcase(root) and os.path.commonpath(
        [os.path.normcase(target), os.path.normcase(root)]
    ) != os.path.normcase(root):
        raise ToolError("Path is outside the project: %s" % path)
    if not os.path.isdir(target):
        raise ToolError("Not a folder: %s" % path)
    return target


def _clip(text):
    """앞을 잘라 상한에 맞춘다(**뒤쪽이 최신**이라 뒤를 남긴다)."""
    data = text.encode("utf-8")
    if len(data) <= MAX_TEXT_BYTES:
        return text
    cut = data[-MAX_TEXT_BYTES:].decode("utf-8", errors="replace")
    return "…(truncated)\n" + cut


# ------------------------------------------------------------------- 화면 읽기


def _screen(proc_dir):
    return _read_json(os.path.join(proc_dir, "screen.json"))


def _scroll_path(proc_dir):
    return os.path.join(proc_dir, "scrollback.txt")


def _scroll_lines(proc_dir):
    try:
        with open(_scroll_path(proc_dir), "r", encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def _cursor_path(proc_dir):
    return os.path.join(proc_dir, "read_cursor.json")


def _rev(proc_dir):
    """지금 화면의 리비전(러너가 화면을 다시 쓸 때마다 올라간다)."""
    return _screen(proc_dir).get("rev")


def _wait_idle(proc_dir, wait, idle, since_rev=None):
    """출력이 **시작되고 나서** [idle]초 동안 멎을 때까지(최대 [wait]초) 기다린다.

    보내자마자 읽으면 아직 아무것도 안 나와 있다 — 터미널 도구에서 가장 흔한
    실수라, 기본 동작으로 넣어 둔다.

    ⚠️ **"지금 조용하다" 로는 부족하다.** 처음에 그렇게 짰다가 정확히 걸렸다:
    명령을 보낸 직후에는 당연히 조용하므로, 0.4초 뒤에 "다 끝났다" 며 명령이
    실행되기도 전의 화면을 돌려줬다. 그래서 [since_rev](보내기 **직전**의 리비전)
    를 받아, 화면이 한 번이라도 움직인 뒤에야 조용함을 인정한다.

    아무 출력도 없는 명령(`cd` 같은)도 있으므로, 첫 출력은 [FIRST_OUTPUT_GRACE]
    까지만 기다리고 포기한다. 프로그램이 계속 떠들면 [wait] 에서 끊고 지금 화면을
    돌려준다(그것도 정보다 — 호출측이 그 사실을 결과에 적는다).
    """
    if wait <= 0:
        return False
    now = time.time()
    deadline = now + wait
    first_deadline = now + min(wait, FIRST_OUTPUT_GRACE)
    last_rev = since_rev
    started = False
    last_change = now
    while time.time() < deadline:
        rev = _rev(proc_dir)
        if rev != last_rev:
            last_rev = rev
            last_change = time.time()
            started = True
        elif started and time.time() - last_change >= idle:
            return True
        elif not started and time.time() >= first_deadline:
            return True  # 출력이 아예 없는 명령이다
        meta = _read_json(os.path.join(proc_dir, "meta.json"))
        if meta.get("status") not in ("running", None):
            return True  # 끝난 세션은 더 기다릴 것이 없다
        time.sleep(0.05)
    return False


def _state(proc_dir, meta, snap=None):
    """모든 도구가 함께 돌려주는 공통 상태."""
    snap = snap if snap is not None else _screen(proc_dir)
    status = meta.get("status") or "running"
    out = {
        "id": meta.get("id"),
        "name": meta.get("name") or "",
        "status": status,
        "running": status == "running",
        "pid": meta.get("pid"),
        "pty": meta.get("pty", True),
        "cols": snap.get("cols") or meta.get("cols"),
        "rows": snap.get("rows") or meta.get("rows"),
    }
    if snap.get("title"):
        out["title"] = snap["title"]
    if snap.get("alt"):
        # vim/top 처럼 화면을 통째로 쓰는 프로그램이 떠 있다는 뜻.
        out["fullscreen_app"] = True
    if status != "running":
        out["exit_code"] = meta.get("exit_code")
    return out


def _screen_text(snap):
    lines = snap.get("lines") or []
    # 화면 아래쪽 빈 줄은 잘라 낸다 — 커서 아래 여백을 그대로 보낼 이유가 없다.
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    return "\n".join(lines)


# =============================================================== 도구: 목록/생성


@tool(
    "term_list",
    "List the terminal sessions open in this project (like `screen -ls`). "
    "Each entry gives the id you pass to the other term_* tools, what is "
    "running in it, whether it is still alive, and how recently it produced "
    "output. Call this first if you do not have an id.",
    {"type": "object", "properties": {}},
)
def term_list(args):
    out = []
    for d, meta in _session_dirs():
        snap = _screen(d)
        item = _state(d, meta, snap)
        item["command"] = meta.get("command")
        item["cwd"] = meta.get("cwd")
        item["started_at"] = meta.get("started_at")
        item["last_output_at"] = snap.get("at")
        item["scrollback_lines"] = len(_scroll_lines(d))
        out.append(item)
    return {
        "terminals": out,
        "count": len(out),
        "hint": "Use term_open to start one." if not out else None,
    }


@tool(
    "term_open",
    "Open a new terminal session and return its id plus the first screen. "
    "With no `command` you get an interactive shell that stays open - send "
    "commands to it with term_send. With a `command` the session runs that "
    "instead (use this for a REPL, a dev server, ssh, or any program that "
    "draws a screen). The session keeps running after this call returns, and "
    "after the conversation ends, until term_close or the user stops it. "
    "Prefer run_command for a one-shot command whose output you just want.",
    {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "Command to run in the terminal (default: an "
                               "interactive shell).",
            },
            "name": {
                "type": "string",
                "description": "Short label so you and the user can tell "
                               "sessions apart (e.g. 'server', 'repl').",
            },
            "cwd": {
                "type": "string",
                "description": "Starting directory (default: project root).",
            },
            "cols": {"type": "integer", "description": "Terminal width (default 120)."},
            "rows": {"type": "integer", "description": "Terminal height (default 32)."},
            "wait": {
                "type": "integer",
                "description": "Seconds to wait for the first output to settle "
                               "before returning (default 10, 0 = return at once).",
            },
        },
    },
)
def term_open(args):
    cwd = _resolve_cwd(args.get("cwd") or ".")
    term_id = uuid.uuid4().hex[:12]
    proc_dir = os.path.join(_proc_root(), term_id)
    os.makedirs(proc_dir, exist_ok=True)
    # 러너가 쓰기 전에 조회가 들어와도 깨지지 않게 미리 만들어 둔다.
    for fn in ("raw.log", "scrollback.txt", "stdin", "ctrl"):
        open(os.path.join(proc_dir, fn), "ab").close()
    spec = {
        "id": term_id,
        "kind": "terminal",
        "command": (args.get("command") or "").strip(),
        "name": (args.get("name") or "").strip(),
        "cwd": cwd,
        "cols": int(args.get("cols") or 0) or 120,
        "rows": int(args.get("rows") or 0) or 32,
    }
    with open(os.path.join(proc_dir, "spec.json"), "w", encoding="utf-8") as f:
        json.dump(spec, f, ensure_ascii=False)

    kwargs = {
        "cwd": proc_dir,
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
    }
    if os.name == "posix":
        kwargs["start_new_session"] = True
    else:
        kwargs["creationflags"] = _DETACHED_PROCESS | _CREATE_NEW_PROCESS_GROUP
    subprocess.Popen([sys.executable, "-u", TERM_RUNNER, proc_dir], **kwargs)

    # 러너가 meta.json 을 쓸 때까지 잠깐 기다린다(없으면 id 밖에 못 돌려준다).
    meta = {}
    deadline = time.time() + 10
    while time.time() < deadline:
        meta = _read_json(os.path.join(proc_dir, "meta.json"))
        if meta:
            break
        time.sleep(0.05)
    if not meta:
        raise ToolError("The terminal did not start (no meta.json).")

    wait = args.get("wait")
    wait = DEFAULT_WAIT if wait is None else int(wait)
    # 셸이 프롬프트를 찍을 때까지 기다린다 — 지금 리비전에서 **움직인 뒤**의 조용함만
    # 인정한다(폴백 안내 배너가 이미 찍혀 있을 수 있다).
    _wait_idle(proc_dir, wait, DEFAULT_IDLE, since_rev=_rev(proc_dir))
    snap = _screen(proc_dir)
    meta = _read_json(os.path.join(proc_dir, "meta.json"), meta)
    result = _state(proc_dir, meta, snap)
    result["screen"] = _clip(_screen_text(snap))
    result["hint"] = (
        "Send input with term_send(id='%s', text='...'). The session stays "
        "open until term_close." % term_id
    )
    if not meta.get("pty", True):
        result["warning"] = (
            "No pseudo-terminal available on this machine (%s), so this "
            "session runs on plain pipes: interactive and full-screen "
            "programs (vim, top, password prompts) will not work here, and "
            "output may arrive in lumps. Line-oriented commands still work."
            % (meta.get("pty_error") or "unknown reason")
        )
    return result


# ================================================================ 도구: 읽기


@tool(
    "term_read",
    "Read what a terminal session shows. `mode` picks what you get:\n"
    "- screen (default): the grid as it looks right now. This is what a human "
    "sees - a progress bar is ONE line, not every frame it drew.\n"
    "- tail: the last `lines` lines of scrollback followed by the screen. Use "
    "this for ordinary command output.\n"
    "- new: only what scrolled past since your previous `new` read, plus the "
    "screen. Safe to call repeatedly while waiting - it does not resend what "
    "you already saw.\n"
    "- range: scrollback lines `from`..`from+lines` (1-based), for reading "
    "around a term_search hit.\n"
    "By default it first waits up to `wait` seconds for output to go quiet, so "
    "you do not read a half-finished response.",
    {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "Terminal id from term_open/term_list."},
            "mode": {
                "type": "string",
                "enum": ["screen", "tail", "new", "range"],
                "description": "What to return (default: screen).",
            },
            "lines": {
                "type": "integer",
                "description": "How many scrollback lines for tail/range (default 200).",
            },
            "from": {
                "type": "integer",
                "description": "First scrollback line for mode=range (1-based).",
            },
            "wait": {
                "type": "integer",
                "description": "Seconds to wait for output to settle first "
                               "(default 0 - read immediately).",
            },
        },
    },
)
def term_read(args):
    proc_dir, meta = _find(args)
    wait = int(args.get("wait") or 0)
    if wait:
        _wait_idle(proc_dir, wait, DEFAULT_IDLE)
    mode = (args.get("mode") or "screen").strip().lower()
    snap = _screen(proc_dir)
    meta = _read_json(os.path.join(proc_dir, "meta.json"), meta)
    result = _state(proc_dir, meta, snap)
    result["mode"] = mode
    screen_text = _screen_text(snap)

    if mode == "screen":
        result["screen"] = _clip(screen_text)
        return result

    if mode == "range":
        lines = _scroll_lines(proc_dir)
        start = max(1, int(args.get("from") or 1))
        count = max(1, int(args.get("lines") or DEFAULT_TAIL_LINES))
        chunk = lines[start - 1 : start - 1 + count]
        result["from"] = start
        result["total_scrollback_lines"] = len(lines)
        result["scrollback"] = _clip("\n".join(chunk))
        return result

    if mode == "new":
        cur = _read_json(_cursor_path(proc_dir))
        start = int(cur.get("scrollback_lines") or 0)
        lines = _scroll_lines(proc_dir)
        if start > len(lines):
            start = 0  # 스크롤백이 잘렸다 — 처음부터
        new_lines = lines[start:]
        try:
            with open(_cursor_path(proc_dir), "w", encoding="utf-8") as f:
                json.dump({"scrollback_lines": len(lines)}, f)
        except OSError:
            pass  # 최악의 경우 다음에 같은 내용을 다시 준다
        result["incremental"] = True
        result["new_output"] = _clip("\n".join(new_lines))
        result["screen"] = _clip(screen_text)
        if not new_lines and snap.get("rev"):
            result["note"] = (
                "Nothing scrolled past since your last read. The screen above "
                "is current - if you are waiting for something, call again "
                "with wait."
            )
        return result

    # tail
    count = max(1, int(args.get("lines") or DEFAULT_TAIL_LINES))
    lines = _scroll_lines(proc_dir)
    tail = lines[-count:] if count < len(lines) else lines
    body = "\n".join(tail)
    if screen_text:
        body = (body + "\n" + screen_text) if body else screen_text
    result["total_scrollback_lines"] = len(lines)
    result["text"] = _clip(body)
    return result


# ================================================================ 도구: 입력


# 키 이름 → 터미널이 실제로 받는 바이트.
_KEYS = {
    "enter": b"\r",
    "return": b"\r",
    "tab": b"\t",
    "esc": b"\x1b",
    "escape": b"\x1b",
    "space": b" ",
    "backspace": b"\x7f",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "right": b"\x1b[C",
    "left": b"\x1b[D",
    "home": b"\x1b[H",
    "end": b"\x1b[F",
    "pageup": b"\x1b[5~",
    "pagedown": b"\x1b[6~",
    "insert": b"\x1b[2~",
    "delete": b"\x1b[3~",
}
for _i in range(1, 13):
    _KEYS["f%d" % _i] = (
        b"\x1bO" + bytes([ord("P") + _i - 1])
        if _i <= 4
        else b"\x1b[" + str(10 + _i).encode() + b"~"
    )


def _key_bytes(name):
    key = str(name).strip().lower().replace("_", "-")
    if key in _KEYS:
        return _KEYS[key]
    for prefix in ("ctrl-", "c-", "^"):
        if key.startswith(prefix):
            ch = key[len(prefix) :]
            if len(ch) == 1 and "a" <= ch <= "z":
                return bytes([ord(ch) - ord("a") + 1])
            if ch == "[":
                return b"\x1b"
            break
    for prefix in ("alt-", "m-"):
        if key.startswith(prefix) and len(key) > len(prefix):
            return b"\x1b" + key[len(prefix) :].encode("utf-8")
    if len(key) == 1:
        return key.encode("utf-8")
    raise ToolError(
        "Unknown key '%s'. Use a name (enter, tab, esc, up, down, left, "
        "right, home, end, pageup, pagedown, delete, backspace, f1-f12) or "
        "ctrl-<letter> / alt-<letter>." % name
    )


@tool(
    "term_send",
    "Type into a terminal session and (by default) hand back the screen once "
    "output settles - so one call is 'run this and show me what happened'.\n"
    "`text` is typed literally and Enter is appended unless you set "
    "enter=false. `keys` sends special keys instead: a list of names such as "
    "['ctrl-c'], ['esc',':wq','enter'], ['up','enter']. Give text or keys or "
    "both (text is sent first).\n"
    "Use ctrl-c here to interrupt whatever is running INSIDE the terminal; "
    "term_close ends the whole session.",
    {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "Terminal id from term_open/term_list."},
            "text": {
                "type": "string",
                "description": "Text to type (a shell command, an answer to a "
                               "prompt, …).",
            },
            "enter": {
                "type": "boolean",
                "description": "Append Enter after `text` (default true). Set "
                               "false to leave the line uncommitted.",
            },
            "keys": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Special keys to send, in order. Names: enter, "
                               "tab, esc, space, backspace, delete, up, down, "
                               "left, right, home, end, pageup, pagedown, "
                               "f1-f12, ctrl-<letter>, alt-<letter>.",
            },
            "read": {
                "type": "boolean",
                "description": "Return the screen afterwards (default true).",
            },
            "wait": {
                "type": "integer",
                "description": "Seconds to wait for output to settle before "
                               "reading back (default 10). Raise it for slow "
                               "commands; the session keeps running either way.",
            },
        },
    },
)
def term_send(args):
    proc_dir, meta = _find(args)
    if (meta.get("status") or "running") != "running":
        raise ToolError(
            "That terminal has already exited (exit code %s). Open a new one "
            "with term_open." % meta.get("exit_code")
        )
    payload = b""
    text = args.get("text")
    if text is not None and text != "":
        payload += str(text).encode("utf-8")
        if args.get("enter", True):
            payload += b"\r"
    keys = args.get("keys")
    if isinstance(keys, str):
        # 모델이 배열 대신 문자열 하나로 보내는 일이 잦다(§note 2026-08-14).
        keys = [k for k in re.split(r"[,\s]+", keys) if k]
    if keys:
        for k in keys:
            payload += _key_bytes(k)
    if not payload:
        raise ToolError("Give `text` or `keys` — there is nothing to send.")

    # 보내기 **직전**의 리비전을 잡아 둔다 — 이게 없으면 "아직 아무 일도 안 일어난
    # 조용함" 을 완료로 오해한다(§_wait_idle).
    before_rev = _rev(proc_dir)
    # 러너가 tail 하는 파일에 **그대로** 붙인다(프로세스 패널의 입력과 같은 통로).
    try:
        with open(os.path.join(proc_dir, "stdin"), "ab") as f:
            f.write(payload)
            f.flush()
    except OSError as e:
        raise ToolError("Could not send input: %s" % e)

    if not args.get("read", True):
        return _state(proc_dir, meta)

    wait = args.get("wait")
    wait = DEFAULT_WAIT if wait is None else int(wait)
    settled = _wait_idle(proc_dir, wait, DEFAULT_IDLE, since_rev=before_rev)
    snap = _screen(proc_dir)
    meta = _read_json(os.path.join(proc_dir, "meta.json"), meta)
    result = _state(proc_dir, meta, snap)
    result["sent"] = len(payload)
    result["screen"] = _clip(_screen_text(snap))
    if not settled and wait:
        result["note"] = (
            "Still producing output after %ds — the screen above is a "
            "snapshot, not the end. Call term_read again (with wait) to see "
            "how it finished." % wait
        )
    return result


# ================================================================ 도구: 검색


@tool(
    "term_search",
    "Search a terminal's scrollback and current screen for text, and return "
    "the matching lines with their line numbers. Use this instead of reading "
    "a long session back in full - find the error, then term_read with "
    "mode='range' and from=<line> to read around it.",
    {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "Terminal id from term_open/term_list."},
            "query": {"type": "string", "description": "Text or regex to look for."},
            "regex": {"type": "boolean", "description": "Treat query as a regex."},
            "ignore_case": {"type": "boolean", "description": "Case-insensitive (default true)."},
            "max_results": {"type": "integer", "description": "Max matches (default 100)."},
            "context": {
                "type": "integer",
                "description": "Lines of context to include around each match "
                               "(default 0).",
            },
        },
        "required": ["query"],
    },
)
def term_search(args):
    proc_dir, meta = _find(args)
    query = str(args.get("query") or "").strip()
    if not query:
        raise ToolError("`query` is required.")
    flags = re.IGNORECASE if args.get("ignore_case", True) else 0
    pattern = re.compile(
        query if args.get("regex") else re.escape(query), flags
    )
    limit = max(1, int(args.get("max_results") or 100))
    ctx = max(0, min(int(args.get("context") or 0), 10))

    lines = _scroll_lines(proc_dir)
    scroll_count = len(lines)
    snap = _screen(proc_dir)
    screen_lines = snap.get("lines") or []
    # 스크롤백 뒤에 현재 화면을 이어 붙여 하나의 줄 번호 체계로 본다.
    lines = lines + screen_lines

    matches = []
    for i, line in enumerate(lines):
        if not pattern.search(line):
            continue
        rec = {
            "line": i + 1,
            "text": line[:2000],
            "where": "screen" if i >= scroll_count else "scrollback",
        }
        if ctx:
            rec["context"] = lines[max(0, i - ctx) : i + ctx + 1]
        matches.append(rec)
        if len(matches) >= limit:
            break

    result = _state(proc_dir, meta, snap)
    result["query"] = query
    result["matches"] = matches
    result["match_count"] = len(matches)
    result["total_lines"] = len(lines)
    result["scrollback_lines"] = scroll_count
    if not matches:
        result["note"] = (
            "No match in %d lines. The scrollback only holds what scrolled "
            "off the screen — if the output is still on screen, term_read "
            "mode='screen' shows it." % len(lines)
        )
    elif len(matches) >= limit:
        result["note"] = "Stopped at %d matches; narrow the query." % limit
    return result


# ================================================================ 도구: 종료


@tool(
    "term_close",
    "End a terminal session and everything running in it. Use this when you "
    "are done with the session — not to interrupt a command (send ctrl-c "
    "with term_send for that), and not merely because something is slow. A "
    "session you leave open costs nothing and the user can watch it in the "
    "process panel.",
    {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "Terminal id from term_open/term_list."},
        },
    },
)
def term_close(args):
    proc_dir, meta = _find(args)
    pid = meta.get("pid")
    status = meta.get("status") or "running"
    stopped = False
    meta_path = os.path.join(proc_dir, "meta.json")

    def wait_ended(seconds):
        # 러너가 자식의 죽음을 알아채고 meta 를 갱신할 때까지 기다린다.
        deadline = time.time() + seconds
        while True:
            cur = _read_json(meta_path, meta)
            if (cur.get("status") or "running") != "running":
                return cur, True
            if time.time() >= deadline:
                return cur, False
            time.sleep(0.1)

    if status == "running" and pid:
        if os.name == "nt":
            try:
                subprocess.run(
                    ["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True
                )
                stopped = True
            except (OSError, subprocess.SubprocessError):
                pass  # 이미 사라졌다 — 아래에서 상태로 확인한다
            meta, _ = wait_ended(5)
        else:
            import signal

            # ★ 대화형 셸은 SIGTERM 을 **무시한다**(POSIX). 진짜 터미널을 닫을 때처럼
            # SIGHUP 부터 보낸다 — 셸은 끝나면서 자기 작업들에도 HUP 을 전한다.
            # 그래도 안 끝나면(HUP 을 무시하는 프로그램) TERM, 마지막으로 KILL.
            for sig, grace in ((signal.SIGHUP, 2), (signal.SIGTERM, 2), (signal.SIGKILL, 3)):
                try:
                    try:
                        os.killpg(pid, sig)
                    except (OSError, ProcessLookupError):
                        os.kill(pid, sig)
                    stopped = True
                except (OSError, ProcessLookupError):
                    pass  # 이미 사라졌다 — 상태로 확인한다
                meta, ended = wait_ended(grace)
                if ended:
                    break
    result = _state(proc_dir, meta)
    result["stopped"] = stopped
    result["final_screen"] = _clip(_screen_text(_screen(proc_dir)))
    return result


# --- entry point ---


def _describe():
    return {
        "module": MODULE_NAME,
        "version": MODULE_VERSION,
        "tools": [t["schema"] for t in _TOOLS.values()],
    }


def _call(tool_name, args):
    entry = _TOOLS.get(tool_name)
    if entry is None:
        return {"ok": False, "error": "Unknown tool: %s" % tool_name}
    try:
        return {"ok": True, "result": entry["func"](args or {})}
    except ToolError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001 - surface any tool error to the LLM
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}


def main(argv):
    if len(argv) < 2 or argv[1] not in ("describe", "call"):
        sys.stderr.write("usage: collabo_term.py {describe|call <tool>}\n")
        return 2

    if argv[1] == "describe":
        sys.stdout.write(json.dumps(_describe(), ensure_ascii=False))
        return 0

    if len(argv) < 3:
        sys.stdout.write(json.dumps({"ok": False, "error": "Tool name is required."}))
        return 0
    raw = sys.stdin.read()
    try:
        args = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        sys.stdout.write(
            json.dumps({"ok": False, "error": "Invalid argument JSON: %s" % e})
        )
        return 0
    sys.stdout.write(json.dumps(_call(argv[2], args), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
