"""list_shapes 가 **셰이프 종류**와 **자리표시자의 상속 위치**를 알려 주는지.

둘 다 없던 시절에 에이전트가 python-pptx 스크립트를 짜다가 그림에서
`'Picture' object has no attribute 'text'` 로 죽는 일이 있었다(§note.md 2026-08-18).
도구가 그 정보를 주면 스크립트를 짤 이유가 없어진다.
"""
import os

from harness import Suite
import fixtures


def _by_index(shapes):
    return {s["shape"]: s for s in shapes}


def run():
    s = Suite("list_shapes: 종류 + 상속 위치")

    fixtures.deck_with_shapes(os.path.join(s.ws, "deck.pptx"))
    r = s.call_ok("덱을 읽는다", "document_advanced",
                  {"action": "list_shapes", "path": "deck.pptx", "args": {"slide": 1}})
    if r is None:
        return s.report()

    shapes = _by_index(r.get("shapes", []))
    s.equal("셰이프 7개를 모두 본다", len(shapes), 7)

    # --- 종류 ---
    s.equal("0 자리표시자", shapes[0].get("type"), "placeholder")
    s.equal("  자리표시자 종류를 알려 준다", shapes[0].get("ph_type"), "ctrTitle")
    s.equal("1 텍스트박스", shapes[1].get("type"), "textbox")
    s.equal("2 도형", shapes[2].get("type"), "autoshape")
    s.equal("  도형은 모양까지 알려 준다", shapes[2].get("geometry"), "ellipse")
    s.equal("3 그림", shapes[3].get("type"), "picture")
    s.equal("4 표", shapes[4].get("type"), "table")
    s.equal("5 그룹", shapes[5].get("type"), "group")
    s.equal("6 연결선", shapes[6].get("type"), "connector")

    # 예전 필드(XML 태그)도 그대로 준다 — 이걸 보던 쪽이 깨지지 않게.
    s.equal("kind(XML 태그)도 유지된다", shapes[3].get("kind"), "pic")

    # --- 그림에서 죽지 않는다 (python-pptx 스크립트가 죽던 지점) ---
    s.equal("그림의 text 는 빈 문자열", shapes[3].get("text"), "")
    s.equal("그림 이름은 준다", shapes[3].get("name"), "Picture 6")

    # --- 위치 ---
    s.equal("텍스트박스 위치(슬라이드에 있는 값)", shapes[1].get("x_cm"), 1.0)
    s.check("자리표시자도 위치를 준다", shapes[0].get("x_cm") is not None,
            "여전히 비어 있다: %r" % shapes[0])
    s.equal("  레이아웃에서 물려받은 값이다", shapes[0].get("x_cm"), 2.0)
    s.equal("  물려받았다는 표시가 붙는다", shapes[0].get("position_inherited"), True)
    s.check("슬라이드에 값이 있으면 상속 표시가 없다",
            "position_inherited" not in shapes[1], repr(shapes[1]))

    # --- 자리표시자를 옮기면 슬라이드 값이 생겨 상속을 덮어쓴다 ---
    s.call_ok("자리표시자를 옮긴다", "document_advanced",
              {"action": "set_shape_position", "path": "deck.pptx",
               "args": {"slide": 1, "shape": 0, "x_cm": 9}})
    r2 = s.call_ok("다시 읽는다", "document_advanced",
                   {"action": "list_shapes", "path": "deck.pptx", "args": {"slide": 1}})
    if r2 is not None:
        moved = _by_index(r2.get("shapes", []))[0]
        s.equal("  옮긴 값이 보인다", moved.get("x_cm"), 9.0)
        s.check("  이제 상속이 아니다", "position_inherited" not in moved, repr(moved))

    return s.report()
