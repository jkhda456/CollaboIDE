#!/usr/bin/env python3
"""Collabo IDE - web browsing tool module (fixed base module).

Lets the agent use the same browser tabs the user sees. The native side owns
the tabs and the WebView; this module owns everything about *search engines* -
which URL a query becomes, and how a results page is turned into a list.

Why the split: adding a search engine must not require touching Dart. The
native channel only knows primitive verbs (open a tab, go to a URL, hand me the
page, run this snippet). Everything engine-specific lives in ENGINES below, or
in a drop-in module under ``web_engines/`` next to this file.

Why a real browser and not an HTTP fetch: Google and friends block headless
automation, but this is the ordinary WebView the user is looking at - same
cookies, same consent state, same session. If a captcha appears, the user
solves it in that tab and the agent carries on.

Contract (identical to collabo_tools.py):
  describe:
    python collabo_web.py describe
      -> stdout(JSON): {"module","version","tools":[<OpenAI tool schema>...]}
  call:
    python collabo_web.py call <tool_name>
      <- stdin(JSON): tool arguments (object)
      -> stdout(JSON): {"ok":true,"result":...} | {"ok":false,"error":"..."}

Environment:
  COLLABO_WORKSPACE     : project root. The browser channel lives under
                          <workspace>/.collabo/browser/. Required.
  COLLABO_SEARCH_ENGINE : default engine name ("google" | "duckduckgo").
  COLLABO_LANG          : UI language hint passed to the search engine.
"""

import importlib.util
import json
import os
import re
import sys
import time
import uuid

MODULE_NAME = "collabo_web"
MODULE_VERSION = "0.1.0"

WORKSPACE = os.environ.get("COLLABO_WORKSPACE") or ""
LANG = (os.environ.get("COLLABO_LANG") or "en").split("-")[0].split("_")[0]

# Where the file channel lives, relative to the workspace.
CHANNEL_DIR = os.path.join(".collabo", "browser")

# How long to wait for the app to answer, per operation class. Page loads are
# slow and the native side already caps its own wait, so these are backstops
# for "the app is not running / not answering" rather than normal timing.
SLOW_OPS = {"open", "nav", "wait", "js", "download"}
SLOW_TIMEOUT = 180.0
FAST_TIMEOUT = 30.0
POLL_INTERVAL = 0.05

DEFAULT_RESULT_COUNT = 8
MAX_RESULT_COUNT = 25

# 내려받은 파일이 기본으로 떨어지는 곳(워크스페이스 안이라 파일 도구가 읽는다).
DOWNLOAD_DIR = os.path.join(".collabo", "downloads")

# 한 번에 받을 수 있는 크기(기본). 네이티브에도 같은 성격의 상한이 따로 있다.
DEFAULT_MAX_DOWNLOAD = 64 * 1024 * 1024


class ToolError(Exception):
    """An error to return to the user/LLM as a failed tool result."""


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


# --- search engines -------------------------------------------------------
#
# An engine is any object with:
#   NAME        str    - the value the `engine` argument takes
#   LABEL       str    - human name, used in messages
#   search_url(query, count, lang) -> str
#   extract_js(count)              -> str   JS body returning
#                                           [{title, url, snippet}, ...]
#
# extract_js runs against the *rendered* DOM, not raw HTML. That is the whole
# reason this works: a search page built by JavaScript looks like nothing in
# its HTML source, but the DOM the user is looking at has the results in it.

def _quote(s):
    from urllib.parse import quote_plus

    return quote_plus(s)


_CLEAN_JS = r"""
function clean(s){ return (s || '').replace(/\s+/g, ' ').trim(); }
"""


