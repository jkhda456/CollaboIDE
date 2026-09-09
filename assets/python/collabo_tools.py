#!/usr/bin/env python3
"""Collabo IDE - base tool module (fixed base module).

The safe execution layer that actually performs the individual operations the
LLM requests via function calling. To keep the LLM from making dangerous file
edits or running risky commands directly, every concrete action goes through
the tools defined here.

Contract:
  describe:
    python collabo_tools.py describe
      -> stdout(JSON): {"module","version","tools":[<OpenAI tool schema>...]}
  call:
    python collabo_tools.py call <tool_name>
      <- stdin(JSON): tool arguments (object)
      -> stdout(JSON): {"ok":true,"result":...}
                     | {"ok":false,"error":"..."}
                     | {"ok":false,"needs_elevation":true,"reason":"..."}

Environment:
  COLLABO_WORKSPACE : workspace root. When set, access outside it is blocked.
  COLLABO_ELEVATED  : "1" when currently running with administrator privileges.

This module is fixed (base). Additional capabilities are added by registering
separate modules that follow the same contract, exposed as extra tools.
"""

import difflib
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid

MODULE_NAME = "collabo_base"
MODULE_VERSION = "0.1.0"

MAX_READ_BYTES = 1 << 20  # 1MB
PROC_TAIL_BYTES = 32 << 10  # 32KB of stdout/stderr returned to the LLM

WORKSPACE = os.environ.get("COLLABO_WORKSPACE") or ""
IS_ELEVATED = os.environ.get("COLLABO_ELEVATED") == "1"

# Detached background-command runner (same directory as this module).
PROC_RUNNER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proc_runner.py")

# Windows process creation flags (used only on Windows).
_DETACHED_PROCESS = 0x00000008
_CREATE_NEW_PROCESS_GROUP = 0x00000200


class ToolError(Exception):
    """An error to return to the user/LLM as a failed tool result."""


class NeedsElevation(Exception):
    """Signals that administrator privileges are required.

    The native side re-runs the tool elevated after this is raised.
    """

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


# Tool registry: name -> {"schema": <openai tool>, "func": callable}
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


# --- path safety ---

def _resolve(path, allow_outside=False):
    """Resolve to a real absolute path and confine it to the workspace.

    Hardening:
    - Resolves symlinks via realpath so a link inside the workspace cannot
      point outside it.
    - Fails safe: if no workspace is set, file operations are blocked
      (instead of allowing everything).
    - Compares case-insensitively on case-insensitive filesystems (Windows).
    """
    if not path or not isinstance(path, str):
        raise ToolError("'path' is required.")
    target = os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    if allow_outside:
        return target
    if not WORKSPACE:
        raise ToolError("No workspace is set; file operations are blocked.")
    root = os.path.realpath(os.path.abspath(WORKSPACE))
    nroot = os.path.normcase(root)
    ntarget = os.path.normcase(target)
    try:
        common = os.path.commonpath([nroot, ntarget])
    except ValueError:
        common = ""  # e.g. different drives on Windows
    if common != nroot:
        raise ToolError("Path is outside the workspace: %s" % target)
    return target


def _diff(before, after, path):
    """before→after 의 통합(unified) diff 문자열(+/-). difflib(stdlib) 사용."""
    lines = list(
        difflib.unified_diff(
            before.split("\n"), after.split("\n"),
            fromfile=path, tofile=path, lineterm="",
        )
    )
    s = "\n".join(lines)
    if len(s) > 20000:
        s = s[:20000] + "\n… (diff truncated)"
    return s


def _str_arg(args, key, required=True, default=""):
    v = args.get(key, default)
    if required and (v is None or v == ""):
        raise ToolError("Required argument '%s' is missing." % key)
    if v is not None and not isinstance(v, str):
        raise ToolError("'%s' must be a string." % key)
    return v


# --- background command registry (.collabo/proc) ---

