#!/usr/bin/env python3
"""Collabo IDE - detached terminal (PTY) session supervisor.

`collabo_term.py` uses this wrapper to open a *terminal session*: a long-lived
shell (or command) attached to a real pseudo-terminal, which both the LLM and
the user can look at and type into. Think GNU `screen`, scoped to one project.

It is the sibling of `proc_runner.py` and lives in the SAME registry
(`<workspace>/.collabo/proc/<id>/`) so the app's process panel lists both with
no extra plumbing. `meta.json` carries `"kind": "terminal"` to tell them apart.

usage: python -u term_runner.py <procDir>

  <procDir>/spec.json      (in)  {"id","kind","command","cwd","cols","rows","name","shell"}
  <procDir>/meta.json      (out) {"id","kind","pid","command","cwd","name","started_at",
                                  "status","pty","cols","rows","exit_code?","ended_at?"}
  <procDir>/raw.log        (out) raw PTY bytes, escape sequences and all
  <procDir>/screen.json    (out) the rendered grid right now + rev/at
  <procDir>/scrollback.txt (out) lines that scrolled off the top, ANSI stripped
  <procDir>/stdin          (in)  appended bytes are written to the PTY verbatim
  <procDir>/ctrl           (in)  one JSON object per line: {"resize":[cols,rows]}

WHY A PTY AND NOT PIPES (the `proc_runner.py` approach)

Without a terminal on the other end, `isatty()` is false and the world changes:
programs switch to block buffering (output arrives in 4KB lumps, or never),
drop colour, skip progress display, and anything interactive - `vim`, `top`,
`ssh` asking for a password, a REPL - either refuses to run or hangs. A PTY is
what makes "use terminal tools" mean anything. `proc_runner.py` stays as it is:
for fire-and-forget commands, pipes are simpler and enough.

`pty` is stdlib on POSIX. On Windows we call ConPTY through `ctypes`, so this
module still needs **no third-party package** - that matters because every
other base tool module here runs on a bare interpreter. If ConPTY is
unavailable (pre-1809 Windows) we fall back to pipes and say so in
`meta.json` (`"pty": false`), rather than failing outright.

`status` is one of: running | exited | killed. `pid` is the child process id,
which is also its process-group/session leader, so the native side terminates
the whole tree by that pid exactly as it does for background commands.
"""

import json
import os
import subprocess
import sys
import threading
import time

# ⚠️ **바이트코드를 남기지 않는다.** 이 러너는 기본 모듈 중 유일하게 옆 모듈을
# import 하는데(`vt_screen`), 그대로 두면 모듈이 놓인 폴더에 `__pycache__` 가
#생긴다. 배포본에서는 `<appSupport>/python_modules/` 라 무해하지만, 개발·테스트
# 중에는 **리포지토리 안**(`assets/python/`)이다 — 이 프로젝트에는 `.gitignore`
# 가 없어 한 번 들어오면 손으로 지워야 한다(§note 10 에 되풀이 항목으로 남아 있다).
# 한 세션에 한 번 하는 import 라 캐시가 아껴 주는 것도 없다.
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vt_screen import DEFAULT_COLS, DEFAULT_ROWS, Screen  # noqa: E402

IS_WINDOWS = os.name == "nt"

# 화면 파일을 다시 쓰는 간격. 더 촘촘히 써 봐야 사람 눈도 LLM 도 못 따라오고,
# 디스크만 두드린다.
FLUSH_INTERVAL = 0.12

# 입력 파일(stdin/ctrl)을 따라가는 간격.
POLL_INTERVAL = 0.05

# 원시 로그 상한. 넘으면 그 뒤로는 쓰지 않는다(화면과 스크롤백은 계속 산다).
MAX_RAW_BYTES = 8 << 20

# 스크롤백 상한. 넘으면 **뒤쪽 절반만 남기고 앞을 버린다**.
MAX_SCROLLBACK_BYTES = 8 << 20


