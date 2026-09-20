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

from harness import Suite, WEB_TOOL, call  # noqa: E402


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
    s.equal("describe 가 도구 5종을 낸다",
            sorted(names),
            ["web_download", "web_open", "web_read", "web_search", "web_tabs"])
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

    # === web_download ======================================================
    #
    # 여기서 잠그는 것은 **정책**이다: 어느 탭으로 받는지, 링크를 어떻게 고르는지,
    # 어디에 저장하라고 말하는지, 교차 출처로 막혔을 때 어떻게 다시 시도하는지.
    # 실제로 바이트를 가져오는 일은 네이티브(Dart)가 하고 그쪽 테스트가 잠근다.

    def dl_handlers(saved=None, fail_with=None, links=None):
        """다운로드용 가짜 네이티브 한 벌."""
        state = {"downloads": saved if saved is not None else []}

        def on_download(a):
            state["downloads"].append(a)
            if fail_with:
                raise RuntimeError(fail_with)
            return {
                "tab": a.get("tab"), "url": a.get("url"),
                "path": os.path.join(a.get("dir", ""), a.get("name") or "f.bin"),
                "name": a.get("name") or "f.bin",
                "bytes": 12, "mime": "application/zip", "status": 200,
            }

        return {
            "tabs": lambda a: {"tabs": [dict(_tab(url="https://site.test/page"),
                                             active=True)]},
            "read": lambda a: {"tab": "t1", "url": "https://site.test/page",
                               "format": "links",
                               "links": links if links is not None else []},
            "open": lambda a: _tab(tab="t9", url=a.get("url", "")),
            "close": lambda a: {"closed": a.get("tab")},
            "download": on_download,
        }, state

    # --- 기본 경로: 활성 탭으로 받고 .collabo/downloads 에 저장한다 ---
    handlers_dl, state = dl_handlers()
    with FakeBrowser(s.ws, handlers_dl) as fake:
        r = s.call_ok("web_download 가 성공한다", "web_download",
                      {"url": "https://site.test/a.zip"}, script=WEB_TOOL)
    if r is not None:
        s.equal("먼저 탭을 확인하고 받는다", fake.ops(), ["tabs", "download"])
        sent = fake.args_for("download")
        s.equal("활성 탭의 세션으로 받는다", sent.get("tab"), "t1")
        s.equal("URL 을 그대로 넘긴다", sent.get("url"), "https://site.test/a.zip")
        s.check("기본 저장 폴더는 .collabo/downloads",
                sent.get("dir", "").replace("\\", "/").endswith(
                    ".collabo/downloads"), sent.get("dir"))
        s.check("기본 상한이 실린다", sent.get("max_bytes", 0) > 0, sent)
        s.equal("어느 경로로 받았는지 알려 준다", r.get("via"), "page")

    # --- 탭이 하나도 없으면 안내하고 멈춘다 ---
    with FakeBrowser(s.ws, {"tabs": lambda a: {"tabs": []}}):
        err = s.call_fails("탭이 없으면 거절한다", "web_download",
                           {"url": "https://x.test/a.zip"}, script=WEB_TOOL)
    s.check("web_open 을 먼저 하라고 말한다", "web_open" in err, err)

    # --- 상대 URL 은 열려 있는 페이지 기준으로 편다 ---
    handlers_dl, _ = dl_handlers()
    with FakeBrowser(s.ws, handlers_dl) as fake:
        s.call_ok("상대 경로도 받는다", "web_download",
                  {"url": "/files/b.zip"}, script=WEB_TOOL)
    s.equal("페이지 출처로 절대 URL 을 만든다",
            fake.args_for("download").get("url"), "https://site.test/files/b.zip")

    # --- link: 지금 페이지의 링크를 글자로 고른다 ---
    page_links = [
        {"text": "소개", "url": "https://site.test/about"},
        {"text": "설치 파일 내려받기", "url": "https://site.test/dl/setup.exe",
         "file": "setup.exe", "ext": "exe", "download": True},
    ]
    handlers_dl, _ = dl_handlers(links=page_links)
    with FakeBrowser(s.ws, handlers_dl) as fake:
        r = s.call_ok("링크 글자로 고른다", "web_download",
                      {"link": "내려받기"}, script=WEB_TOOL)
    if r is not None:
        s.equal("링크를 보려고 read 를 먼저 부른다",
                fake.ops(), ["tabs", "read", "download"])
        s.equal("고른 링크의 URL 로 받는다",
                fake.args_for("download").get("url"),
                "https://site.test/dl/setup.exe")

    handlers_dl, _ = dl_handlers(links=page_links)
    with FakeBrowser(s.ws, handlers_dl):
        r = s.call_ok("파일명으로도 고른다", "web_download",
                      {"link": "setup.exe"}, script=WEB_TOOL)

    # --- 여러 개가 걸리면 **고르지 않는다** (엉뚱한 파일을 받는 것보다 낫다) ---
    ambiguous = [
        {"text": "리눅스 내려받기", "url": "https://site.test/a.tar.gz"},
        {"text": "윈도우 내려받기", "url": "https://site.test/a.zip"},
    ]
    handlers_dl, _ = dl_handlers(links=ambiguous)
    with FakeBrowser(s.ws, handlers_dl):
        err = s.call_fails("여러 링크가 걸리면 묻는다", "web_download",
                           {"link": "내려받기"}, script=WEB_TOOL)
    s.check("후보를 보여 준다", "a.zip" in err and "a.tar.gz" in err, err)

    handlers_dl, _ = dl_handlers(links=page_links)
    with FakeBrowser(s.ws, handlers_dl):
        err = s.call_fails("맞는 링크가 없으면 있는 것을 알려 준다", "web_download",
                           {"link": "없는링크"}, script=WEB_TOOL)
    s.check("몇 개인지와 예시를 준다", "2 links" in err or "links" in err, err)

    # --- 저장 위치 지정 ---
    #
    # ★ 여기가 한 번 크게 어긋났던 자리다(2026-09-18). "있는 폴더인가" 로만
    # 갈랐더니 **이제부터 만들 폴더**가 파일 경로로 떨어져, 워크스페이스 루트에
    # 그 이름의 파일이 생기고 서버가 준 진짜 파일명이 사라졌다.

    def dest_of(path=None, name=None):
        """주어진 인자로 네이티브에 어떤 dir/name 이 나가는지 본다."""
        handlers, _ = dl_handlers()
        req = {"url": "https://site.test/a.zip"}
        if path is not None:
            req["path"] = path
        if name is not None:
            req["name"] = name
        with FakeBrowser(s.ws, handlers) as fk:
            call("web_download", req, s.ws, script=WEB_TOOL)
        sent = fk.args_for("download") or {}
        return sent.get("dir", "").replace("\\", "/"), sent.get("name")

    d, n = dest_of(path="Downloads")
    s.check("★ 없는 폴더 이름도 폴더로 읽는다", d.endswith("/Downloads"), d)
    s.equal("★ 폴더 이름을 파일명으로 쓰지 않는다", n, None)

    d, n = dest_of(path="assets/")
    s.check("구분자로 끝나면 폴더", d.endswith("/assets"), d)
    s.equal("이름은 서버가 준 것을 쓴다", n, None)

    d, n = dest_of(path="assets/nested/deep")
    s.check("여러 겹의 새 폴더도 폴더", d.endswith("/assets/nested/deep"), d)
    s.equal("이름 없음", n, None)

    d, n = dest_of(path="assets/my.zip")
    s.check("확장자가 붙으면 파일 경로", d.endswith("/assets"), d)
    s.equal("그 이름으로 저장한다", n, "my.zip")

    # 점이 든 폴더 이름은 구분자로 구분한다(규칙을 설명 가능하게 유지).
    d, n = dest_of(path="v1.2/")
    s.check("점이 든 폴더도 / 를 붙이면 폴더", d.endswith("/v1.2"), d)
    s.equal("이름 없음", n, None)

    # name 을 주면 path 는 무조건 폴더다 — 둘 다 이름일 수는 없다.
    d, n = dest_of(path="Downloads", name="report.pdf")
    s.check("name 이 있으면 path 는 폴더", d.endswith("/Downloads"), d)
    s.equal("지정한 이름으로 저장한다", n, "report.pdf")

    d, n = dest_of(path="out/x.zip", name="real.zip")
    s.check("파일처럼 생긴 path 도 name 이 있으면 폴더", d.endswith("/out/x.zip"), d)
    s.equal("이름은 name 이 이긴다", n, "real.zip")

    d, n = dest_of(name="only-name.bin")
    s.check("path 없이 name 만 주면 기본 폴더",
            d.endswith(".collabo/downloads"), d)
    s.equal("이름은 그대로", n, "only-name.bin")

    # 이미 있는 폴더는 확장자가 있어도 폴더다.
    os.makedirs(os.path.join(s.ws, "real.dir"), exist_ok=True)
    d, n = dest_of(path="real.dir")
    s.check("있는 폴더는 확장자가 있어도 폴더", d.endswith("/real.dir"), d)
    s.equal("이름 없음", n, None)

    # 결과에 어느 폴더로 갔는지 실린다(엉뚱한 곳에 떨어지면 바로 보이게).
    handlers_dl, _ = dl_handlers()
    with FakeBrowser(s.ws, handlers_dl):
        r = s.call_ok("결과에 dir 이 실린다", "web_download",
                      {"url": "https://site.test/a.zip", "path": "Downloads"},
                      script=WEB_TOOL)
    if r is not None:
        s.check("어느 폴더에 받았는지 알려 준다",
                (r.get("dir") or "").replace("\\", "/").endswith("/Downloads"),
                r.get("dir"))

    # --- 워크스페이스 밖에는 못 쓴다 ---
    handlers_dl, _ = dl_handlers()
    with FakeBrowser(s.ws, handlers_dl):
        err = s.call_fails("프로젝트 밖 저장은 거절한다", "web_download",
                           {"url": "https://site.test/a.zip",
                            "path": "../escape.zip"}, script=WEB_TOOL)
    s.check("밖이라고 말해 준다", "outside" in err.lower(), err)

    # --- 인자가 아예 없으면 ---
    handlers_dl, _ = dl_handlers()
    with FakeBrowser(s.ws, handlers_dl):
        err = s.call_fails("url 도 link 도 없으면 거절한다", "web_download", {},
                           script=WEB_TOOL)
    s.check("무엇을 달라는지 말한다", "url" in err and "link" in err, err)

    # --- 교차 출처 CORS 폴백: 그 URL 의 출처에서 한 번 더 ---
    attempts = {"n": 0}

    def flaky_download(a):
        attempts["n"] += 1
        if attempts["n"] == 1:
            raise RuntimeError(
                "the page could not fetch it: TypeError: Failed to fetch")
        return {"tab": a.get("tab"), "url": a.get("url"),
                "path": os.path.join(a.get("dir", ""), "a.zip"),
                "name": "a.zip", "bytes": 5, "mime": "application/zip",
                "status": 200}

    cors_handlers = {
        "tabs": lambda a: {"tabs": [dict(_tab(url="https://site.test/page"),
                                         active=True)]},
        "open": lambda a: _tab(tab="t9", url=a.get("url", "")),
        "close": lambda a: {"closed": a.get("tab")},
        "download": flaky_download,
    }
    with FakeBrowser(s.ws, cors_handlers) as fake:
        r = s.call_ok("CORS 로 막히면 그 출처에서 다시 받는다", "web_download",
                      {"url": "https://cdn.other.test/a.zip"}, script=WEB_TOOL)
    if r is not None:
        s.equal("탭 확인 → 실패 → 보조 탭 → 재시도 → 정리",
                fake.ops(), ["tabs", "download", "open", "download", "close"])
        opened = [a for o, a in fake.seen if o == "open"][0]
        s.equal("그 URL 의 출처를 연다", opened.get("url"),
                "https://cdn.other.test/")
        retried = [a for o, a in fake.seen if o == "download"][1]
        s.equal("보조 탭으로 다시 받는다", retried.get("tab"), "t9")
        s.equal("어느 경로였는지 알려 준다", r.get("via"), "origin")
        s.check("왜 그랬는지도 적는다", "cross-origin" in (r.get("note") or ""), r)

    # --- 같은 출처인데 실패한 것은 다시 시도하지 않는다 (의미가 없다) ---
    attempts["n"] = 0
    with FakeBrowser(s.ws, cors_handlers) as fake:
        s.call_fails("같은 출처 실패는 재시도하지 않는다", "web_download",
                     {"url": "https://site.test/a.zip"}, script=WEB_TOOL)
    s.equal("보조 탭을 열지 않는다", fake.ops(), ["tabs", "download"])

    # --- CORS 가 아닌 실패(404 등)도 재시도하지 않는다 ---
    handlers_dl, _ = dl_handlers(fail_with="the server answered 404")
    with FakeBrowser(s.ws, handlers_dl) as fake:
        err = s.call_fails("404 는 재시도하지 않는다", "web_download",
                           {"url": "https://cdn.other.test/a.zip"},
                           script=WEB_TOOL)
    s.equal("한 번만 시도한다", fake.ops(), ["tabs", "download"])
    s.check("서버 응답을 그대로 올린다", "404" in err, err)

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
