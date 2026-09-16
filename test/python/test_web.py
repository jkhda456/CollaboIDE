"""`collabo_web.py` — 웹 검색 도구의 계약 테스트.

도구를 서브프로세스로 부르고(계약 그대로), **네이티브 쪽은 가짜로 세운다** —
`.collabo/browser/req` 를 지켜보다 `res` 에 답을 쓰는 스레드가 Dart 의
`BrowserChannel` 역할을 대신한다. 그래서 이 테스트가 실제로 검증하는 것은
파일 통로의 **양쪽 계약**이다: 파이썬이 어떤 op 를 어떤 순서로 보내는가,
그리고 응답을 어떻게 결과로 바꾸는가.

Flutter 가 없어도 돈다(표준 라이브러리만).
"""
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import Suite, WEB_TOOL  # noqa: E402


class FakeBrowser(object):
    """Dart `BrowserChannel` 의 대역. req 를 집어 res 를 쓴다.

    `handlers` 는 op → 함수(args) → result 다. 함수가 예외를 던지면 그 메시지를
    실패 응답으로 돌려준다(네이티브의 BrowserException 자리).
    """

    def __init__(self, workspace, handlers):
        self.root = os.path.join(workspace, ".collabo", "browser")
        self.req = os.path.join(self.root, "req")
        self.res = os.path.join(self.root, "res")
        os.makedirs(self.req, exist_ok=True)
        os.makedirs(self.res, exist_ok=True)
        self.handlers = handlers
        self.seen = []          # 처리한 (op, args) 순서 — 순서 검증용
        self._stop = threading.Event()
        self._thread = None

    def __enter__(self):
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=3)
        return False

    def _loop(self):
        while not self._stop.is_set():
            try:
                names = sorted(os.listdir(self.req))
            except OSError:
                names = []
            for name in names:
                if not name.endswith(".json"):
                    continue
                path = os.path.join(self.req, name)
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        req = json.load(f)
                except (OSError, ValueError):
                    continue
                self._answer(req)
                try:
                    os.remove(path)
                except OSError:
                    pass
            time.sleep(0.01)

    def _answer(self, req):
        op = req.get("op")
        args = req.get("args") or {}
        self.seen.append((op, args))
        handler = self.handlers.get(op)
        if handler is None:
            body = {"ok": False, "error": "unknown browser op: %s" % op}
        else:
            try:
                body = {"ok": True, "result": handler(args)}
            except Exception as e:  # noqa: BLE001 - 네이티브 오류 자리
                body = {"ok": False, "error": str(e)}
        dest = os.path.join(self.res, "%s.json" % req.get("id"))
        tmp = dest + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(dict(body, id=req.get("id")), f)
        os.replace(tmp, dest)

    def ops(self):
        return [op for op, _ in self.seen]

    def args_for(self, op):
        for o, a in self.seen:
            if o == op:
                return a
        return None


def _tab(tab="t1", url="https://example.com/", title="Example"):
    return {
        "tab": tab, "name": "", "title": title, "url": url,
        "status": "ready", "opened_by": "agent",
        "can_go_back": False, "can_go_forward": False,
    }


def _results(n):
    return [
        {"title": "R%d" % i, "url": "https://r%d.example/" % i,
         "snippet": "s%d" % i}
        for i in range(n)
    ]


