#!/usr/bin/env python3
"""Collabo IDE - detached background command runner.

`run_command` (collabo_tools.py) uses this wrapper to launch a command in the
background. It must OUTLIVE its parent (the short-lived tool-call process): it
runs the command, streams stdout/stderr to log files, updates a status file
(meta.json), and forwards input appended to a `stdin` file to the child.

usage: python -u proc_runner.py <procDir>

  <procDir>/spec.json   (in)  {"id","command","cwd"}
  <procDir>/meta.json   (out) {"id","pid","command","cwd","started_at",
                               "status","exit_code?","ended_at?"}
  <procDir>/stdout.log  (out) child stdout (live)
  <procDir>/stderr.log  (out) child stderr (live)
  <procDir>/stdin       (in)  native/tool appends -> forwarded to child stdin

`status` is one of: running | exited | killed. `pid` is the child (shell) pid,
which is also the process-group leader, so the native side can terminate the
whole tree by that pid.
"""

import json
import os
import subprocess
import sys
import threading
import time

# Windows process creation flags (avoid importing on POSIX).
_DETACHED_PROCESS = 0x00000008
_CREATE_NEW_PROCESS_GROUP = 0x00000200


def _write_meta(proc_dir, meta):
    """Write meta.json atomically (readers never see a partial file)."""
    tmp = os.path.join(proc_dir, "meta.json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False)
    os.replace(tmp, os.path.join(proc_dir, "meta.json"))


def _pump_stdin(proc_dir, child, stop):
    """Tail <procDir>/stdin and forward newly appended bytes to child stdin."""
    path = os.path.join(proc_dir, "stdin")
    pos = 0
    while not stop.is_set() and child.poll() is None:
        try:
            if os.path.exists(path):
                size = os.path.getsize(path)
                if size > pos:
                    with open(path, "rb") as f:
                        f.seek(pos)
                        data = f.read(size - pos)
                    pos = size
                    if child.stdin and not child.stdin.closed:
                        child.stdin.write(data)
                        child.stdin.flush()
        except (OSError, ValueError):
            pass  # child stdin closed / file transiently unavailable
        time.sleep(0.15)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: proc_runner.py <procDir>\n")
        return 2
    proc_dir = argv[1]
    with open(os.path.join(proc_dir, "spec.json"), "r", encoding="utf-8") as f:
        spec = json.load(f)
    command = spec.get("command") or ""
    cwd = spec.get("cwd") or None

    out_f = open(os.path.join(proc_dir, "stdout.log"), "wb", buffering=0)
    err_f = open(os.path.join(proc_dir, "stderr.log"), "wb", buffering=0)

    # Put the child in its own session/group so the native side can kill the
    # whole tree by the child pid. (Not DETACHED: this runner is the supervisor
    # and must keep the redirected stdout/stderr handles flowing to the child —
    # DETACHED_PROCESS breaks console/handle inheritance for grandchildren such
    # as the python.exe that `py.exe`/`cmd` launches.)
    kwargs = {}
    if os.name == "posix":
        kwargs["start_new_session"] = True
    else:
        kwargs["creationflags"] = _CREATE_NEW_PROCESS_GROUP

    # PYTHONUNBUFFERED 로 파이썬 자식의 출력이 즉시 로그에 흐르게 한다(뷰어 실시간
    # 표시용). 다른 런타임은 파일 출력 시 블록 버퍼링할 수 있어 완전 실시간은 아니다.
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"

    started = time.time()
    child = subprocess.Popen(
        command,
        shell=True,
        cwd=cwd,
        stdin=subprocess.PIPE,
        stdout=out_f,
        stderr=err_f,
        env=env,
        **kwargs,
    )

    meta = {
        "id": spec.get("id") or os.path.basename(proc_dir.rstrip("/\\")),
        "pid": child.pid,
        "command": command,
        "cwd": cwd or "",
        "started_at": started,
        "status": "running",
    }
    _write_meta(proc_dir, meta)

    stop = threading.Event()
    pump = threading.Thread(
        target=_pump_stdin, args=(proc_dir, child, stop), daemon=True
    )
    pump.start()

    code = child.wait()
    stop.set()
    try:
        if child.stdin and not child.stdin.closed:
            child.stdin.close()
    except OSError:
        pass
    out_f.close()
    err_f.close()

    # Negative return code (POSIX) means terminated by a signal.
    meta["status"] = "killed" if code < 0 else "exited"
    meta["exit_code"] = code
    meta["ended_at"] = time.time()
    _write_meta(proc_dir, meta)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
