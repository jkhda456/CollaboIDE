"""터미널 세션 도구(`collabo_term.py`) 테스트 — 계약 그대로 서브프로세스로.

여기서 잠그는 것은 **두 쪽이 맞물리는 자리**다. 파이썬 도구가 쓰는 파일과
Dart(`BackgroundProcessRegistry`)가 읽는 파일이 같은 것들이라, 한쪽만 바뀌면
조용히 어긋난다(§note 13 "두 곳을 같이 고쳐야 하는 지점"). 그래서 meta.json 의
키 이름까지 확인한다.

PTY 가 없는 환경(이 VM 의 Windows ARM64 가 그렇다)에서도 **전부 통과해야 한다** —
폴백이 제 몫을 하는지가 곧 이 테스트의 절반이다. 그래서 대화형 프로그램을
요구하는 검사는 넣지 않고, 줄 단위 동작만 본다.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from harness import Suite, TERM_TOOL, call, describe  # noqa: E402

IS_WINDOWS = os.name == "nt"

# 셸에 무관하게 같은 문자열을 찍는 명령.
ECHO = "echo COLLABO_TERM_MARKER"


def _meta(ws, term_id):
    path = os.path.join(ws, ".collabo", "proc", term_id, "meta.json")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def run():
    s = Suite("터미널 세션 도구 (collabo_term)")
    opened = []

    def t(tool, args):
        return call(tool, args, s.ws, script=TERM_TOOL)

    try:
        # --- describe ---
        d = describe(TERM_TOOL)
        names = [x["function"]["name"] for x in d["tools"]]
        s.equal("모듈 이름", d["module"], "collabo_term")
        s.equal(
            "도구 6종",
            sorted(names),
            ["term_close", "term_list", "term_open", "term_read",
             "term_search", "term_send"],
        )
        for spec in d["tools"]:
            fn = spec["function"]
            s.check(
                "%s 에 설명이 있다" % fn["name"],
                len(fn.get("description") or "") > 40,
                fn.get("description", "")[:40],
            )

        # --- 빈 목록 ---
        out = t("term_list", {})
        s.check("빈 목록도 성공한다", out.get("ok"), out.get("error", ""))
        s.equal("아직 아무것도 없다", out["result"]["count"], 0)

        # --- 열기 ---
        out = t("term_open", {"name": "test", "wait": 15})
        if not s.check("터미널을 연다", out.get("ok"), out.get("error", "")):
            return s.report()
        res = out["result"]
        term_id = res["id"]
        opened.append(term_id)
        s.check("실행 중이다", res["running"], res.get("status"))
        s.equal("이름이 실린다", res["name"], "test")
        s.check("첫 화면을 같이 준다", "screen" in res, list(res))
        if not res.get("pty", True):
            s.check("PTY 가 없으면 이유를 알려 준다",
                    "warning" in res, "경고 없이 조용히 넘어갔다")

        # --- meta.json: Dart 가 읽는 계약 ---
        meta = _meta(s.ws, term_id)
        s.equal("kind 로 명령과 구분한다", meta.get("kind"), "terminal")
        for key in ("id", "pid", "command", "cwd", "status", "pty", "name",
                    "cols", "rows", "started_at"):
            s.check("meta.%s 가 있다" % key, key in meta, sorted(meta))
        s.check("pid 가 숫자다", isinstance(meta.get("pid"), int), meta.get("pid"))

        # --- Dart 가 읽는 파일들이 실제로 있다 ---
        pdir = os.path.join(s.ws, ".collabo", "proc", term_id)
        for fn in ("screen.json", "scrollback.txt", "stdin", "ctrl", "raw.log"):
            s.check("%s 가 만들어진다" % fn,
                    os.path.exists(os.path.join(pdir, fn)), pdir)
        with open(os.path.join(pdir, "screen.json"), encoding="utf-8") as f:
            snap = json.load(f)
        for key in ("cols", "rows", "cursor", "lines", "rev", "at"):
            s.check("screen.%s 가 있다" % key, key in snap, sorted(snap))

        # --- 목록 ---
        out = t("term_list", {})
        s.equal("목록에 하나", out["result"]["count"], 1)
        s.equal("목록의 id 가 같다", out["result"]["terminals"][0]["id"], term_id)

        # --- 보내고 읽기 ---
        out = t("term_send", {"id": term_id, "text": ECHO, "wait": 20})
        if s.check("명령을 보낸다", out.get("ok"), out.get("error", "")):
            screen = out["result"].get("screen", "")
            s.check("출력이 화면에 보인다",
                    "COLLABO_TERM_MARKER" in screen, repr(screen)[-300:])

        # --- 검색 ---
        out = t("term_search", {"id": term_id, "query": "COLLABO_TERM_MARKER"})
        if s.check("검색이 돈다", out.get("ok"), out.get("error", "")):
            s.check("검색이 찾아낸다", out["result"]["match_count"] > 0,
                    out["result"].get("note", ""))
            hit = (out["result"]["matches"] or [{}])[0]
            s.check("줄 번호를 준다", isinstance(hit.get("line"), int), hit)

        out = t("term_search", {"id": term_id, "query": "NOPE_NOT_THERE_XYZ"})
        s.equal("없는 것은 0건", out["result"]["match_count"], 0)
        s.check("없으면 이유를 적어 준다", "note" in out["result"], out["result"])

        # --- 증분 읽기 ---
        t("term_read", {"id": term_id, "mode": "new"})
        out = t("term_read", {"id": term_id, "mode": "new"})
        s.check("두 번째 증분은 비어 있다",
                not (out["result"].get("new_output") or "").strip(),
                repr(out["result"].get("new_output"))[:200])

        # --- tail / range ---
        out = t("term_read", {"id": term_id, "mode": "tail", "lines": 50})
        s.check("tail 은 text 를 준다", "text" in out["result"], list(out["result"]))
        out = t("term_read", {"id": term_id, "mode": "range", "from": 1,
                              "lines": 5})
        s.check("range 는 scrollback 을 준다",
                "scrollback" in out["result"], list(out["result"]))

        # --- 특수키 ---
        out = t("term_send", {"id": term_id, "keys": ["ctrl-c"], "wait": 5})
        s.check("ctrl-c 는 세션을 죽이지 않는다",
                out.get("ok") and out["result"]["running"], out)
        out = t("term_send", {"id": term_id, "keys": "ctrl-c", "read": False})
        s.check("keys 를 문자열로 보내도 받아 준다", out.get("ok"), out.get("error"))
        out = t("term_send", {"id": term_id, "keys": ["no-such-key"],
                              "read": False})
        s.check("모르는 키는 이름을 알려 주며 거절한다",
                not out.get("ok") and "Unknown key" in (out.get("error") or ""),
                out)
        out = t("term_send", {"id": term_id, "read": False})
        s.check("보낼 것이 없으면 거절한다", not out.get("ok"), out)

        # --- id 생략 ---
        out = t("term_read", {})
        s.check("세션이 하나뿐이면 id 를 생략해도 된다",
                out.get("ok"), out.get("error", ""))

        # --- 워크스페이스 밖 ---
        out = t("term_open", {"cwd": "..", "wait": 0})
        s.check("프로젝트 밖에서는 못 연다",
                not out.get("ok") and "outside" in (out.get("error") or "").lower(),
                out)

        # --- 닫기 ---
        out = t("term_close", {"id": term_id})
        if s.check("닫힌다", out.get("ok"), out.get("error", "")):
            s.check("더 이상 실행 중이 아니다", not out["result"]["running"],
                    out["result"].get("status"))
            s.check("마지막 화면을 남겨 준다", "final_screen" in out["result"],
                    list(out["result"]))
        opened.remove(term_id)

        out = t("term_list", {})
        s.equal("닫아도 기록은 남는다", out["result"]["count"], 1)
        s.check("끝난 것으로 표시된다",
                out["result"]["terminals"][0]["running"] is False,
                out["result"]["terminals"][0])

        out = t("term_send", {"id": term_id, "text": "x", "read": False})
        s.check("끝난 세션에는 보낼 수 없다",
                not out.get("ok") and "exited" in (out.get("error") or ""),
                out)

        # --- 없는 id ---
        out = t("term_read", {"id": "nosuchterminal"})
        s.check("없는 id 는 안내와 함께 거절한다",
                not out.get("ok") and "No such terminal" in (out.get("error") or ""),
                out)

    finally:
        # 테스트가 중간에 깨져도 띄운 세션을 남기지 않는다.
        for tid in list(opened):
            call("term_close", {"id": tid}, s.ws, script=TERM_TOOL)
        time.sleep(0.3)

    return s.report()


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
