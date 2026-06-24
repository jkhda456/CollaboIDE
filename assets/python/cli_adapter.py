#!/usr/bin/env python3
"""Collabo IDE — 일반 Python 스크립트 어댑터.

대상 스크립트의 `--help` 를 실행·파싱해 function calling 도구 1개(JSON 스키마)를
자동 생성한다. LLM 이 그 도구를 호출하면 인자를 CLI 인자로 변환해 스크립트를 실행한다.

계약(describe/call)은 기본 모듈과 동일하므로 동일 실행기에 그대로 연결된다.

환경변수:
  COLLABO_TARGET : 대상 Python 스크립트 경로(필수).
"""

import json
import os
import re
import subprocess
import sys

TARGET = os.environ.get("COLLABO_TARGET", "")


def _tool_name():
    base = os.path.splitext(os.path.basename(TARGET))[0]
    name = re.sub(r"[^a-zA-Z0-9_]", "_", base).strip("_")
    return name or "cli_tool"


def _run_help():
    proc = subprocess.run(
        [sys.executable, TARGET, "--help"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    return proc.stdout or proc.stderr or ""


# 파싱 결과를 보관: 인자명 -> 렌더링 정보
#   {"flag": "--name"|None, "takes_value": bool, "positional": bool, "order": int}
def _parse_help(text):
    description_lines = []
    properties = {}
    required = []
    render = {}
    pos_order = 0

    section = None
    # 옵션 한 줄: "  -n NAME, --name NAME   도움말"  /  "  --verbose   도움말"
    opt_re = re.compile(r"^\s+(-{1,2}[^\s].*?)(?:\s{2,}(.*))?$")

    for line in text.splitlines():
        low = line.strip().lower()
        if low.startswith("positional arguments"):
            section = "pos"
            continue
        if low.startswith("options") or low.startswith("optional arguments"):
            section = "opt"
            continue
        if not line.strip():
            continue

        if section is None:
            if not low.startswith("usage:"):
                description_lines.append(line.strip())
            continue

        if section == "opt":
            m = opt_re.match(line)
            if not m:
                continue
            spec, help_text = m.group(1), (m.group(2) or "").strip()
            # 긴 옵션(--xxx) 우선, 없으면 짧은 옵션(-x).
            long_m = re.search(r"--([a-zA-Z0-9][\w-]*)", spec)
            short_m = re.search(r"(?<!-)-([a-zA-Z0-9])\b", spec)
            flag = "--" + long_m.group(1) if long_m else (
                "-" + short_m.group(1) if short_m else None)
            if flag in (None, "--help", "-h"):
                continue
            # 값을 받는지: 옵션 뒤에 대문자 metavar 또는 =VALUE 가 있으면.
            takes_value = bool(re.search(r"(--[\w-]+|-[a-zA-Z])[ =]([A-Z][A-Z0-9_]*|\<)", spec))
            prop = (long_m.group(1) if long_m else short_m.group(1)).replace("-", "_")
            properties[prop] = {
                "type": "string" if takes_value else "boolean",
                "description": help_text,
            }
            render[prop] = {"flag": flag, "takes_value": takes_value, "positional": False}

        elif section == "pos":
            m = re.match(r"^\s+([A-Za-z0-9_][\w-]*)\s{2,}(.*)$", line)
            if not m:
                m2 = re.match(r"^\s+([A-Za-z0-9_][\w-]*)\s*$", line)
                if not m2:
                    continue
                name, help_text = m2.group(1), ""
            else:
                name, help_text = m.group(1), m.group(2).strip()
            prop = name.replace("-", "_")
            properties[prop] = {"type": "string", "description": help_text}
            required.append(prop)
            render[prop] = {"flag": None, "takes_value": True, "positional": True, "order": pos_order}
            pos_order += 1

    description = " ".join(description_lines).strip() or ("실행: %s" % _tool_name())
    return description[:500], properties, required, render


def _build_tool():
    description, properties, required, render = _parse_help(_run_help())
    schema = {
        "type": "function",
        "function": {
            "name": _tool_name(),
            "description": description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": required,
            },
        },
    }
    return schema, render


def _describe():
    schema, _ = _build_tool()
    return {
        "module": _tool_name(),
        "version": "cli-1",
        "kind": "cli",
        "tools": [schema],
    }


def _call(tool_name, args):
    schema, render = _build_tool()
    if tool_name != schema["function"]["name"]:
        return {"ok": False, "error": "알 수 없는 도구: %s" % tool_name}

    options = []
    positionals = []
    for prop, info in render.items():
        if prop not in args or args[prop] is None:
            continue
        value = args[prop]
        if info["positional"]:
            positionals.append((info["order"], str(value)))
        elif info["takes_value"]:
            options += [info["flag"], str(value)]
        elif value:  # boolean flag
            options.append(info["flag"])

    positionals.sort(key=lambda x: x[0])
    argv = [sys.executable, TARGET] + options + [v for _, v in positionals]
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "실행이 시간 초과되었습니다."}
    return {
        "ok": True,
        "result": {
            "exit_code": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        },
    }


def main(argv):
    if not TARGET:
        sys.stdout.write(json.dumps({"ok": False, "error": "COLLABO_TARGET 미설정"}))
        return 0
    if len(argv) >= 2 and argv[1] == "describe":
        sys.stdout.write(json.dumps(_describe(), ensure_ascii=False))
        return 0
    if len(argv) >= 3 and argv[1] == "call":
        raw = sys.stdin.read()
        try:
            args = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError as e:
            sys.stdout.write(json.dumps({"ok": False, "error": "잘못된 인자 JSON: %s" % e}))
            return 0
        sys.stdout.write(json.dumps(_call(argv[2], args), ensure_ascii=False))
        return 0
    sys.stderr.write("usage: cli_adapter.py {describe|call <tool>}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