def _write_json(path, obj):
    """원자적으로 쓴다 — 읽는 쪽이 반쯤 쓰인 파일을 보지 않게."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def _default_shell():
    if IS_WINDOWS:
        for name in ("powershell.exe", "cmd.exe"):
            for d in os.environ.get("PATH", "").split(os.pathsep):
                cand = os.path.join(d, name)
                if os.path.isfile(cand):
                    return cand
        return os.environ.get("COMSPEC", "cmd.exe")
    # $SHELL 이 가리키는 게 실제로 있어야 한다 — collaboCore 게스트(busybox)에는
    # bash 가 없고 /bin/sh 뿐이다. 예전엔 /bin/bash 를 그대로 믿어 폴백까지 죽었다.
    for cand in (os.environ.get("SHELL"), "/bin/bash", "/bin/sh"):
        if cand and os.path.exists(cand):
            return cand
    return "/bin/sh"


def _child_env(cols, rows):
    env = dict(os.environ)
    # 터미널이 붙어 있다고 알려 준다. 이게 없으면 색·커서 제어를 아예 안 쓰는
    # 프로그램이 많다(그래도 되지만, 그러면 PTY 를 쓸 이유가 없다).
    env.setdefault("TERM", "xterm-256color")
    env["COLUMNS"] = str(cols)
    env["LINES"] = str(rows)
    env["PYTHONUNBUFFERED"] = "1"
    # 페이저가 끼어들면 에이전트가 `q` 를 눌러야 빠져나온다 — 기본은 끄고,
    # 사용자가 필요하면 명령에서 직접 켠다.
    env.setdefault("PAGER", "cat")
    env.setdefault("GIT_PAGER", "cat")
    return env


# ============================================================ PTY 백엔드(POSIX)


# fork 없이 PosixPty 의 _setup 과 같은 일을 한다: argv = [tty 경로, 프로그램, 인자...].
# 세션 리더가 O_NOCTTY 없이 처음 연 tty 는 제어 터미널이 된다(TIOCSCTTY 는 확인 사살).
# exec 하므로 pid 는 그대로 프로그램의 것이 된다(meta.json 의 pid·killpg 가 그대로 맞는다).
_CTTY_TRAMPOLINE = """\
import os, sys
os.setsid()
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    import fcntl, termios
    fcntl.ioctl(fd, termios.TIOCSCTTY, 0)
except OSError:
    pass
for i in (0, 1, 2):
    os.dup2(fd, i)
if fd > 2:
    os.close(fd)