class GoogleEngine(object):
    NAME = "google"
    LABEL = "Google"

    def search_url(self, query, count, lang):
        return "https://www.google.com/search?q=%s&num=%d&hl=%s" % (
            _quote(query),
            min(max(count, 10), 30),
            lang or "en",
        )

    def extract_js(self, count):
        # Anchor on `a[href] > ... > h3`: Google's class names churn constantly
        # but a result has been "a link wrapping an h3" for many years.
        return _CLEAN_JS + r"""
var LIMIT = %d, out = [], seen = {};
var h3s = document.querySelectorAll('a[href^="http"] h3');
for (var i = 0; i < h3s.length && out.length < LIMIT; i++) {
  var h3 = h3s[i];
  var a = h3.closest ? h3.closest('a') : null;
  if (!a || !a.href) continue;
  var href = a.href;
  if (seen[href]) continue;
  if (/^https?:\/\/(www\.)?google\.[a-z.]+\//.test(href)) continue;
  seen[href] = 1;
  var title = clean(h3.innerText || h3.textContent);
  if (!title) continue;
  var block = (a.closest && a.closest('div[data-hveid]')) || a.parentElement;
  var snippet = '';
  if (block) {
    var lines = (block.innerText || '').split('\n'), parts = [];
    for (var j = 0; j < lines.length; j++) {
      var L = clean(lines[j]);
      // Drop the title echo and short chrome ("More results", breadcrumbs).
      if (!L || L === title || L.length < 20) continue;
      parts.push(L);
    }
    snippet = clean(parts.join(' ')).slice(0, 400);
  }
  out.push({title: title, url: href, snippet: snippet});
}
return out;
""" % (count,)


class DuckDuckGoEngine(object):
    NAME = "duckduckgo"
    LABEL = "DuckDuckGo"

    def search_url(self, query, count, lang):
        return "https://duckduckgo.com/?q=%s&ia=web" % (_quote(query),)

    def extract_js(self, count):
        return _CLEAN_JS + r"""
var LIMIT = %d, out = [], seen = {};
var nodes = document.querySelectorAll('article[data-testid="result"]');
if (!nodes.length) nodes = document.querySelectorAll('li[data-layout="organic"]');
if (!nodes.length) nodes = document.querySelectorAll('div.result');
for (var i = 0; i < nodes.length && out.length < LIMIT; i++) {
  var n = nodes[i];
  var a = n.querySelector('a[data-testid="result-title-a"]') ||
          n.querySelector('h2 a[href^="http"]') ||
          n.querySelector('a.result__a');
  if (!a || !a.href || seen[a.href]) continue;
  seen[a.href] = 1;
  var s = n.querySelector('[data-result="snippet"]') ||
          n.querySelector('[data-testid="result-snippet"]') ||
          n.querySelector('.result__snippet');
  var title = clean(a.innerText || a.textContent);
  if (!title) continue;
  out.push({
    title: title,
    url: a.href,
    snippet: clean(s ? (s.innerText || s.textContent) : '').slice(0, 400)
  });
}
return out;
""" % (count,)


ENGINES = {}


def _register_engine(engine):
    name = getattr(engine, "NAME", "")
    if name:
        ENGINES[name] = engine