def _proc_root():
    """`<workspace>/.collabo/proc` — the file registry for background commands."""
    if not WORKSPACE:
        raise ToolError("No workspace is set; cannot run commands.")
    return os.path.join(os.path.abspath(WORKSPACE), ".collabo", "proc")


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _tail_text(path, max_bytes=PROC_TAIL_BYTES):
    """Return the last `max_bytes` of a log file as text (with a marker if cut)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
            data = f.read()
    except OSError:
        return ""
    text = data.decode("utf-8", errors="replace")
    return ("…(truncated)\n" + text) if size > max_bytes else text


def _cursor_path(proc_dir):
    """`<procDir>/cursor.json` — how far the LLM has read each log (bytes)."""
    return os.path.join(proc_dir, "cursor.json")


def _read_new_output(proc_dir, max_bytes=PROC_TAIL_BYTES):
    """Return stdout/stderr appended since the stored cursor, then advance it.

    Only the delta since the previous run_command/run_wait call is returned so
    repeated waits do not resend (and re-bill) the same log content. If the
    delta exceeds `max_bytes`, only its tail is returned (with a marker).
    """
    cur = _read_json(_cursor_path(proc_dir))
    out = {}
    new_cur = {}
    for key, fn in (("stdout", "stdout.log"), ("stderr", "stderr.log")):
        path = os.path.join(proc_dir, fn)
        start = int(cur.get(key) or 0)
        try:
            size = os.path.getsize(path)
        except OSError:
            out[key] = ""
            new_cur[key] = start
            continue
        if size < start:
            start = 0  # log replaced/truncated — start over
        text = ""
        if size > start:
            try:
                with open(path, "rb") as f:
                    if size - start > max_bytes:
                        f.seek(size - max_bytes)
                        text = "…(truncated)\n" + f.read().decode(
                            "utf-8", errors="replace")
                    else:
                        f.seek(start)
                        text = f.read().decode("utf-8", errors="replace")
            except OSError:
                text = ""
        out[key] = text
        new_cur[key] = size
    try:
        with open(_cursor_path(proc_dir), "w", encoding="utf-8") as f:
            json.dump(new_cur, f)
    except OSError:
        pass  # best-effort: worst case some output is resent next time
    return out


def _spawn_detached(cmd_argv, cwd):
    """Spawn a fully detached process that survives this process exiting."""
    kwargs = {
        "cwd": cwd,
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
    }
    if os.name == "posix":
        kwargs["start_new_session"] = True
    else:
        kwargs["creationflags"] = _DETACHED_PROCESS | _CREATE_NEW_PROCESS_GROUP
    subprocess.Popen(cmd_argv, **kwargs)


# --- tools ---

@tool(
    "read_file",
    "Read a file's contents (text; only the beginning for large files).",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Path of the file to read"},
            "max_bytes": {
                "type": "integer",
                "description": "Max bytes to read (default 1MB)",
            },
        },
        "required": ["path"],
    },
)
def read_file(args):
    path = _resolve(_str_arg(args, "path"))
    limit = int(args.get("max_bytes") or MAX_READ_BYTES)
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        data = f.read(limit)
    return {
        "path": path,
        "size": size,
        "truncated": size > len(data),
        "content": data.decode("utf-8", errors="replace"),
    }


@tool(
    "list_directory",
    "List the direct entries of a directory.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Directory to list"},
        },
        "required": ["path"],
    },
)
def list_directory(args):
    path = _resolve(_str_arg(args, "path"))
    entries = []
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        entries.append({"name": name, "path": full, "is_dir": os.path.isdir(full)})
    entries.sort(key=lambda e: (not e["is_dir"], e["name"].lower()))
    return {"path": path, "entries": entries}


@tool(
    "create_directory",
    "Create a directory (including parents).",
    {
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Directory to create (parent folders are created too)",
            },
        },
        "required": ["path"],
    },
)
def create_directory(args):
    path = _resolve(_str_arg(args, "path"))
    os.makedirs(path, exist_ok=True)
    return {"path": path, "created": True}


@tool(
    "create_file",
    "Create a new file. By default existing files are not overwritten "
    "(set overwrite to allow it).",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Path of the file to create"},
            "content": {"type": "string", "description": "File content (default empty)"},
            "overwrite": {"type": "boolean", "description": "Allow overwriting an existing file"},
        },
        "required": ["path"],
    },
)
def create_file(args):
    path = _resolve(_str_arg(args, "path"))
    content = _str_arg(args, "content", required=False)
    overwrite = bool(args.get("overwrite", False))
    if os.path.exists(path) and not overwrite:
        raise ToolError("Already exists (set overwrite=true to replace): %s" % path)
    before = ""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            before = f.read()
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content)
    return {
        "path": path,
        "bytes": len(content.encode("utf-8")),
        "diff": _diff(before, content, path),
    }


@tool(
    "write_file",
    "Save (overwrite) an existing file.",
    {
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Path of the existing file to overwrite",
            },
            "content": {
                "type": "string",
                "description": "The complete new contents of the file (it replaces "
                               "everything). This writes text — do NOT use it on "
                               "zip-based documents such as .docx/.xlsx/.pptx.",
            },
        },
        "required": ["path", "content"],
    },
)
def write_file(args):
    path = _resolve(_str_arg(args, "path"))
    content = _str_arg(args, "content")
    before = ""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            before = f.read()
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content)
    return {
        "path": path,
        "bytes": len(content.encode("utf-8")),
        "diff": _diff(before, content, path),
    }


@tool(
    "edit_file",
    "Replace old_string with new_string in a file. To avoid mistakes, "
    "old_string must occur exactly once unless replace_all is set.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File to edit"},
            "old_string": {
                "type": "string",
                "description": "Exact text to find. Unless replace_all is true it "
                               "must occur exactly once — include surrounding lines "
                               "to make it unique.",
            },
            "new_string": {
                "type": "string",
                "description": "Text to put in its place (empty string deletes it)",
            },
            "replace_all": {
                "type": "boolean",
                "description": "Replace every occurrence instead of requiring a "
                               "single unique match (default false)",
            },
        },
        "required": ["path", "old_string", "new_string"],
    },
)
def edit_file(args):
    path = _resolve(_str_arg(args, "path"))
    old = _str_arg(args, "old_string")
    new = _str_arg(args, "new_string", required=False)
    replace_all = bool(args.get("replace_all", False))
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    count = text.count(old)
    if count == 0:
        raise ToolError("old_string not found.")
    if count > 1 and not replace_all:
        raise ToolError(
            "old_string occurs %d times. Use replace_all=true or a more "
            "specific string." % count
        )
    updated = text.replace(old, new) if replace_all else text.replace(old, new, 1)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(updated)
    return {
        "path": path,
        "replacements": count if replace_all else 1,
        "diff": _diff(text, updated, path),
    }


@tool(
    "delete_path",
    "Delete a file or directory (dangerous). Directories require recursive.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File or directory to delete"},
            "recursive": {
                "type": "boolean",
                "description": "Required (true) to delete a directory and "
                               "everything inside it",
            },
        },
        "required": ["path"],
    },
)
def delete_path(args):
    import shutil

    path = _resolve(_str_arg(args, "path"))
    if not os.path.exists(path):
        raise ToolError("Does not exist: %s" % path)
    if os.path.isdir(path):
        if not bool(args.get("recursive", False)):
            raise ToolError("Deleting a directory requires recursive=true.")
        shutil.rmtree(path)
    else:
        os.remove(path)
    return {"path": path, "deleted": True}


@tool(
    "move_path",
    "Move or rename a file/directory.",
    {
        "type": "object",
        "properties": {
            "src": {"type": "string", "description": "Existing file/directory to move"},
            "dst": {
                "type": "string",
                "description": "New path. Renaming is moving to a different name "
                               "in the same folder.",
            },
        },
        "required": ["src", "dst"],
    },
)
def move_path(args):
    import shutil

    src = _resolve(_str_arg(args, "src"))
    dst = _resolve(_str_arg(args, "dst"))
    if not os.path.exists(src):
        raise ToolError("Source does not exist: %s" % src)
    if os.path.exists(dst):
        raise ToolError("Destination already exists: %s" % dst)
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    shutil.move(src, dst)
    return {"src": src, "dst": dst, "moved": True}


def _wait_until_done(meta_path, seconds):
    """Poll meta.json for up to `seconds`; return the last meta read."""
    deadline = time.time() + max(1, seconds)
    meta = {}
    while time.time() < deadline:
        meta = _read_json(meta_path)
        if meta.get("status", "running") != "running":
            break
        time.sleep(0.2)
    return meta


@tool(
    "run_command",
    "Run a shell command in the background and return its output. The command "
    "keeps running even if it does not finish within the wait window: it is "
    "registered as a background process (with an id) whose stdout/stderr are "
    "logged. If it finishes within `timeout` seconds you get the full output "
    "and exit code; otherwise you get the output so far plus running=true and "
    "an id. It is NEVER killed on timeout - call run_wait with that id to keep "
    "waiting (it returns only NEW output), stop_command to terminate it, or "
    "leave it to the user (process viewer). If elevated is true, administrator "
    "privileges are required (requested if not available).",
    {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "Shell command line to run (as you would type it "
                               "in a terminal)",
            },
            "cwd": {"type": "string", "description": "Working directory (default: workspace)"},
            "timeout": {
                "type": "integer",
                "description": "Seconds to wait for completion before returning "
                "as still-running (default 30). The process is NOT killed on "
                "timeout.",
            },
            "elevated": {"type": "boolean", "description": "Whether admin privileges are required"},
        },
        "required": ["command"],
    },
)
def run_command(args):
    command = _str_arg(args, "command")
    if bool(args.get("elevated", False)) and not IS_ELEVATED:
        raise NeedsElevation("Administrator privileges are required to run: %s" % command)
    cwd = args.get("cwd") or WORKSPACE or None
    if cwd:
        cwd = _resolve(cwd)
    timeout = int(args.get("timeout") or 30)

    proc_id = uuid.uuid4().hex[:12]
    proc_dir = os.path.join(_proc_root(), proc_id)
    os.makedirs(proc_dir, exist_ok=True)
    # Pre-create logs so status/query works even before the runner writes.
    for fn in ("stdout.log", "stderr.log"):
        open(os.path.join(proc_dir, fn), "wb").close()
    with open(os.path.join(proc_dir, "spec.json"), "w", encoding="utf-8") as f:
        json.dump({"id": proc_id, "command": command, "cwd": cwd or ""}, f,
                  ensure_ascii=False)

    # Launch the detached wrapper; it outlives this tool-call process.
    _spawn_detached([sys.executable, "-u", PROC_RUNNER, proc_dir], cwd=proc_dir)

    # Wait up to `timeout` for completion (the process is never killed here).
    meta = _wait_until_done(os.path.join(proc_dir, "meta.json"), timeout)

    status = meta.get("status") or "running"
    running = status == "running"
    new = _read_new_output(proc_dir)
    result = {
        "id": proc_id,
        "pid": meta.get("pid"),
        "status": status,
        "running": running,
        "command": command,
        "cwd": cwd or "",
        "stdout": new["stdout"],
        "stderr": new["stderr"],
    }
    if running:
        result["note"] = (
            "Still running in the background after %ds (NOT killed). To keep "
            "waiting call run_wait with id '%s' - it returns only output "
            "produced since this call. If you decide to give up, call "
            "stop_command to terminate it, or leave it running and tell the "
            "user (the process viewer can inspect/stop it at any time)."
            % (timeout, proc_id)
        )
    else:
        result["exit_code"] = meta.get("exit_code")
    return result


@tool(
    "run_wait",
    "Keep waiting for a background command started by run_command. Waits up to "
    "`wait` seconds (default 30) for it to finish and returns its status plus "
    "ONLY the stdout/stderr produced since your previous run_command/run_wait "
    "call (incremental - safe to call repeatedly without bloating context). "
    "Call it again while you still expect the command to finish; if you give "
    "up, call stop_command or leave the process to the user.",
    {
        "type": "object",
        "properties": {
            "id": {"type": "string", "description": "Command id returned by run_command"},
            "wait": {
                "type": "integer",
                "description": "Seconds to wait before reporting back (default 30).",
            },
        },
        "required": ["id"],
    },
)
def run_wait(args):
    proc_dir = _find_proc_dir(args)
    wait = int(args.get("wait") or 30)
    meta = _wait_until_done(os.path.join(proc_dir, "meta.json"), wait)
    status = meta.get("status") or "running"
    running = status == "running"
    new = _read_new_output(proc_dir)
    result = {
        "id": meta.get("id") or os.path.basename(proc_dir),
        "pid": meta.get("pid"),
        "status": status,
        "running": running,
        "command": meta.get("command"),
        "stdout": new["stdout"],
        "stderr": new["stderr"],
        "incremental": True,
    }
    if running:
        result["note"] = (
            "Still running after waiting %ds more. stdout/stderr above contain "
            "only NEW output since your previous call. Call run_wait again to "
            "keep waiting, stop_command to terminate, or leave it to the user."
            % wait
        )
    else:
        result["exit_code"] = meta.get("exit_code")
    return result


def _find_proc_dir(args):
    """Locate a background command's procDir by id (preferred) or pid."""
    proc_id = args.get("id")
    pid = args.get("pid")
    root = _proc_root()
    if proc_id:
        cand = os.path.join(root, str(proc_id))
        if os.path.isdir(cand):
            return cand
    if pid is not None:
        try:
            for name in os.listdir(root):
                d = os.path.join(root, name)
                if _read_json(os.path.join(d, "meta.json")).get("pid") == int(pid):
                    return d
        except OSError:
            pass
    raise ToolError("No such background command (id/pid not found).")


