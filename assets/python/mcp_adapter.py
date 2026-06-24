#!/usr/bin/env python3
"""Collabo IDE — MCP 도구 어댑터.

내장(포터블) Python 으로 MCP 서버를 stdio(JSON-RPC 2.0, 줄 단위) 로 제어한다.
MCP 서버의 tools 를 function calling 도구로 노출한다(describe/call 계약).

환경변수:
  COLLABO_MCP_COMMAND : JSON {"command": "...", "args": [...], "env": {...}}
"""

import json
import os
import queue
import subprocess
import sys
import threading

PROTOCOL_VERSION = "2024-11-05"


def _server_spec():
    raw = os.environ.get("COLLABO_MCP_COMMAND", "")
    if not raw:
        raise RuntimeError("COLLABO_MCP_COMMAND 미설정")
    spec = json.loads(raw)
    if not spec.get("command"):
        raise RuntimeError("MCP command 가 비어 있습니다.")
    return spec


class McpClient:
    """MCP stdio 서버에 대한 최소 JSON-RPC 클라이언트."""

    def __init__(self, spec):
        env = dict(os.environ)
        env.update(spec.get("env") or {})
        self.proc = subprocess.Popen(
            [spec["command"], *(spec.get("args") or [])],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=env,
        )
        self._id = 0
        self._q = queue.Queue()
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def _read_loop(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._q.put(json.loads(line))
            except json.JSONDecodeError:
                continue  # 서버 로그 등 비-JSON 무시

    def _send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self._id += 1
            msg["id"] = self._id
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        return None if notify else self._id

    def _await(self, want_id, timeout=30):
        while True:
            msg = self._q.get(timeout=timeout)  # queue.Empty → 예외로 상위 전달
            if msg.get("id") == want_id:
                if "error" in msg:
                    raise RuntimeError(msg["error"].get("message", "MCP 오류"))
                return msg.get("result", {})

    def initialize(self):
        rid = self._send("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "collabo-ide", "version": "0.1.0"},
        })
        self._await(rid)
        self._send("notifications/initialized", notify=True)

    def list_tools(self):
        rid = self._send("tools/list")
        return self._await(rid).get("tools", [])

    def call_tool(self, name, arguments):
        rid = self._send("tools/call", {"name": name, "arguments": arguments or {}})
        return self._await(rid)

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.terminate()
        except Exception:
            pass


def _to_openai_tool(mcp_tool):
    params = mcp_tool.get("inputSchema") or {"type": "object", "properties": {}}
    return {
        "type": "function",
        "function": {
            "name": mcp_tool.get("name", ""),
            "description": mcp_tool.get("description", ""),
            "parameters": params,
        },
    }


def _describe():
    client = McpClient(_server_spec())
    try:
        client.initialize()
        tools = client.list_tools()
    finally:
        client.close()
    return {
        "module": "mcp",
        "version": "mcp-1",
        "kind": "mcp",
        "tools": [_to_openai_tool(t) for t in tools],
    }


def _call(tool_name, args):
    client = McpClient(_server_spec())
    try:
        client.initialize()
        result = client.call_tool(tool_name, args)
    finally:
        client.close()
    if result.get("isError"):
        return {"ok": False, "error": _content_text(result)}
    return {"ok": True, "result": _content_text(result), "raw": result}


def _content_text(result):
    parts = []
    for c in result.get("content", []) or []:
        if isinstance(c, dict) and c.get("type") == "text":
            parts.append(c.get("text", ""))
    return "\n".join(parts) if parts else result


def main(argv):
    try:
        if len(argv) >= 2 and argv[1] == "describe":
            sys.stdout.write(json.dumps(_describe(), ensure_ascii=False))
            return 0
        if len(argv) >= 3 and argv[1] == "call":
            raw = sys.stdin.read()
            args = json.loads(raw) if raw.strip() else {}
            sys.stdout.write(json.dumps(_call(argv[2], args), ensure_ascii=False))
            return 0
    except Exception as e:  # noqa: BLE001
        sys.stdout.write(json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e)}))
        return 0
    sys.stderr.write("usage: mcp_adapter.py {describe|call <tool>}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