def _load_engine_plugins():
    """Load drop-in engines from ``web_engines/*.py`` next to this module.

    A plugin is a plain module exposing NAME / LABEL / search_url / extract_js.
    A broken plugin is skipped rather than taking the whole module down - the
    built-in engines must keep working.
    """
    folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web_engines")
    if not os.path.isdir(folder):
        return
    for entry in sorted(os.listdir(folder)):
        if not entry.endswith(".py") or entry.startswith("_"):
            continue
        path = os.path.join(folder, entry)
        try:
            spec = importlib.util.spec_from_file_location(
                "collabo_engine_" + entry[:-3], path
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _register_engine(mod)
        except Exception:  # noqa: BLE001 - a bad plugin must not break search
            continue


_register_engine(GoogleEngine())
_register_engine(DuckDuckGoEngine())
_load_engine_plugins()

DEFAULT_ENGINE = os.environ.get("COLLABO_SEARCH_ENGINE") or "google"
if DEFAULT_ENGINE not in ENGINES:
    DEFAULT_ENGINE = "google"

# When the chosen engine returns nothing, try this one once before giving up.
# Blocking and layout churn hit the big engines first; DuckDuckGo's result
# markup is the steadiest of the two.
FALLBACK_ENGINE = "duckduckgo"


def _engine(name):
    key = (name or DEFAULT_ENGINE).strip().lower()
    eng = ENGINES.get(key)
    if eng is None:
        raise ToolError(
            "Unknown search engine %r. Available: %s"
            % (key, ", ".join(sorted(ENGINES)))
        )
    return eng


# --- native channel -------------------------------------------------------

def _channel_root():
    if not WORKSPACE:
        raise ToolError("No project is open, so the browser is not available.")
    return os.path.join(WORKSPACE, CHANNEL_DIR)


def _channel(op, args=None, timeout=None):
    """Send one request to the app's browser and wait for the answer.

    Writes ``req/<id>.json`` and polls for ``res/<id>.json``. Both files are
    written tmp-then-rename so neither side ever reads a half-written JSON.
    """
    root = _channel_root()
    req_dir = os.path.join(root, "req")
    res_dir = os.path.join(root, "res")
    try:
        os.makedirs(req_dir, exist_ok=True)
        os.makedirs(res_dir, exist_ok=True)
    except OSError as e:
        raise ToolError("Could not open the browser channel: %s" % e)

    rid = "%s%s" % (int(time.time() * 1000), uuid.uuid4().hex[:6])
    payload = {"id": rid, "op": op, "args": args or {}, "ts": time.time()}
    req_path = os.path.join(req_dir, rid + ".json")
    tmp_path = req_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.replace(tmp_path, req_path)

    limit = timeout if timeout is not None else (
        SLOW_TIMEOUT if op in SLOW_OPS else FAST_TIMEOUT
    )
    res_path = os.path.join(res_dir, rid + ".json")
    deadline = time.time() + limit
    while time.time() < deadline:
        if os.path.exists(res_path):
            try:
                with open(res_path, "r", encoding="utf-8") as f:
                    res = json.load(f)
            except (OSError, ValueError):
                # Caught it mid-rename on a slow filesystem; look again.
                time.sleep(POLL_INTERVAL)
                continue
            _quiet_remove(res_path)
            if res.get("ok"):
                return res.get("result")
            raise ToolError(str(res.get("error") or "browser error"))
        time.sleep(POLL_INTERVAL)

    _quiet_remove(req_path)
    raise ToolError(
        "The app's browser did not answer within %ds. Is Collabo IDE running "
        "with this project open?" % int(limit)
    )


def _quiet_remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


# --- argument helpers -----------------------------------------------------
#
# Models call tools sloppily: an object arrives as a JSON string, a number as
# "8", a tab id with stray whitespace. Take it, but say so in `hint` so the
# next call is cleaner (see the note, "be generous but leave a hint").

def _str_arg(args, key, default=""):
    v = args.get(key, default)
    if v is None:
        return default
    if not isinstance(v, str):
        v = str(v)
    return v.strip()


def _int_arg(args, key, default):
    v = args.get(key, default)
    if v is None or v == "":
        return default
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _count_arg(args):
    n = _int_arg(args, "count", DEFAULT_RESULT_COUNT)
    return max(1, min(n, MAX_RESULT_COUNT))


def _require_url(url):
    if not url:
        raise ToolError("'url' is required.")
    low = url.lower()
    if not (low.startswith("http://") or low.startswith("https://")):
        raise ToolError(
            "Only http:// and https:// URLs can be opened. To read a local "
            "file use read_file."
        )
    return url


# --- tools ----------------------------------------------------------------

@tool(
    "web_search",
    "Search the web and get a list of results (title, url, snippet). Runs the "
    "search in the app's browser tab that the user can also see, so sites that "
    "block automated browsers still work. Follow up with web_open on a result "
    "url to read the actual page - the snippets alone are rarely enough.",
    {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "What to search for.",
            },
            "count": {
                "type": "integer",
                "description": "How many results to return (default 8, max 25).",
            },
            "engine": {
                "type": "string",
                "description": "Search engine to use. Defaults to the one set "
                               "in settings.",
            },
            "tab": {
                "type": "string",
                "description": "Tab id to search in (from web_tabs). Omit to "
                               "reuse the active tab, or open one if there is "
                               "none. Reuse one tab for a line of research "
                               "instead of opening a new tab per search.",
            },
            "tab_name": {
                "type": "string",
                "description": "Optional label for the tab, so you and the "
                               "user can tell what it is for later.",
            },
        },
        "required": ["query"],
    },
)
def web_search(args):
    query = _str_arg(args, "query")
    if not query:
        raise ToolError("'query' is required.")
    count = _count_arg(args)
    name = _str_arg(args, "tab_name")
    tab = _str_arg(args, "tab")

    requested = _str_arg(args, "engine") or DEFAULT_ENGINE
    eng = _engine(requested)
    results, tab_info = _run_search(eng, query, count, tab, name)


    hint = ""
    # Zero results usually means the layout moved or the page is an interstitial
    # (consent, captcha). Try the steadier engine once before reporting nothing.
    if not results and eng.NAME != FALLBACK_ENGINE:
        alt = ENGINES.get(FALLBACK_ENGINE)
        if alt is not None:
            alt_results, alt_tab = _run_search(
                alt, query, count, tab_info.get("tab"), name
            )
            if alt_results:
                hint = (
                    "%s returned nothing (it may be showing a consent or "
                    "captcha page - the user can solve it in that tab). "
                    "These results are from %s." % (eng.LABEL, alt.LABEL)
                )
                return _search_result(alt, query, alt_results, alt_tab, hint)

    if not results:
        hint = (
            "No results could be read from the page. Open the Web Search tab to "
            "see what %s actually returned - it may be a consent or captcha "
            "page that needs a person." % eng.LABEL
        )
    return _search_result(eng, query, results, tab_info, hint)