os.execvp(sys.argv[2], sys.argv[2:])
"""


def _openpty(pty):
    """(master, slave). slave 는 **반드시 O_NOCTTY** 로 연다.

    `pty.openpty()` 는 `os.openpty()`(UNIX98, /dev/pts)가 안 되면 구식 BSD pty
    (/dev/ptyXY ↔ /dev/ttyXY)로 물러서는데, 그때 slave 를 O_NOCTTY 없이 연다. 러너는
    세션 리더(start_new_session)라 그 tty 가 **러너의 제어 터미널**이 돼 버린다 —
    셸은 제어 터미널을 못 얻고(ctrl-c 가 셸이 아니라 러너로 간다), 셸이 끝나면 행업
    SIGHUP 이 러너를 죽여 meta.json 이 영영 running 으로 남는다.
    devpts 가 없는 collaboCore 게스트에서 실제로 그랬다(2026-09-22).
    """
    try:
        return os.openpty()
    except OSError:
        pass
    master, slave_name = pty._open_terminal()  # BSD 방식 탐색(stdlib 내부 함수)
    return master, os.open(slave_name, os.O_RDWR | os.O_NOCTTY)


class PosixPty(object):
    """stdlib `pty` 로 연 의사 터미널."""

    def __init__(self, argv, cwd, env, cols, rows):
        import fcntl
        import pty
        import struct
        import termios

        self._fcntl, self._termios, self._struct = fcntl, termios, struct
        self.master, slave = _openpty(pty)
        self._set_winsize(slave, cols, rows)

        def _setup():
            # 세션 리더가 되고, 이 PTY 를 **제어 터미널**로 붙인다. 이게 없으면
            # 잡 컨트롤이 죽어 ctrl-c 가 프로그램에 전달되지 않는다.
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        if hasattr(os, "fork"):
            spawn_argv, extra = argv, {"preexec_fn": _setup}
        else:
            # fork 가 없는 곳(collaboCore 게스트: subprocess 가 posix_spawn 으로만 돈다)
            # 에서는 preexec_fn 을 못 쓴다 → 같은 일을 하는 트램펄린을 거쳐 exec 한다.
            spawn_argv = [sys.executable, "-c", _CTTY_TRAMPOLINE, os.ttyname(slave)] + list(argv)
            extra = {}
        self.proc = subprocess.Popen(
            spawn_argv,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            cwd=cwd,
            env=env,
            close_fds=True,
            **extra
        )
        os.close(slave)
        self.pid = self.proc.pid

    def _set_winsize(self, fd, cols, rows):
        packed = self._struct.pack("HHHH", rows, cols, 0, 0)
        self._fcntl.ioctl(fd, self._termios.TIOCSWINSZ, packed)

    def read(self, size=65536):
        try:
            return os.read(self.master, size)
        except OSError:
            return b""  # 자식이 끝나면 EIO 가 난다 — 정상 종료로 본다

    def write(self, data):
        os.write(self.master, data)

    def resize(self, cols, rows):
        self._set_winsize(self.master, cols, rows)

    def poll(self):
        return self.proc.poll()

    def close(self):
        try:
            os.close(self.master)
        except OSError:
            pass


# ========================================================== PTY 백엔드(Windows)


class WindowsPty(object):
    """ConPTY(`CreatePseudoConsole`)를 ctypes 로 직접 부른다.

    Windows 10 1809+ 필요. 실패하면 호출측이 파이프로 떨어진다.
    """

    _PSEUDOCONSOLE_ATTR = 0x00020016
    _EXTENDED_STARTUPINFO_PRESENT = 0x00080000

    def __init__(self, argv, cwd, env, cols, rows):
        import ctypes
        import msvcrt
        from ctypes import wintypes

        self._ctypes = ctypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._k32 = k32

        class COORD(ctypes.Structure):
            _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]

        class STARTUPINFOW(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD),
                ("lpReserved", wintypes.LPWSTR),
                ("lpDesktop", wintypes.LPWSTR),
                ("lpTitle", wintypes.LPWSTR),
                ("dwX", wintypes.DWORD),
                ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD),
                ("dwYSize", wintypes.DWORD),
                ("dwXCountChars", wintypes.DWORD),
                ("dwYCountChars", wintypes.DWORD),
                ("dwFillAttribute", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD),
                ("wShowWindow", wintypes.WORD),
                ("cbReserved2", wintypes.WORD),
                ("lpReserved2", ctypes.POINTER(ctypes.c_byte)),
                ("hStdInput", wintypes.HANDLE),
                ("hStdOutput", wintypes.HANDLE),
                ("hStdError", wintypes.HANDLE),
            ]

        class STARTUPINFOEXW(ctypes.Structure):
            _fields_ = [
                ("StartupInfo", STARTUPINFOW),
                ("lpAttributeList", ctypes.c_void_p),
            ]

        class PROCESS_INFORMATION(ctypes.Structure):
            _fields_ = [
                ("hProcess", wintypes.HANDLE),
                ("hThread", wintypes.HANDLE),
                ("dwProcessId", wintypes.DWORD),
                ("dwThreadId", wintypes.DWORD),
            ]

        self._COORD = COORD
        k32.CreatePseudoConsole.argtypes = [
            COORD,
            wintypes.HANDLE,
            wintypes.HANDLE,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.HANDLE),
        ]
        k32.CreatePseudoConsole.restype = ctypes.HRESULT
        k32.ResizePseudoConsole.argtypes = [wintypes.HANDLE, COORD]
        k32.ResizePseudoConsole.restype = ctypes.HRESULT
        k32.ClosePseudoConsole.argtypes = [wintypes.HANDLE]
        k32.ClosePseudoConsole.restype = None

        # 두 개의 익명 파이프: 우리가 쓰는 쪽(입력)과 읽는 쪽(출력).
        in_read = wintypes.HANDLE()
        in_write = wintypes.HANDLE()
        out_read = wintypes.HANDLE()
        out_write = wintypes.HANDLE()
        if not k32.CreatePipe(ctypes.byref(in_read), ctypes.byref(in_write), None, 0):
            raise ctypes.WinError(ctypes.get_last_error())
        if not k32.CreatePipe(ctypes.byref(out_read), ctypes.byref(out_write), None, 0):
            raise ctypes.WinError(ctypes.get_last_error())

        self.hpc = wintypes.HANDLE()
        k32.CreatePseudoConsole(
            COORD(cols, rows), in_read, out_write, 0, ctypes.byref(self.hpc)
        )
        # ConPTY 가 자기 몫을 복제해 갔다 — 우리 쪽 핸들은 닫아야 EOF 가 온다.
        k32.CloseHandle(in_read)
        k32.CloseHandle(out_write)

        # STARTUPINFOEX 에 의사 콘솔 속성을 얹는다.
        size = ctypes.c_size_t(0)
        k32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        buf = (ctypes.c_byte * size.value)()
        attrs = ctypes.cast(buf, ctypes.c_void_p)
        if not k32.InitializeProcThreadAttributeList(
            attrs, 1, 0, ctypes.byref(size)
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        if not k32.UpdateProcThreadAttribute(
            attrs,
            0,
            ctypes.c_size_t(self._PSEUDOCONSOLE_ATTR),
            self.hpc,
            ctypes.sizeof(wintypes.HANDLE),
            None,
            None,
        ):
            raise ctypes.WinError(ctypes.get_last_error())

        si = STARTUPINFOEXW()
        si.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
        si.lpAttributeList = attrs
        pi = PROCESS_INFORMATION()

        cmdline = subprocess.list2cmdline(argv)
        env_block = "\0".join("%s=%s" % kv for kv in env.items()) + "\0\0"
        ok = k32.CreateProcessW(
            None,
            ctypes.create_unicode_buffer(cmdline),
            None,
            None,
            False,
            self._EXTENDED_STARTUPINFO_PRESENT | 0x00000400,  # CREATE_UNICODE_ENVIRONMENT
            ctypes.create_unicode_buffer(env_block),
            cwd,
            ctypes.byref(si.StartupInfo),
            ctypes.byref(pi),
        )
        k32.DeleteProcThreadAttributeList(attrs)
        if not ok:
            k32.ClosePseudoConsole(self.hpc)
            raise ctypes.WinError(ctypes.get_last_error())

        k32.CloseHandle(pi.hThread)
        self._hprocess = pi.hProcess
        self.pid = int(pi.dwProcessId)
        # CRT fd 로 감싸면 그 뒤로는 POSIX 와 같은 os.read/os.write 로 다룬다.
        self._read_fd = msvcrt.open_osfhandle(out_read.value, os.O_RDONLY)
        self._write_fd = msvcrt.open_osfhandle(in_write.value, 0)
        self._exit_code = None

    def read(self, size=65536):
        try:
            return os.read(self._read_fd, size)
        except OSError:
            return b""

    def write(self, data):
        os.write(self._write_fd, data)

    def resize(self, cols, rows):
        self._k32.ResizePseudoConsole(self.hpc, self._COORD(cols, rows))

    def poll(self):
        if self._exit_code is not None:
            return self._exit_code
        ctypes = self._ctypes
        from ctypes import wintypes

        code = wintypes.DWORD()
        if self._k32.GetExitCodeProcess(self._hprocess, ctypes.byref(code)):
            if code.value != 259:  # STILL_ACTIVE
                self._exit_code = int(code.value)
                return self._exit_code
        return None

    def close(self):
        try:
            self._k32.ClosePseudoConsole(self.hpc)
        except Exception:
            pass
        for fd in (self._read_fd, self._write_fd):
            try:
                os.close(fd)
            except OSError:
                pass


def _conpty_usable():
    """ConPTY 가 **실제로 자식을 받아 주는지** 한 번 시험해 본다.

    ⚠️ 이 검사가 필요한 이유(2026-09-16 에 여기서 데였다): 이 환경
    (Parallels 위의 Windows 11 ARM64, build 26200)에서는 `CreatePseudoConsole`,
    `InitializeProcThreadAttributeList`, `UpdateProcThreadAttribute`,
    `CreateProcessW` 가 **전부 성공을 돌려주는데** 자식은 의사 콘솔이 아니라
    **부모 콘솔에 붙는다.** 속성 리스트 바이트를 덤프해 보면 0x20016 / size 8 /
    HPCON 값까지 정확히 들어가 있고, 플래그 조합(CREATE_NO_WINDOW ·
    DETACHED_PROCESS · CREATE_NEW_CONSOLE)이나 부모 콘솔 유무를 바꿔도 같다.
    즉 **반환값으로는 실패를 알 수 없다.**

    그대로 두면 세션이 열리자마자 죽고(자식의 stdin 이 EOF) 화면은 빈 채로
    남는다 — 사용자에게는 "터미널이 안 된다" 로만 보인다. 그래서 무해한 명령
    하나를 실제로 태워 보고, 출력이 통로로 돌아오는지로 판정한다.

    비용은 세션 하나당 최대 2초이고 Windows 에서만 든다.
    """
    if not IS_WINDOWS:
        return True
    comspec = os.environ.get("COMSPEC", "cmd.exe")
    token = "COLLABOPTY%d" % os.getpid()
    probe = None
    try:
        probe = WindowsPty(
            [comspec, "/c", "echo " + token], None, dict(os.environ), 60, 10
        )
    except Exception:
        return False
    # ⚠️ 판정은 **렌더된 화면**으로 한다. 원시 바이트에는 ConPTY 자신의 핸드셰이크
    # (`ESC[?9001h`)와 창 제목 OSC 가 섞여 있어, 거기서 토큰을 찾으면 제목에 걸려
    # 거짓 통과가 난다(처음에 `.` 하나로 보다가 정확히 이렇게 속았다).
    screen = Screen(60, 10)
    lock = threading.Lock()

    def _read():
        try:
            while True:
                data = probe.read()
                if not data:
                    break
                with lock:
                    screen.feed(data)
        except Exception:
            pass

    threading.Thread(target=_read, daemon=True).start()

    def _hit():
        with lock:
            return any(token in line for line in screen.display())

    deadline = time.time() + 2.0
    ok = False
    while time.time() < deadline:
        if _hit():
            ok = True
            break
        time.sleep(0.05)
    try:
        probe.close()
    except Exception:
        pass
    return ok


# ====================================================== 폴백: PTY 없이 파이프로


class PipeBackend(object):
    """PTY 를 못 열었을 때. 대화형 프로그램은 안 되지만 아무것도 안 되는 것보다 낫다."""

    def __init__(self, argv, cwd, env, cols, rows):
        kwargs = {}
        if IS_WINDOWS:
            kwargs["creationflags"] = 0x00000200  # CREATE_NEW_PROCESS_GROUP
        else:
            kwargs["start_new_session"] = True
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=cwd,
            env=env,
            bufsize=0,
            **kwargs
        )
        self.pid = self.proc.pid

    def read(self, size=65536):
        try:
            # `stdout.read(size)` 는 size 바이트가 다 찰 때까지 기다린다 — 터미널은
            # 온 만큼 바로 보여 줘야 하므로 fd 에서 직접 읽는다.
            return os.read(self.proc.stdout.fileno(), size)
        except (OSError, ValueError):
            return b""

    def write(self, data):
        try:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()
        except (OSError, ValueError):
            pass

    def resize(self, cols, rows):
        pass  # 파이프에는 창 크기가 없다

    def poll(self):
        return self.proc.poll()

    def close(self):
        for s in (self.proc.stdin, self.proc.stdout):
            try:
                if s:
                    s.close()
            except OSError:
                pass


# ==================================================================== 세션 본체


class Session(object):
    def __init__(self, proc_dir, spec):
        self.dir = proc_dir
        self.spec = spec
        self.cols = int(spec.get("cols") or DEFAULT_COLS)
        self.rows = int(spec.get("rows") or DEFAULT_ROWS)
        self.screen = Screen(self.cols, self.rows)
        self.rev = 0
        self.last_data_at = time.time()
        self._dirty = True
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._raw_bytes = 0
        self._raw = open(os.path.join(proc_dir, "raw.log"), "ab", buffering=0)
        self._scroll_path = os.path.join(proc_dir, "scrollback.txt")
        self._screen_path = os.path.join(proc_dir, "screen.json")
        self.meta = {}

    # ------------------------------------------------------------------ 시작

    def start(self):
        command = (self.spec.get("command") or "").strip()
        cwd = self.spec.get("cwd") or None
        shell = self.spec.get("shell") or _default_shell()
        is_cmd = IS_WINDOWS and shell.lower().endswith("cmd.exe")
        if command:
            # 명령을 셸에 태운다 — 파이프·리다이렉션이 그대로 먹게.
            if is_cmd:
                argv = [shell, "/c", command]
            elif IS_WINDOWS:
                argv = [shell, "-NoLogo", "-Command", command]
            else:
                argv = [shell, "-c", command]
        else:
            # 명령이 없으면 **대화형 셸**이다(`screen` 을 그냥 띄운 것과 같다).
            argv = [shell] if (is_cmd or not IS_WINDOWS) else [shell, "-NoLogo"]
        env = _child_env(self.cols, self.rows)

        backend = None
        pty_ok = True
        why = ""
        if not _conpty_usable():
            pty_ok = False
            why = "this Windows build accepts the ConPTY calls but never attaches the child to it"
        else:
            try:
                backend = (WindowsPty if IS_WINDOWS else PosixPty)(
                    argv, cwd, env, self.cols, self.rows
                )
            except Exception as e:  # openpty 실패 / ConPTY 미지원 등
                pty_ok = False
                why = str(e)
        if not pty_ok:
            # 아무것도 안 되는 것보다 낫다 — 줄 단위 명령은 그대로 쓰이고,
            # 대화형 프로그램만 막힌다. 그 사실을 **화면 첫 줄에 남긴다**.
            self.screen.feed(
                ("[collabo] no pseudo-terminal available (%s).\r\n"
                 "[collabo] running on plain pipes: interactive and "
                 "full-screen programs will not work here.\r\n" % why
                 ).encode("utf-8")
            )
            backend = PipeBackend(argv, cwd, env, self.cols, self.rows)
        self.backend = backend

        self.meta = {
            "id": self.spec.get("id") or os.path.basename(self.dir.rstrip("/\\")),
            "kind": "terminal",
            "pid": backend.pid,
            "command": command or shell,
            "name": self.spec.get("name") or "",
            "cwd": cwd or "",
            "shell": shell,
            "pty": pty_ok,
            "pty_error": why,
            "cols": self.cols,
            "rows": self.rows,
            "started_at": time.time(),
            "status": "running",
        }
        # 게스트 pid 표시 — proc_runner.py 와 같은 이유(앱이 호스트에서 kill 하지 않게).
        if os.environ.get("COLLABO_SANDBOX"):
            self.meta["sandbox"] = True
        self._write_meta()

    def _write_meta(self):
        _write_json(os.path.join(self.dir, "meta.json"), self.meta)

    # ------------------------------------------------------------------ 루프

    def _watchdog(self):
        """자식이 끝나면 읽기를 깨운다.

        ⚠️ **ConPTY 는 자식이 죽어도 출력 파이프를 닫아 주지 않는다.** 그대로 두면
        아래 읽기 루프가 영원히 블록돼 세션이 `running` 으로 굳는다 —
        `ClosePseudoConsole` 이 그걸 푸는 유일한 손잡이다. POSIX 는 EIO 로 저절로
        풀리므로 이 스레드는 사실상 Windows 용이지만, 양쪽에 같이 둔다.
        """
        while not self._stop.wait(0.2):
            if self.backend.poll() is not None:
                # 죽기 직전의 출력이 아직 파이프에 남아 있을 수 있어 잠깐 기다린다.
                time.sleep(0.3)
                try:
                    self.backend.close()
                except Exception:
                    pass
                return

    def run(self):
        threading.Thread(target=self._pump_stdin, daemon=True).start()
        threading.Thread(target=self._pump_ctrl, daemon=True).start()
        threading.Thread(target=self._flusher, daemon=True).start()
        threading.Thread(target=self._watchdog, daemon=True).start()
        try:
            while True:
                data = self.backend.read()
                if not data:
                    break
                with self._lock:
                    self.screen.feed(data)
                    self.last_data_at = time.time()
                    self._dirty = True
                    self._append_raw(data)
        except Exception:
            pass
        # 자식이 끝날 때까지 기다린다(출력이 먼저 끊길 수 있다).
        code = self.backend.poll()
        deadline = time.time() + 5
        while code is None and time.time() < deadline:
            time.sleep(0.05)
            code = self.backend.poll()
        self._stop.set()
        self.flush(force=True)
        self.backend.close()
        try:
            self._raw.close()
        except OSError:
            pass
        code = 0 if code is None else code
        self.meta["status"] = "killed" if code < 0 else "exited"
        self.meta["exit_code"] = code
        self.meta["ended_at"] = time.time()
        self._write_meta()

    def _append_raw(self, data):
        if self._raw_bytes >= MAX_RAW_BYTES:
            return
        try:
            self._raw.write(data)
            self._raw_bytes += len(data)
            if self._raw_bytes >= MAX_RAW_BYTES:
                self._raw.write(b"\n[collabo] raw log limit reached\n")
        except OSError:
            pass

    def _flusher(self):
        while not self._stop.wait(FLUSH_INTERVAL):
            self.flush()

    def flush(self, force=False):
        with self._lock:
            if not (self._dirty or force):
                return
            self._dirty = False
            scrolled = self.screen.take_scrolled()
            snap = self.screen.snapshot()
            self.rev += 1
            snap["rev"] = self.rev
            snap["at"] = self.last_data_at
        if scrolled:
            try:
                with open(self._scroll_path, "a", encoding="utf-8") as f:
                    f.write("\n".join(scrolled) + "\n")
                self._trim_scrollback()
            except OSError:
                pass
        try:
            _write_json(self._screen_path, snap)
        except OSError:
            pass

    def _trim_scrollback(self):
        """상한을 넘으면 **뒤쪽 절반만** 남긴다(오래된 출력부터 버린다)."""
        try:
            size = os.path.getsize(self._scroll_path)
            if size <= MAX_SCROLLBACK_BYTES:
                return
            keep = MAX_SCROLLBACK_BYTES // 2
            with open(self._scroll_path, "rb") as f:
                f.seek(size - keep)
                f.readline()  # 잘린 줄은 버린다
                tail = f.read()
            with open(self._scroll_path, "wb") as f:
                f.write(b"[collabo] ... older output dropped ...\n")
                f.write(tail)
        except OSError:
            pass

    # -------------------------------------------------------------- 입력 통로

    def _tail_file(self, name, handle):
        """`<procDir>/<name>` 에 붙는 내용을 따라가며 [handle] 에 넘긴다."""
        path = os.path.join(self.dir, name)
        pos = 0
        while not self._stop.is_set():
            try:
                if os.path.exists(path):
                    size = os.path.getsize(path)
                    if size < pos:
                        pos = 0  # 파일이 잘렸다 — 처음부터
                    if size > pos:
                        with open(path, "rb") as f:
                            f.seek(pos)
                            chunk = f.read(size - pos)
                        pos = size
                        handle(chunk)
            except (OSError, ValueError):
                pass
            time.sleep(POLL_INTERVAL)

    def _pump_stdin(self):
        # **바이트를 그대로** 흘린다. `\x03`(ctrl-c)·방향키·ESC 도 전부 여기로 온다 —
        # 줄 단위로 해석하면 특수키를 보낼 길이 사라진다.
        self._tail_file("stdin", lambda chunk: self.backend.write(chunk))

    def _pump_ctrl(self):
        def handle(chunk):
            for line in chunk.decode("utf-8", errors="replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    cmd = json.loads(line)
                except ValueError:
                    continue
                size = cmd.get("resize")
                if isinstance(size, list) and len(size) == 2:
                    cols, rows = int(size[0]), int(size[1])
                    with self._lock:
                        self.cols, self.rows = cols, rows
                        self.screen.resize(cols, rows)
                        self._dirty = True
                    try:
                        self.backend.resize(cols, rows)
                    except Exception:
                        pass
                    self.meta["cols"], self.meta["rows"] = cols, rows
                    self._write_meta()

        self._tail_file("ctrl", handle)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: term_runner.py <procDir>\n")
        return 2
    proc_dir = argv[1]
    with open(os.path.join(proc_dir, "spec.json"), "r", encoding="utf-8") as f:
        spec = json.load(f)
    session = Session(proc_dir, spec)
    session.start()
    session.run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