@tool(
    "check_command",
    "Check the current status and output of a background command previously "
    "started by run_command, by its id (preferred) or pid. Returns status "
    "(running/exited/killed), exit code when finished, and the tail of "
    "stdout/stderr. This is a snapshot: unlike run_wait it does not wait and "
    "does not advance the incremental-output cursor.",
    {
        "type": "object",
        "properties": {
            "id": {
                "type": "string",
                "description": "Command id returned by run_command. Give either id or pid — id is preferred.",
            },
            "pid": {
                "type": "integer",
                "description": "Process id, if you do not have the command id.",
            },
        },
    },
)
def check_command(args):
    proc_dir = _find_proc_dir(args)
    meta = _read_json(os.path.join(proc_dir, "meta.json"))
    status = meta.get("status") or "running"
    return {
        "id": meta.get("id") or os.path.basename(proc_dir),
        "pid": meta.get("pid"),
        "status": status,
        "running": status == "running",
        "exit_code": meta.get("exit_code"),
        "command": meta.get("command"),
        "stdout": _tail_text(os.path.join(proc_dir, "stdout.log")),
        "stderr": _tail_text(os.path.join(proc_dir, "stderr.log")),
    }


@tool(
    "stop_command",
    "Terminate a background command (whole process tree) started by "
    "run_command. Use this only when you have decided to give up on the "
    "command (e.g. it hangs or is no longer needed) - never just because it "
    "is slow. Returns the final status and any remaining new output.",
    {
        "type": "object",
        "properties": {
            "id": {
                "type": "string",
                "description": "Command id returned by run_command. Give either id or pid — id is preferred.",
            },
            "pid": {
                "type": "integer",
                "description": "Process id, if you do not have the command id.",
            },
        },
    },
)
def stop_command(args):
    proc_dir = _find_proc_dir(args)
    meta_path = os.path.join(proc_dir, "meta.json")
    meta = _read_json(meta_path)
    status = meta.get("status") or "running"
    pid = meta.get("pid")
    stopped = False
    if status == "running" and pid:
        try:
            if os.name == "nt":
                # Kill the whole tree (the child may have grandchildren).
                subprocess.run(
                    ["taskkill", "/T", "/F", "/PID", str(pid)],
                    capture_output=True,
                )
            else:
                # The child is its session/group leader (pgid == pid).
                try:
                    os.killpg(pid, signal.SIGTERM)
                except (OSError, ProcessLookupError):
                    os.kill(pid, signal.SIGTERM)
            stopped = True
        except (OSError, ProcessLookupError, subprocess.SubprocessError):
            pass  # already gone / cannot signal — report the state below
        # proc_runner notices the child died and updates meta shortly.
        meta = _wait_until_done(meta_path, 5)
        status = meta.get("status") or "running"
    new = _read_new_output(proc_dir)
    return {
        "id": meta.get("id") or os.path.basename(proc_dir),
        "pid": pid,
        "status": status,
        "running": status == "running",
        "stopped": stopped,
        "exit_code": meta.get("exit_code"),
        "command": meta.get("command"),
        "stdout": new["stdout"],
        "stderr": new["stderr"],
    }