def _run_search(eng, query, count, tab, name):
    url = eng.search_url(query, count, LANG)
    # 새 탭에만 질의로 이름을 붙인다. 기존 탭을 재사용할 때 자동으로 이름을 씌우면
    # 에이전트가 web_tabs(action="name") 로 붙여 둔 이름을 검색할 때마다 지워 버린다.
    label = name if tab else (name or ("search: " + query[:40]))
    tab_info = _channel("open", {
        "url": url,
        "tab": tab or "",
        "name": label,
    })
    value = _channel("js", {
        "tab": tab_info.get("tab"),
        "script": eng.extract_js(count),
    })
    raw = (value or {}).get("value")
    results = raw if isinstance(raw, list) else []
    clean = []
    for r in results:
        if not isinstance(r, dict):
            continue
        u = r.get("url") or ""
        if not u:
            continue
        clean.append({
            "title": r.get("title") or "",
            "url": u,
            "snippet": r.get("snippet") or "",
        })
    return clean[:count], tab_info


def _search_result(eng, query, results, tab_info, hint):
    out = {
        "engine": eng.NAME,
        "query": query,
        "count": len(results),
        "results": results,
        "tab": tab_info.get("tab"),
        "search_url": tab_info.get("url"),
    }
    if hint:
        out["hint"] = hint
    return out


@tool(
    "web_open",
    "Open a URL in a browser tab the user can also see, and return the page "
    "text. Use this to actually read a page found by web_search. The tab stays "
    "open, so follow-up reads and links from that page keep the same session "
    "(cookies, logins).",
    {
        "type": "object",
        "properties": {
            "url": {
                "type": "string",
                "description": "The http(s) URL to open.",
            },
            "tab": {
                "type": "string",
                "description": "Tab id to navigate (from web_tabs). Omit to "
                               "open a new tab. Prefer reusing one tab.",
            },
            "tab_name": {
                "type": "string",
                "description": "Optional label for the tab.",
            },
            "format": {
                "type": "string",
                "enum": ["text", "html", "links", "none"],
                "description": "What to return: visible text (default), raw "
                               "html, the page's links, or none to just "
                               "navigate.",
            },
            "max_chars": {
                "type": "integer",
                "description": "Cap on the returned content. Keep it small "
                               "unless you need the whole page.",
            },
        },
        "required": ["url"],
    },
)
def web_open(args):
    url = _require_url(_str_arg(args, "url"))
    fmt = _str_arg(args, "format", "text") or "text"
    tab_info = _channel("open", {
        "url": url,
        "tab": _str_arg(args, "tab"),
        "name": _str_arg(args, "tab_name"),
    })
    out = dict(tab_info)
    if fmt != "none":
        page = _read_page(tab_info.get("tab"), fmt, args)
        out.update(page)
    return out


@tool(
    "web_read",
    "Read the page that is currently open in a browser tab, without "
    "navigating. Use this after the user has browsed somewhere themselves, or "
    "to re-read a page after it finished loading.",
    {
        "type": "object",
        "properties": {
            "tab": {
                "type": "string",
                "description": "Tab id (from web_tabs). Omit for the tab the "
                               "user is currently looking at.",
            },
            "format": {
                "type": "string",
                "enum": ["text", "html", "links"],
                "description": "Visible text (default), raw html, or the "
                               "page's links.",
            },
            "max_chars": {
                "type": "integer",
                "description": "Cap on the returned content.",
            },
        },
        "required": [],
    },
)
def web_read(args):
    return _read_page(_str_arg(args, "tab"), _str_arg(args, "format", "text") or "text", args)


