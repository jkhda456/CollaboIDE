#!/usr/bin/env python3
"""Collabo IDE — Python 환경/라이브러리 점검 스크립트(대화형, 다국어).

현재 인터프리터의 버전과 필수/권장 라이브러리 설치 여부를 확인하고,
누락이 있으면 사용자에게 설치할지 물어본 뒤 pip 로 설치한다.

다국어: 환경변수 COLLABO_LANG 로 전달된 JSON 언어팩을 사용한다(없으면 한국어 기본).
실시간 출력을 위해 인터프리터를 `-u`(unbuffered)로 실행하는 것을 전제로 한다.
점검 대상은 환경변수 COLLABO_REQUIRED(쉼표 구분)로 바꿀 수 있다(기본: mcp).
"""

import importlib.util
import os
import subprocess
import sys

from collabo_i18n import load

T = load()


def check(mod):
    return importlib.util.find_spec(mod) is not None


def main():
    print("=" * 48)
    print(T("check_title", "Python 환경 점검"))
    print("=" * 48)
    print(T("interpreter", "인터프리터:"), sys.executable)
    print(T("version", "버전:"), sys.version.split()[0])
    print()

    required = [
        m.strip()
        for m in os.environ.get("COLLABO_REQUIRED", "mcp").split(",")
        if m.strip()
    ]

    print(T("checking_libs", "필수/권장 라이브러리 확인:"))
    missing = []
    for mod in required:
        ok = check(mod)
        label = T("ok", "OK") if ok else T("missing", "없음")
        print("  [%s] %s" % (label, mod))
        if not ok:
            missing.append(mod)
    print()

    if not missing:
        print(T("all_installed", "모든 라이브러리가 설치되어 있습니다."))
        print(T("done", "완료."))
        return 0

    print(T("missing_list", "누락된 라이브러리: ") + ", ".join(missing))
    print()
    print(T("auto_install_start", "자동 설치를 시작합니다…"))

    failed = []
    for mod in missing:
        print()
        print(T("installing", "-> 설치 중: ") + mod)
        rc = subprocess.call([sys.executable, "-m", "pip", "install", mod])
        print("   (%s) %s%d" % (mod, T("exit_code", "종료코드 "), rc))
        if rc != 0:
            failed.append(mod)

    print()
    if failed:
        print(T("install_failed", "설치 실패: ") + ", ".join(failed))
        return 1
    print(T("install_done", "설치 완료."))
    print(T("done", "완료."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