@tool(
    "search_text",
    "Search for text in a single file or recursively in a directory and return "
    "matching lines (path, line number, text). Use this to locate content in "
    "large files/projects without reading everything.",
    {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Text or regex to search for"},
            "path": {
                "type": "string",
                "description": "File or directory (default: project root)",
            },
            "regex": {"type": "boolean", "description": "Treat query as a regex"},
            "max_results": {"type": "integer", "description": "Max matches (default 200)"},
        },
        "required": ["query"],
    },
)
def search_text(args):
    query = _str_arg(args, "query")
    root = _resolve(args.get("path") or ".")
    use_regex = bool(args.get("regex", False))
    pattern = re.compile(query) if use_regex else None
    limit = int(args.get("max_results") or 200)
    skip_dirs = {".git", ".collabo", "node_modules", "build", ".dart_tool", "__pycache__"}

    results = []
    state = {"truncated": False}

    def scan(fp):
        try:
            if os.path.getsize(fp) > 2_000_000:
                return
            with open(fp, "rb") as f:
                if b"\x00" in f.read(1024):
                    return  # likely binary
            with open(fp, "r", encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f, 1):
                    hit = pattern.search(line) if use_regex else (query in line)
                    if hit:
                        if len(results) >= limit:
                            state["truncated"] = True
                            return
                        results.append(
                            {"path": fp, "line": i, "text": line.rstrip("\n")[:500]}
                        )
        except OSError:
            return

    if os.path.isfile(root):
        scan(root)
    else:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in skip_dirs]
            for fn in filenames:
                scan(os.path.join(dirpath, fn))
                if state["truncated"]:
                    break
            if state["truncated"]:
                break

    return {
        "query": query,
        "root": root,
        "matches": results,
        "truncated": state["truncated"],
    }