def _read_page(tab, fmt, args):
    if fmt not in ("text", "html", "links"):
        raise ToolError("'format' must be one of: text, html, links.")
    payload = {"tab": tab or "", "format": fmt}
    max_chars = _int_arg(args, "max_chars", 0)
    if max_chars > 0:
        payload["max_chars"] = max_chars
    return _channel("read", payload)


@tool(
    "web_tabs",
    "List the browser tabs, or act on one. The list is shared with the user - "
    "tabs they opened are here too, and they can see everything you open. Use "
    "action='name' to label a tab so it is obvious later what it was for.",
    {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["list", "close", "back", "forward", "reload",
                         "focus", "name"],
                "description": "What to do. Defaults to 'list'.",
            },
            "tab": {
                "type": "string",
                "description": "Tab id the action applies to. Omit for the "
                               "active tab.",
            },
            "name": {
                "type": "string",
                "description": "New label, for action='name'.",
            },
        },
        "required": [],
    },
)
def web_tabs(args):
    action = _str_arg(args, "action", "list") or "list"
    tab = _str_arg(args, "tab")
    if action == "list":
        return _channel("tabs")
    if action == "close":
        return _channel("close", {"tab": tab})
    if action == "focus":
        return _channel("focus", {"tab": tab})
    if action == "name":
        name = _str_arg(args, "name")
        if not name:
            raise ToolError("action='name' needs a 'name'.")
        return _channel("name", {"tab": tab, "name": name})
    if action in ("back", "forward", "reload"):
        return _channel("nav", {"tab": tab, "action": action})
    raise ToolError(
        "Unknown action %r. Use one of: list, close, back, forward, reload, "
        "focus, name." % action
    )


# --- download -------------------------------------------------------------
#
# 여기 있는 것은 전부 **정책**이다: 어느 링크를 말하는지 고르고, 어디에 저장할지
# 정하고, 교차 출처로 막혔을 때 어떻게 다시 시도할지. 네이티브는 "이 탭에서 이
# URL 을 받아 이 폴더에 써라" 만 안다(§12 층 가르기).


def _resolve_in_workspace(path):
    """워크스페이스 안의 실제 경로로 바꾼다(`collabo_tools._resolve` 와 같은 취지)."""
    if not WORKSPACE:
        raise ToolError("No project is open, so there is nowhere to save.")
    root = os.path.realpath(os.path.abspath(WORKSPACE))
    target = os.path.realpath(os.path.abspath(os.path.join(root, path)))
    if os.path.normcase(target) != os.path.normcase(root):
        try:
            common = os.path.commonpath(
                [os.path.normcase(target), os.path.normcase(root)])
        except ValueError:  # 윈도우에서 드라이브가 다르면 던진다
            raise ToolError("Path is outside the project: %s" % path)
        if common != os.path.normcase(root):
            raise ToolError("Path is outside the project: %s" % path)
    return target


_EXT_RE = re.compile(r"\.[A-Za-z0-9]{1,8}$")


def _looks_like_file(path):
    """마지막 조각에 확장자가 붙어 있으면 파일 경로로 읽는다."""
    return bool(_EXT_RE.search(os.path.basename(path.rstrip("/\\"))))


def _download_dest(path, name):
    """`path`/`name` 인자를 (폴더, 파일명 또는 None) 으로 푼다.

    ⚠️ **아직 없는 폴더를 파일로 읽지 않는다.** 처음에는 "있는 폴더인가" 로만
    갈랐는데, 그러면 `path="Downloads"` 처럼 **이제부터 만들 폴더**가 파일 경로로
    떨어진다 — 워크스페이스 루트에 `Downloads` 라는 **파일**이 생기고, 서버가 준
    진짜 파일명은 그 이름에 밀려 사라진다(2026-09-18 에 실제로 그랬다).

    그래서 판정은 셋 중 하나라도 맞으면 **폴더**다:
    있는 폴더 / 구분자로 끝남 / **마지막 조각에 확장자가 없음.**
    확장자가 붙은 것만 파일 경로로 본다(`out/report.pdf`). 점이 든 폴더 이름
    (`v1.2`)은 뒤에 `/` 를 붙이면 폴더로 읽힌다.

    [name] 을 따로 주면 **`path` 는 무조건 폴더다** — 둘 다 이름일 수는 없다.
    """
    if name:
        base = _resolve_in_workspace(path) if path else \
            _resolve_in_workspace(DOWNLOAD_DIR)
        return base, name
    if not path:
        return _resolve_in_workspace(DOWNLOAD_DIR), None
    target = _resolve_in_workspace(path)
    if (os.path.isdir(target)
            or path.endswith(("/", "\\"))
            or not _looks_like_file(path)):
        return target, None
    parent = os.path.dirname(target)
    return parent or _resolve_in_workspace(DOWNLOAD_DIR), os.path.basename(target)


