"""Python 도구 테스트 공용 도우미.

도구를 **실제 계약 그대로** 부른다 — 서브프로세스로 띄우고, 인자는 stdin JSON,
`COLLABO_WORKSPACE` 와 cwd 를 프로젝트 폴더로 잡는다(`ToolRunner.call` 과 동일).
모듈을 import 해서 함수를 직접 부르면 계약이 깨져도 모르므로 그렇게 하지 않는다.

의존성 없음(표준 라이브러리만). 실행:

    python3 test/python/run_all.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS_DIR = os.path.join(REPO, "assets", "python")
DOCS_TOOL = os.path.join(TOOLS_DIR, "collabo_docs.py")
BASE_TOOL = os.path.join(TOOLS_DIR, "collabo_tools.py")
WEB_TOOL = os.path.join(TOOLS_DIR, "collabo_web.py")
TERM_TOOL = os.path.join(TOOLS_DIR, "collabo_term.py")


def call(tool, args, workspace, script=DOCS_TOOL, env_extra=None):
    """도구 하나를 부르고 `{"ok":…}` 응답을 그대로 돌려준다."""
    env = dict(os.environ)
    env["COLLABO_WORKSPACE"] = workspace
    env["PYTHONIOENCODING"] = "utf-8"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [sys.executable, script, "call", tool],
        input=json.dumps(args),
        capture_output=True,
        text=True,
        encoding="utf-8",
        env=env,
        cwd=workspace,          # 상대 경로가 프로젝트 기준으로 풀리도록
    )
    if not (proc.stdout or "").strip():
        return {"ok": False, "error": "no stdout (rc=%s) %s"
                                      % (proc.returncode, (proc.stderr or "").strip())}
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return {"ok": False, "error": "bad json: %s" % proc.stdout[:200]}


def describe(script=DOCS_TOOL):
    proc = subprocess.run(
        [sys.executable, script, "describe"],
        capture_output=True, text=True, encoding="utf-8",
    )
    return json.loads(proc.stdout)


class Suite(object):
    """작은 테스트 러너. 통과/실패를 세고 마지막에 요약한다."""

    def __init__(self, title):
        self.title = title
        self.passed = 0
        self.failures = []
        self._ws = None
        print("\n=== %s ===" % title)

    # --- 워크스페이스 ---
    @property
    def ws(self):
        if self._ws is None:
            self._ws = tempfile.mkdtemp(prefix="collabo_test_")
        return self._ws

    def cleanup(self):
        if self._ws and os.path.isdir(self._ws):
            shutil.rmtree(self._ws, ignore_errors=True)
        self._ws = None

    # --- 어서션 ---
    def check(self, title, condition, detail=""):
        if condition:
            self.passed += 1
            print("  ok    %s" % title)
        else:
            self.failures.append((title, detail))
            print("  FAIL  %s   %s" % (title, detail))
        return bool(condition)

    def equal(self, title, got, want):
        return self.check(title, got == want, "got %r, want %r" % (got, want))

    def call_ok(self, title, tool, args, script=DOCS_TOOL, env_extra=None):
        """호출이 성공하기를 기대한다. 성공하면 result 를, 아니면 None 을 준다."""
        out = call(tool, args, self.ws, script=script, env_extra=env_extra)
        if not self.check(title, out.get("ok"), out.get("error", "")):
            return None
        return out.get("result") or {}

    def call_fails(self, title, tool, args, script=DOCS_TOOL, env_extra=None):
        out = call(tool, args, self.ws, script=script, env_extra=env_extra)
        self.check(title, not out.get("ok"), "성공해 버렸다: %r" % (out.get("result"),))
        return out.get("error") or ""

    def report(self):
        self.cleanup()
        if self.failures:
            print("  -- %s: 통과 %d, 실패 %d" % (self.title, self.passed, len(self.failures)))
        else:
            print("  -- %s: %d개 전부 통과" % (self.title, self.passed))
        return len(self.failures)
