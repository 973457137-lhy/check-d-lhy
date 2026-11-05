#!/usr/bin/env python3
"""M1 侧调用示例：只用 Python 标准库，不需要 pip install 任何东西。

用法（先启动 serve.dart）：
    python tools/m2-engine/examples/call_engine.py health
    python tools/m2-engine/examples/call_engine.py generate tools/m2-engine/fixtures/normal.json
    python tools/m2-engine/examples/call_engine.py validate tools/m2-engine/fixtures/normal.json

退出码：0 = 调用成功且（validate 时）判定符合预期；1 = 失败。
"""

from __future__ import annotations

import json
import pathlib
import sys
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8787"

# 本机若设了 http_proxy，urllib 会走代理连不上 127.0.0.1；显式禁用代理。
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(path: str, payload: dict | None = None) -> dict:
    url = f"{BASE}{path}"
    if payload is None:
        request = urllib.request.Request(url, method="GET")
    else:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            url, data=data, method="POST", headers={"content-type": "application/json"}
        )
    try:
        with _OPENER.open(request, timeout=10) as response:
            body = response.read().decode("utf-8")
            return {"status": response.status, "json": json.loads(body)}
    except urllib.error.HTTPError as error:  # 4xx 也带 JSON body，要读出来
        body = error.read().decode("utf-8")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"raw": body}
        return {"status": error.code, "json": parsed}


def load_fixture(path: str) -> dict:
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1

    command = argv[1]
    if command == "health":
        result = call("/health")
        print(json.dumps(result["json"], ensure_ascii=False, indent=2))
        return 0 if result["status"] == 200 and result["json"].get("service") == "m2-engine" else 1

    if command not in {"generate", "validate"}:
        print(f"未知命令：{command}")
        return 1

    fixture_path = argv[2] if len(argv) > 2 else "tools/m2-engine/fixtures/normal.json"
    fixture = load_fixture(fixture_path)
    payload = {"input": fixture["input"]}

    if command == "generate":
        result = call("/generate_schedule", payload)
        body = result["json"]
        if result["status"] != 200:
            print(json.dumps(body, ensure_ascii=False, indent=2))
            return 1
        proposal = body["proposal"]
        print(f"HTTP {result['status']}  场景={fixture.get('scenario')}")
        print(f"blocks={len(proposal['blocks'])} changes={len(proposal['changes'])} "
              f"unplanned={len(proposal['unplanned_tasks'])} planned_minutes={body['meta']['planned_minutes']}")
        for block in proposal["blocks"]:
            print(f"  - {block['task_id']}: {block['start_at']} → {block['end_at']} "
                  f"({block['duration_source']}, {block['persistable_as']})")
        for task in proposal["unplanned_tasks"]:
            print(f"  ! 未安排 {task['task_id']}: {task['reason_code']}")
        for note in proposal["explanations"]:
            print(f"  · {note['code']}: {note['message']}")
        return 0

    result = call("/validate_schedule", payload)
    body = result["json"]
    if result["status"] != 200:
        print(json.dumps(body, ensure_ascii=False, indent=2))
        return 1
    print(f"HTTP {result['status']}  场景={fixture.get('scenario')}  来源={body['proposal_source']}")
    print(f"valid={body['valid']} violations={body['counts']['total']}")
    for violation in body["violations"]:
        print(f"  x {violation['code']}: {violation['message']}")
    return 0 if body["valid"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