@tool(
    "read_lines",
    "Read a 1-based inclusive line range of a file (window into large files).",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File to read from"},
            "start_line": {
                "type": "integer",
                "description": "First line to read, 1-based and inclusive "
                               "(default: 1)",
            },
            "end_line": {
                "type": "integer",
                "description": "Last line to read, 1-based and inclusive "
                               "(default: end of file)",
            },
        },
        "required": ["path"],
    },
)
def read_lines(args):
    path = _resolve(_str_arg(args, "path"))
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    n = len(lines)
    start = max(1, int(args.get("start_line") or 1))
    end = min(n, int(args.get("end_line") or n))
    if start > end:
        raise ToolError("start_line is greater than end_line.")
    return {
        "path": path,
        "start_line": start,
        "end_line": end,
        "total_lines": n,
        "content": "\n".join(lines[start - 1:end]),
    }


@tool(
    "replace_lines",
    "Replace a 1-based inclusive line range with new content (line-based edit). "
    "Lets the editor change part of a large file without rewriting all of it. "
    "Empty content deletes the lines.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "File to edit"},
            "start_line": {
                "type": "integer",
                "description": "First line to replace, 1-based and inclusive "
                               "(use read_lines first to confirm the range)",
            },
            "end_line": {
                "type": "integer",
                "description": "Last line to replace, 1-based and inclusive",
            },
            "content": {"type": "string", "description": "Replacement text (may be empty)"},
        },
        "required": ["path", "start_line", "end_line", "content"],
    },
)
def replace_lines(args):
    path = _resolve(_str_arg(args, "path"))
    if "start_line" not in args or "end_line" not in args:
        raise ToolError("start_line and end_line are required.")
    content = _str_arg(args, "content", required=False)
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = text.split("\n")
    n = len(lines)
    start = int(args["start_line"])
    end = int(args["end_line"])
    if start < 1 or end < start or end > n:
        raise ToolError("Invalid line range (valid: 1..%d)." % n)
    repl = content.split("\n") if content != "" else []
    lines[start - 1:end] = repl
    new_text = "\n".join(lines)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(new_text)
    return {
        "path": path,
        "replaced_lines": end - start + 1,
        "new_line_count": len(lines),
        "diff": _diff(text, new_text, path),
    }