def _origin_of(url):
    """`https://host:port` 만 남긴다(교차 출처 폴백에서 쓴다)."""
    try:
        parts = url.split("/", 3)
        if len(parts) < 3 or not parts[0].endswith(":"):
            return ""
        return "%s//%s" % (parts[0], parts[2])
    except (AttributeError, IndexError):
        return ""


def _pick_link(tab, wanted):
    """지금 페이지의 링크 중 [wanted] 와 맞는 것 하나를 고른다.

    사용자가 보고 있는 페이지에서 "저 링크" 를 가리키는 가장 자연스러운 방법이
    링크 글자다. 여러 개가 걸리면 **고르지 않고 후보를 돌려준다** — 엉뚱한 파일을
    받아 놓는 것보다 한 번 더 묻는 편이 싸다.
    """
    page = _channel("read", {"tab": tab or "", "format": "links"})
    links = page.get("links") or []
    if not links:
        raise ToolError(
            "That page has no links to choose from. Give 'url' instead, or "
            "open the page first with web_open."
        )
    needle = wanted.lower()
    exact, partial = [], []
    for item in links:
        text = (item.get("text") or "").strip()
        url = item.get("url") or ""
        name = item.get("file") or ""
        if text.lower() == needle or name.lower() == needle:
            exact.append(item)
        elif needle in text.lower() or needle in url.lower() or needle in name.lower():
            partial.append(item)
    hits = exact or partial
    if not hits:
        sample = ", ".join(
            repr((x.get("text") or x.get("url") or "")[:40]) for x in links[:8]
        )
        raise ToolError(
            "No link on this page matches %r. The page has %d links; the first "
            "few are: %s. Use web_read(format='links') to see them all."
            % (wanted, len(links), sample)
        )
    if len(hits) > 1:
        shown = [
            {"text": (x.get("text") or "")[:80], "url": x.get("url")}
            for x in hits[:8]
        ]
        raise ToolError(
            "%r matches %d links on this page, so I did not guess. Pass the "
            "exact 'url' of the one you want: %s"
            % (wanted, len(hits), json.dumps(shown, ensure_ascii=False))
        )
    return hits[0].get("url") or ""


def _absolute(url, base):
    """상대 URL 을 지금 페이지 기준으로 편다(흔한 `/files/x.zip` 형태)."""
    low = url.lower()
    if low.startswith("http://") or low.startswith("https://"):
        return url
    origin = _origin_of(base or "")
    if not origin:
        raise ToolError(
            "%r is not an absolute URL and there is no page open to resolve it "
            "against. Give the full https:// URL." % url
        )
    if url.startswith("//"):
        return "%s:%s" % (origin.split("//")[0], url)
    if url.startswith("/"):
        return origin + url
    base_path = (base or "").split("?")[0].split("#")[0]
    return base_path.rsplit("/", 1)[0] + "/" + url


# CORS 로 막혔을 때 나오는 문구들. 브라우저마다 말이 달라 넉넉하게 본다.
_CORS_HINTS = ("cors", "failed to fetch", "networkerror", "opaque",
               "access-control", "load failed")


