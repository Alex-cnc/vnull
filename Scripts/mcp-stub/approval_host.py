#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""假 MCP host：验证**界面审批通道**（FR-AI-10 的界面那一半）。

做三件事，覆盖三条路径（用 `--mode` 选）：
  · `deny`：发一个写调用 → 等它进待审批队列 → 写一条**拒绝** → 必须收到"没执行"的错误内容；
  · `allow`：同上，但写**允许** → 必须真的执行（建临时表成功），且审计里留下"等待 → 批准"；
  · `timeout`：谁都不点 → 到点必须**不放行**（默认拒绝，而不是默认同意）。

为什么要专门验这三条：审批通道的价值全在"没人点的时候会怎样"。
默认放行是最危险的默认值 —— 这条脚本就是防止它被写反。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time


def pending_request(cli: str, queue: str, timeout_seconds: float = 10.0) -> str:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        time.sleep(0.25)
        result = subprocess.run(
            [cli, "mcp", "pending", "--approval-queue", queue, "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        try:
            items = json.loads(result.stdout.decode())["pending"]
        except Exception:
            continue
        if items:
            return items[0]["id"]
    raise AssertionError("没有等到待审批的请求")


def run(cli: str, queue: str, work: str, mode: str, sql: str) -> None:
    requests = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "clientInfo": {"name": "approval-host"}},
        },
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "query_sql", "arguments": {"sql": sql}},
        },
    ]
    stdin = "\n".join(json.dumps(request) for request in requests) + "\n"
    audit_path = work + "/audit-approval.jsonl"
    command = [
        cli, "mcp", "serve",
        "--approval-queue", queue,
        "--approval-timeout", "2" if mode == "timeout" else "20",
        "--audit", audit_path,
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    process.stdin.write(stdin.encode())
    process.stdin.flush()

    if mode == "timeout":
        # 谁都不点：等到超时。
        process.stdin.close()
    else:
        request_id = pending_request(cli, queue)
        print("  ✅ 写调用进了待审批队列：%s" % request_id, flush=True)
        decision = "--allow" if mode == "allow" else "--deny"
        subprocess.run(
            [cli, "mcp", "decide", request_id, decision, "--approval-queue", queue],
            stdout=subprocess.DEVNULL,
            check=True,
        )
        process.stdin.close()

    stdout = process.stdout.read().decode()
    stderr = process.stderr.read().decode()
    lines = [json.loads(line) for line in stdout.splitlines() if line.strip()]
    responses = [line for line in lines if line.get("id") == 2]
    assert responses, ("没有收到 tools/call 的回复", stdout, stderr)
    result = responses[0]["result"]

    if mode == "allow":
        assert result["isError"] is False, result
        print("  ✅ 批准之后真的执行了（建临时表成功）", flush=True)
        audit = open(audit_path, encoding="utf-8").read()
        assert "waiting-approval" in audit and "approved-by-user" in audit, audit
        print("  ✅ 审计里留下了「等待审批 → 用户批准」两段", flush=True)
    else:
        assert result["isError"] is True, (result, stderr)
        assert "拒绝" in result["content"][0]["text"] or "超时" in result["content"][0]["text"], result
        label = "拒绝" if mode == "deny" else "超时"
        print("  ✅ %s之后如实回错误内容（没有偷偷执行）" % label, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--queue", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--mode", required=True, choices=["deny", "allow", "timeout"])
    parser.add_argument("--sql", default="CREATE TEMP TABLE mcp_approval (id int)")
    args = parser.parse_args()
    run(args.cli, args.queue, args.work, args.mode, args.sql)
    return 0


if __name__ == "__main__":
    sys.exit(main())
