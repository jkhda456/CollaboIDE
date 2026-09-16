"""VT 화면 에뮬레이터(`vt_screen.py`) 단위 테스트.

여기만은 서브프로세스가 아니라 **직접 import** 한다 — 도구 계약의 바깥이고,
`term_runner.py` 가 in-process 로 쓰는 순수 함수 계층이기 때문이다.

지키려는 것은 하나다: **원시 바이트가 아니라 사람이 본 화면**이 나와야 한다.
`\\r` 로 덮어쓴 진행바, `ESC[2J` 로 지운 화면, vim 이 쓰는 대체 화면 — 이걸
구분하지 못하면 LLM 에게 "그려진 모든 중간 프레임" 을 넘기게 된다.
"""
import os
import sys

# ⚠️ 이 스위트만 도구 모듈을 **import** 한다 — 그대로 두면 `assets/python/` 안에
# `__pycache__` 가 생겨 리포지토리에 섞인다(전부터 되풀이되던 문제라 §note 10 에
# 남아 있다). run_all.py 는 이미 끄지만, 이 파일을 직접 돌릴 때도 막는다.
sys.dont_write_bytecode = True

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "assets",
        "python",
    ),
)

from harness import Suite  # noqa: E402
from vt_screen import Screen  # noqa: E402


def run():
    s = Suite("VT 화면 에뮬레이터 (vt_screen)")

    # --- 기본 출력과 덮어쓰기 ---
    sc = Screen(cols=20, rows=4)
    sc.feed(b"loading 10%\rloading 99%")
    s.equal("CR 은 같은 줄을 덮어쓴다(진행바)", sc.display()[0], "loading 99%")

    sc = Screen(cols=20, rows=3)
    sc.feed(b"a\r\nb\r\nc\r\nd\r\ne")
    s.equal("밀려난 줄만 스크롤백으로", sc.take_scrolled(), ["a", "b"])
    s.equal("화면에는 마지막 세 줄", sc.display(), ["c", "d", "e"])
    s.equal("가져간 뒤에는 비어 있다", sc.take_scrolled(), [])

    # --- 커서와 지우기 ---
    sc = Screen(cols=10, rows=3)
    sc.feed(b"hello\x1b[1;1Hxy")
    s.equal("커서 이동 후 덮어쓰기", sc.display()[0], "xyllo")
    sc.feed(b"\x1b[2K")
    s.equal("ESC[2K 는 줄을 지운다", sc.display()[0], "")

    # --- 전각(한글) ---
    sc = Screen(cols=10, rows=2)
    sc.feed("한글abc".encode("utf-8"))
    s.equal("한글은 두 칸을 쓴다", sc.display()[0], "한글abc")
    s.equal("커서도 두 칸씩 민다", sc.x, 7)

    # --- 줄바꿈 시점 ---
    sc = Screen(cols=5, rows=3)
    sc.feed(b"12345")
    s.equal("폭에 딱 맞아도 아직 안 넘긴다", sc.display(), ["12345", "", ""])
    sc.feed(b"6")
    s.equal("다음 글자에서 넘긴다", sc.display(), ["12345", "6", ""])

    # --- 대체 화면(vim/top) ---
    sc = Screen(cols=10, rows=2)
    sc.feed(b"real\r\n")
    sc.take_scrolled()
    sc.feed(b"\x1b[?1049h")
    sc.feed(b"x\r\ny\r\nz\r\nw")
    s.equal("대체 화면의 스크롤은 기록하지 않는다", sc.take_scrolled(), [])
    sc.feed(b"\x1b[?1049l")
    s.equal("빠져나오면 원래 화면이 돌아온다", sc.display()[0], "real")

    # --- clear ---
    sc = Screen(cols=10, rows=3)
    sc.feed(b"keep me\r\n")
    sc.take_scrolled()
    sc.feed(b"\x1b[2J\x1b[H")
    s.equal("clear 는 화면만 지우고 기록은 남긴다",
            sc.take_scrolled(), ["keep me"])

    # --- 색/제목 ---
    sc = Screen(cols=20, rows=2)
    sc.feed(b"\x1b[1;31mRED\x1b[0m done")
    s.equal("SGR(색)은 통째로 버린다", sc.display()[0], "RED done")

    sc = Screen(cols=20, rows=2)
    sc.feed(b"\x1b]0;my title\x07hi")
    s.equal("OSC 는 제목으로만 남는다", sc.title, "my title")
    s.equal("제목은 화면에 새지 않는다", sc.display()[0], "hi")

    # --- 청크 경계 ---
    sc = Screen(cols=20, rows=2)
    sc.feed(b"\x1b[")
    sc.feed(b"1;1Hab")
    s.equal("시퀀스가 두 청크에 걸쳐도 된다", sc.display()[0], "ab")
    sc = Screen(cols=20, rows=2)
    raw = "가".encode("utf-8")
    sc.feed(raw[:1])
    sc.feed(raw[1:])
    s.equal("UTF-8 도 청크 경계를 넘는다", sc.display()[0], "가")

    # --- 삽입/삭제/스크롤 영역 ---
    sc = Screen(cols=10, rows=2)
    sc.feed(b"abcdef\x1b[1;3H\x1b[2P")
    s.equal("ESC[P 는 글자를 지운다", sc.display()[0], "abef")
    sc = Screen(cols=10, rows=2)
    sc.feed(b"abcdef\x1b[1;3H\x1b[2@")
    s.equal("ESC[@ 는 자리를 벌린다", sc.display()[0], "ab  cdef")

    sc = Screen(cols=10, rows=4)
    sc.feed(b"1\r\n2\r\n3\r\n4")
    sc.take_scrolled()
    sc.feed(b"\x1b[2;3r\x1b[3;1H\r\nX")
    s.equal("스크롤 영역 안에서만 민다", sc.display(), ["1", "3", "X", "4"])

    # --- 크기 변경 ---
    sc = Screen(cols=10, rows=3)
    sc.feed(b"abcdefghij")
    sc.resize(5, 2)
    s.equal("좁히면 잘린다", sc.display()[0], "abcde")
    s.equal("행 수도 따라간다", len(sc.display()), 2)

    # --- 모르는 시퀀스 ---
    sc = Screen(cols=20, rows=2)
    sc.feed(b"\x1b[>4;2mA\x1b[?2004hB")
    s.equal("모르는 시퀀스는 찍지 않고 버린다", sc.display()[0], "AB")

    return s.report()


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