@tool(
    "web_download",
    "Download a file through the browser, using the session of the page that "
    "is open - cookies, logins and consent are the user's, so this gets files "
    "that a plain HTTP request cannot. The file is saved inside the project "
    "(.collabo/downloads by default) and the path is returned, so the file "
    "tools can read it afterwards.\n"
    "Give 'url' for a known address, or 'link' to grab a link that is on the "
    "page right now - 'link' matches the link's visible text, its filename or "
    "its URL (use web_read(format='links') to see what is there). A relative "
    "url is resolved against the open page.\n"
    "This is for files, not pages: to read a web page use web_open.",
    {
        "type": "object",
        "properties": {
            "url": {
                "type": "string",
                "description": "Address of the file. May be relative to the "
                               "page that is open.",
            },
            "link": {
                "type": "string",
                "description": "Instead of 'url': part of the visible text, "
                               "filename or URL of a link on the current page.",
            },
            "tab": {
                "type": "string",
                "description": "Tab whose session to download with (from "
                               "web_tabs). Omit for the tab the user is "
                               "looking at.",
            },
            "path": {
                "type": "string",
                "description": "Folder to save it in, inside the project "
                               "(created if needed). Defaults to "
                               ".collabo/downloads. A path ending in a file "
                               "extension is taken as the full file path "
                               "instead - to be explicit, use 'name'.",
            },
            "name": {
                "type": "string",
                "description": "File name to save as. Omit to keep the name "
                               "the server gives (Content-Disposition, or the "
                               "last part of the URL). With 'name' set, 'path' "
                               "is always a folder.",
            },
            "max_bytes": {
                "type": "integer",
                "description": "Refuse anything larger (default 64MB).",
            },
        },
        "required": [],
    },
)
def web_download(args):
    tab = _str_arg(args, "tab")
    url = _str_arg(args, "url")
    link = _str_arg(args, "link")
    if not url and not link:
        raise ToolError("Give either 'url' or 'link'.")

    # 어느 탭의 세션으로 받을지부터 정한다. 링크를 고르는 것도 그 탭의 페이지다.
    tabs = (_channel("tabs") or {}).get("tabs") or []
    if not tabs:
        raise ToolError(
            "No browser tab is open. Open the page the file is on with "
            "web_open first — the download uses that page's session."
        )
    current = None
    for t in tabs:
        if (tab and t.get("tab") == tab) or (not tab and t.get("active")):
            current = t
            break
    if current is None:
        current = tabs[0]
    tab = current.get("tab") or tab
    page_url = current.get("url") or ""

    if link:
        url = _pick_link(tab, link)
    url = _absolute(url, page_url)
    _require_url(url)

    dest_dir, dest_name = _download_dest(
        _str_arg(args, "path"), _str_arg(args, "name"))
    payload = {"tab": tab, "url": url, "dir": dest_dir}
    if dest_name:
        payload["name"] = dest_name
    max_bytes = _int_arg(args, "max_bytes", DEFAULT_MAX_DOWNLOAD)
    if max_bytes > 0:
        payload["max_bytes"] = max_bytes

    try:
        out = _channel("download", payload)
        out["via"] = "page"
        # 어느 폴더로 정해졌는지 결과에 남긴다 — 폴더로 읽었는지 파일 경로로
        # 읽었는지가 눈에 보이면, 엉뚱한 곳에 떨어져도 바로 알아챈다.
        out["dir"] = dest_dir
        return out
    except ToolError as first:
        # 교차 출처가 CORS 로 막힌 경우에만 한 번 더 시도한다. 그 URL 자신의
        # 출처에서 받으면 동일 출처가 되어 풀린다 — 그 호스트의 쿠키도 그대로다.
        message = str(first)
        target_origin = _origin_of(url)
        same_origin = target_origin and target_origin == _origin_of(page_url)
        if same_origin or not any(h in message.lower() for h in _CORS_HINTS):
            raise
        helper = None
        try:
            helper = _channel("open", {
                "url": target_origin + "/",
                "name": "download",
            })
            payload["tab"] = helper.get("tab")
            out = _channel("download", payload)
            out["via"] = "origin"
            out["dir"] = dest_dir
            out["note"] = (
                "The page you were on could not fetch this (cross-origin), so "
                "it was downloaded from %s instead." % target_origin
            )
            return out
        except ToolError as second:
            raise ToolError(
                "%s Retrying from %s did not work either: %s"
                % (message, target_origin, second)
            )
        finally:
            # 열어 둔 보조 탭은 치운다 — 사용자 탭 목록을 어지럽히지 않는다.
            if helper and helper.get("tab"):
                try:
                    _channel("close", {"tab": helper["tab"]})
                except ToolError:
                    pass


# --- entry point ----------------------------------------------------------

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
        sys.stderr.write("usage: collabo_web.py {describe|call <tool>}\n")
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
        sys.stdout.write(json.dumps({"ok": False, "error": "Invalid argument JSON: %s" % e}))
        return 0
    sys.stdout.write(json.dumps(_call(argv[2], args), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
