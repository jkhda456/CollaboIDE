"""Python 도구 테스트 전체 실행.

    python3 test/python/run_all.py

표준 라이브러리만 쓴다(도구 자체가 그렇기 때문이다). Flutter 툴체인과 무관하므로
`flutter test` 와 별개로 돌린다.
"""
import os
import sys

# 리포지토리에 __pycache__ 를 다시 만들지 않는다(예전부터 정리 대상이었다).
sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import test_document_args      # noqa: E402
import test_shapes             # noqa: E402
import test_term               # noqa: E402
import test_vt                 # noqa: E402
import test_web                # noqa: E402

SUITES = [test_document_args, test_shapes, test_web, test_vt, test_term]


def main():
    failed = 0
    for suite in SUITES:
        failed += suite.run()
    print()
    if failed:
        print("실패 %d건" % failed)
        return 1
    print("전부 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
