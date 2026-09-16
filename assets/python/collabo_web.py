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
SLOW_OPS = {"open", "nav", "wait", "js"}
SLOW_TIMEOUT = 180.0
FAST_TIMEOUT = 30.0
POLL_INTERVAL = 0.05

DEFAULT_RESULT_COUNT = 8
MAX_RESULT_COUNT = 25


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