def run():
    s = Suite("collabo_web — 웹 검색 도구")

    # --- describe: 도구 4종이 계약대로 나오는가 ---
    from harness import describe
    d = describe(WEB_TOOL)
    names = [t["function"]["name"] for t in d.get("tools", [])]
    s.equal("describe 가 도구 4종을 낸다",
            sorted(names), ["web_open", "web_read", "web_search", "web_tabs"])
    s.equal("모듈 이름", d.get("module"), "collabo_web")

    # --- web_search: open → js 순서, 결과 모양 ---
    handlers = {
        "open": lambda a: _tab(url=a.get("url", "")),
        "js": lambda a: {"value": _results(3)},
    }
    with FakeBrowser(s.ws, handlers) as fake:
        r = s.call_ok("web_search 가 성공한다", "web_search",
                      {"query": "flutter webview", "count": 3},
                      script=WEB_TOOL)
    if r is not None:
        s.equal("open 다음에 js 를 부른다", fake.ops(), ["open", "js"])
        s.equal("결과 개수", r.get("count"), 3)
        s.equal("엔진 이름이 실린다", r.get("engine"), "google")
        s.equal("결과 키", sorted(r["results"][0]), ["snippet", "title", "url"])
        opened = fake.args_for("open").get("url", "")
        s.check("기본 엔진은 구글 검색 URL 로 연다",
                opened.startswith("https://www.google.com/search?q="), opened)
        s.check("질의가 URL 인코딩돼 실린다", "flutter+webview" in opened, opened)

    # --- 탭 이름: 새 탭에만 붙이고, 재사용하는 탭의 이름은 안 건드린다 ---
    with FakeBrowser(s.ws, handlers) as fake:
        s.call_ok("새 탭 검색", "web_search", {"query": "dart isolate"},
                  script=WEB_TOOL)
    s.equal("새 탭에는 질의로 이름을 붙인다",
            fake.args_for("open").get("name"), "search: dart isolate")

    with FakeBrowser(s.ws, handlers) as fake:
        s.call_ok("기존 탭 재사용", "web_search",
                  {"query": "dart isolate", "tab": "t1"}, script=WEB_TOOL)
    # 에이전트가 web_tabs(action='name') 로 붙여 둔 이름을 검색이 덮으면 안 된다.
    s.equal("재사용 탭의 이름은 그대로 둔다",
            fake.args_for("open").get("name"), "")

    with FakeBrowser(s.ws, handlers) as fake:
        s.call_ok("이름을 명시하면 재사용 탭도 바꾼다", "web_search",
                  {"query": "x", "tab": "t1", "tab_name": "조사용"},
                  script=WEB_TOOL)
    s.equal("명시한 이름은 반영한다",
            fake.args_for("open").get("name"), "조사용")

    # --- 엔진 선택이 URL 을 바꾼다 ---
    with FakeBrowser(s.ws, handlers) as fake:
        s.call_ok("engine=duckduckgo 로 검색한다", "web_search",
                  {"query": "dart", "engine": "duckduckgo"}, script=WEB_TOOL)
    opened = fake.args_for("open").get("url", "")
    s.check("덕덕고 URL 로 연다", opened.startswith("https://duckduckgo.com/?q="), opened)

    # --- 설정(COLLABO_SEARCH_ENGINE)이 기본 엔진을 바꾼다 ---
    with FakeBrowser(s.ws, handlers) as fake:
        r = s.call_ok("환경변수로 기본 엔진을 바꾼다", "web_search", {"query": "x"},
                      script=WEB_TOOL,
                      env_extra={"COLLABO_SEARCH_ENGINE": "duckduckgo"})
    if r is not None:
        s.equal("기본 엔진이 덕덕고", r.get("engine"), "duckduckgo")

    # --- 0건이면 폴백 엔진으로 한 번 더 ---
    state = {"calls": 0}

    def js_empty_then_full(a):
        state["calls"] += 1
        return {"value": [] if state["calls"] == 1 else _results(2)}

    with FakeBrowser(s.ws, {"open": lambda a: _tab(url=a.get("url", "")),
                            "js": js_empty_then_full}) as fake:
        r = s.call_ok("구글이 0건이면 덕덕고로 한 번 더", "web_search",
                      {"query": "blocked"}, script=WEB_TOOL)
    if r is not None:
        s.equal("폴백 엔진의 결과를 준다", r.get("engine"), "duckduckgo")
        s.equal("폴백 결과 개수", r.get("count"), 2)
        s.check("왜 바뀌었는지 hint 를 붙인다", bool(r.get("hint")), r)
        s.equal("open 과 js 를 두 번씩", fake.ops(),
                ["open", "js", "open", "js"])

    # --- 양쪽 다 0건이면 사람에게 넘기는 안내 ---
    with FakeBrowser(s.ws, {"open": lambda a: _tab(),
                            "js": lambda a: {"value": []}}):
        r = s.call_ok("전부 0건이어도 실패가 아니다", "web_search",
                      {"query": "nothing"}, script=WEB_TOOL)
    if r is not None:
        s.equal("결과가 비어 있다", r.get("count"), 0)
        s.check("안내를 남긴다", bool(r.get("hint")), r)

    # --- web_open: format=none 이면 read 를 안 부른다 ---
    with FakeBrowser(s.ws, {"open": lambda a: _tab(url=a.get("url", "")),
                            "read": lambda a: {"content": "hi"}}) as fake:
        s.call_ok("web_open(format=none)", "web_open",
                  {"url": "https://example.com/", "format": "none"},
                  script=WEB_TOOL)
    s.equal("읽지 않고 열기만 한다", fake.ops(), ["open"])

    # --- web_open 기본은 본문까지 읽는다 ---
    with FakeBrowser(s.ws, {"open": lambda a: _tab(url=a.get("url", "")),
                            "read": lambda a: {"content": "page text",
                                               "truncated": False,
                                               "format": a.get("format")}}) as fake:
        r = s.call_ok("web_open 기본", "web_open",
                      {"url": "https://example.com/"}, script=WEB_TOOL)
    if r is not None:
        s.equal("open 뒤 read", fake.ops(), ["open", "read"])
        s.equal("본문이 실린다", r.get("content"), "page text")
        s.equal("기본 형태는 text", fake.args_for("read").get("format"), "text")

    # --- web_read: 탭을 안 주면 빈 문자열로 넘겨 활성 탭에 맡긴다 ---
    with FakeBrowser(s.ws, {"read": lambda a: {"content": "x",
                                               "tab": a.get("tab")}}) as fake:
        s.call_ok("web_read(탭 생략)", "web_read", {}, script=WEB_TOOL)
    s.equal("탭은 비워서 보낸다", fake.args_for("read").get("tab"), "")

    # --- web_tabs 의 action 분기 ---
    with FakeBrowser(s.ws, {"tabs": lambda a: {"tabs": [_tab()]}}) as fake:
        r = s.call_ok("web_tabs 기본은 목록", "web_tabs", {}, script=WEB_TOOL)
    s.equal("tabs op 를 부른다", fake.ops(), ["tabs"])
    if r is not None:
        s.equal("탭 목록이 온다", len(r.get("tabs", [])), 1)

    with FakeBrowser(s.ws, {"nav": lambda a: _tab()}) as fake:
        s.call_ok("web_tabs(action=back)", "web_tabs",
                  {"action": "back", "tab": "t1"}, script=WEB_TOOL)
    s.equal("nav op 로 간다", fake.args_for("nav"),
            {"tab": "t1", "action": "back"})

    with FakeBrowser(s.ws, {"name": lambda a: _tab()}) as fake:
        s.call_ok("web_tabs(action=name)", "web_tabs",
                  {"action": "name", "tab": "t1", "name": "조사용"},
                  script=WEB_TOOL)
    s.equal("이름을 그대로 넘긴다", fake.args_for("name").get("name"), "조사용")

    # --- 인자 검증: 통로를 타기 전에 막는 것들 ---
    err = s.call_fails("file:// 은 열지 않는다", "web_open",
                       {"url": "file:///etc/passwd"}, script=WEB_TOOL)
    s.check("이유에 read_file 을 안내한다", "read_file" in err, err)

    s.call_fails("빈 query 는 거부", "web_search", {"query": "  "}, script=WEB_TOOL)
    err = s.call_fails("모르는 엔진은 거부", "web_search",
                       {"query": "x", "engine": "altavista"}, script=WEB_TOOL)
    s.check("쓸 수 있는 엔진을 알려 준다", "duckduckgo" in err, err)
    s.call_fails("모르는 action 은 거부", "web_tabs",
                 {"action": "teleport"}, script=WEB_TOOL)
    s.call_fails("format 은 셋 중 하나", "web_read",
                 {"format": "pdf"}, script=WEB_TOOL)

    # --- 네이티브가 오류를 주면 도구 오류가 된다 ---
    def boom(a):
        raise RuntimeError("no such tab: t9")

    with FakeBrowser(s.ws, {"read": boom}):
        err = s.call_fails("네이티브 오류가 그대로 올라온다", "web_read",
                           {"tab": "t9"}, script=WEB_TOOL)
    s.check("메시지가 보존된다", "no such tab" in err, err)

    # --- 요청/응답 파일을 남기지 않는다 ---
    leftover = []
    for sub in ("req", "res"):
        d2 = os.path.join(s.ws, ".collabo", "browser", sub)
        if os.path.isdir(d2):
            leftover += [f for f in os.listdir(d2) if f.endswith(".json")]
    s.equal("통로에 찌꺼기를 안 남긴다", leftover, [])

    return s.report()


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