@tool(
    "request_elevation",
    "Request administrator privilege elevation for the next action "
    "(handled by the native side, e.g. via UAC).",
    {
        "type": "object",
        "properties": {
            "reason": {
                "type": "string",
                "description": "Why elevation is needed, in one sentence — it is "
                               "shown to the user, who decides whether to allow it",
            },
        },
        "required": ["reason"],
    },
)
def request_elevation(args):
    raise NeedsElevation(_str_arg(args, "reason"))


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
        result = entry["func"](args or {})
        return {"ok": True, "result": result}
    except NeedsElevation as e:
        return {"ok": False, "needs_elevation": True, "reason": e.reason}
    except ToolError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001 - surface any tool error to the LLM
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}


def main(argv):
    if len(argv) < 2 or argv[1] not in ("describe", "call"):
        sys.stderr.write("usage: collabo_tools.py {describe|call <tool>}\n")
        return 2

    if argv[1] == "describe":
        sys.stdout.write(json.dumps(_describe(), ensure_ascii=False))
        return 0

    # call
    if len(argv) < 3:
        sys.stdout.write(json.dumps({"ok": False, "error": "Tool name is required."}))
        return 0
    raw = sys.stdin.read()
    try:
        args = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        sys.stdout.write(json.dumps({"ok": False, "error": "Invalid argument JSON: %s" % e}))
        return 0
    sys.stdout.write(json.dumps(_call(argv[2], args), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
