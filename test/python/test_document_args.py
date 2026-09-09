"""document_advanced / edit_document 의 **인자 관대화**.

모델이 스키마대로 부르지 않는 경우가 잦다. 뜻이 분명한 형태는 받아 주되,
진짜로 잘못된 호출은 계속 막혀야 한다 — 그 경계를 고정한다.
(§note.md 2026-08-14 "문자열로 보내는 모델", 2026-08-18 "평평하게 보낸 인자")
"""
import os

from harness import Suite
import fixtures


def run():
    s = Suite("document_advanced 인자 관대화")

    deck = fixtures.deck_with_shapes(os.path.join(s.ws, "deck.pptx"))
    deck = os.path.basename(deck)
    doc = fixtures.make(s, "doc.docx")

    # --- 1. 액션 인자를 최상위에 평평하게 보낸 경우 ---
    r = s.call_ok("평평: list_shapes(slide 최상위)", "document_advanced",
                  {"action": "list_shapes", "path": deck, "slide": 1})
    if r is not None:
        s.equal("  결과가 정상이다", len(r.get("shapes", [])), 7)
        s.check("  다음엔 args 에 넣으라는 hint 가 붙는다",
                "top level" in (r.get("hint") or ""), repr(r.get("hint")))

    s.call_ok("평평: 인자 여러 개(set_shape_position)", "document_advanced",
              {"action": "set_shape_position", "path": deck,
               "slide": 1, "shape": 1, "x_cm": 3})

    s.call_ok("평평: docx(set_heading)", "document_advanced",
              {"action": "set_heading", "path": doc, "index": 0, "level": 2})

    # --- 2. 스키마대로 부른 경우는 그대로 ---
    r = s.call_ok("정상: args 중첩", "document_advanced",
                  {"action": "list_shapes", "path": deck, "args": {"slide": 1}})
    if r is not None:
        s.check("  hint 는 붙지 않는다", "hint" not in r, repr(r.get("hint")))

    s.call_ok("정상: args 가 JSON 문자열", "document_advanced",
              {"action": "list_shapes", "path": deck, "args": '{"slide": 1}'})

    s.call_ok("정상: 인자 없는 액션(structure)", "document_advanced",
              {"action": "structure", "path": deck})

    s.call_ok("정상: actions 카탈로그", "document_advanced",
              {"action": "actions", "path": deck})

    # --- 3. 섞어 보낸 경우 ---
    s.call_ok("혼합: args 절반 + 최상위 절반", "document_advanced",
              {"action": "set_shape_position", "path": deck,
               "args": {"slide": 1}, "shape": 1, "x_cm": 2})

    r = s.call_ok("혼합: 같은 키가 겹치면 args 가 이긴다", "document_advanced",
                  {"action": "list_shapes", "path": deck,
                   "slide": 99, "args": {"slide": 1}})
    if r is not None:
        s.equal("  args 의 slide=1 이 쓰였다", r.get("slide"), 1)

    # --- 4. 여전히 막혀야 하는 것 ---
    s.call_fails("차단: 없는 액션", "document_advanced",
                 {"action": "no_such_action", "path": deck})
    s.call_fails("차단: 진짜로 인자가 빠짐", "document_advanced",
                 {"action": "list_shapes", "path": deck})
    s.call_fails("차단: 워크스페이스 밖", "document_advanced",
                 {"action": "structure", "path": "../outside.pptx"})
    s.call_fails("차단: 없는 슬라이드 번호", "document_advanced",
                 {"action": "list_shapes", "path": deck, "slide": 99})

    # --- 5. edit_document: 배열 자리에 객체 하나 ---
    s.call_ok("edits 를 객체 하나로", "edit_document",
              {"path": doc, "edits": {"paragraph": 0, "text": "바뀐 문단"}})
    s.call_ok("edits 배열은 그대로", "edit_document",
              {"path": doc, "edits": [{"paragraph": 0, "text": "다시 바꾼 문단"}]})
    s.call_ok("edits 가 객체 하나짜리 JSON 문자열", "edit_document",
              {"path": doc, "edits": '{"paragraph": 0, "text": "문자열로 온 객체"}'})

    return s.report()
