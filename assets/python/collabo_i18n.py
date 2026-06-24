"""Collabo IDE — Python 스크립트용 경량 i18n 로더(stdlib 전용).

언어팩(JSON)은 실행 시 환경변수 COLLABO_LANG 로 파일 경로를 전달받는다.
파일이 없거나 키가 없으면 호출부의 기본값(보통 한국어)을 사용한다.

사용:
    from collabo_i18n import load
    T = load()
    print(T("done", "완료."))
"""

import json
import os


def load(env_var="COLLABO_LANG"):
    data = {}
    path = os.environ.get(env_var, "")
    if path:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}

    def t(key, default=""):
        value = data.get(key, default)
        return value if isinstance(value, str) else default

    return t
