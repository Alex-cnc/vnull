#!/bin/bash
# FR-AI-10 MCP 双向的可复跑证据。
#
# **两个方向都用假对端**（与替身 ssh、假 MySQL 服务器同一思路）：
#   · 方向 A（我们当 server）：一个 Python **假 MCP host** 往 `doyah mcp serve` 的 stdin 写 JSON-RPC、读 stdout；
#   · 方向 B（我们当 host）：一个 Python **假 MCP server** 读 stdin 写 stdout，由 `doyah mcp call` 驱动。
#
# 于是"消息格式对不对、权限有没有继承、写操作要不要审批、审计有没有留痕"这些**全部可断言**，
# 不需要真实 MCP 客户端 / 服务器，也不需要网络。
#
# 命中的纪律（需求原文）：权限继承当前会话、不另开特权；外部调用同样进审批与审计。
#
# 用法：./Scripts/test-mcp.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PGPORT_TEST="${DOYAH_TEST_PGPORT}"
WORK="$PWD/.build/mcp-$$"
STARTED_PG=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() {
    [ "$STARTED_PG" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 0) 构建 CLI 与准备本机 PostgreSQL =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > .build/mcp-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 .build/mcp-build.log
    exit 1
fi

if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then
    STARTED_PG=1
    "$PGBIN/pg_ctl" -D "$DATADIR" -o "-p ${PGPORT_TEST} -k /tmp" -l /tmp/doyah-mcp-pg.log start >/dev/null 2>&1
    sleep 2
fi
"$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1 && check "本机 PG 在跑" 0 || check "本机 PG 在跑" 1

mkdir -p "$WORK"
doyah_test_env_export_connection
export PGDATABASE="${DOYAH_TEST_PGDATABASE}"

echo ""
echo "== 1) 方向 A：我们当 server（假 MCP host 驱动） =="
AUDIT="$WORK/audit.jsonl"
"$CLI" mcp serve --audit "$AUDIT" < /dev/null > "$WORK/serve-idle.out" 2>/dev/null
python3 - "$CLI" "$WORK" <<'PY' 2>&1 | tail -20
import json, subprocess, sys
cli, work = sys.argv[1], sys.argv[2]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2024-11-05", "clientInfo": {"name": "fake-host", "version": "0.1"}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    # 只读查询：不需要审批
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "query_sql", "arguments": {"sql": "SELECT current_database() AS db"}}},
    # 写语句塞进同一个工具：**判据是语句内容，不是工具名** → 需要审批（这里没批准）
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
        "name": "query_sql", "arguments": {"sql": "DELETE FROM customers"}}},
    # 同一工具的写语句，**按次批准**：只放行 SQL 完全一致的那一次
    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {
        "name": "query_sql", "arguments": {"sql": "CREATE TEMP TABLE mcp_probe (id int)"}}},
    # 没暴露的工具
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "run_shell", "arguments": {}}},
    # 我们不实现的方法
    {"jsonrpc": "2.0", "id": 6, "method": "prompts/list", "params": {}},
    # 坏报文
    "这不是 JSON",
]
stdin = "\n".join(json.dumps(r, ensure_ascii=False) if isinstance(r, dict) else r for r in requests) + "\n"
proc = subprocess.run([cli, "mcp", "serve", "--audit", work + "/audit.jsonl",
                           "--approve-write", "CREATE TEMP TABLE mcp_probe (id int)"],
                      input=stdin.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
lines = [json.loads(l) for l in proc.stdout.decode().splitlines() if l.strip()]
assert len(lines) >= 7, ("回复条数不对", len(lines), proc.stdout.decode()[:400])
by_id = {l.get("id"): l for l in lines if isinstance(l, dict)}

init = by_id[1]["result"]
assert init["protocolVersion"] == "2024-11-05", init
assert init["serverInfo"]["name"] == "DoyahStudio", init
print("  ✅ initialize 回了协议版本与服务器名")

tools = [t["name"] for t in by_id[2]["result"]["tools"]]
assert sorted(tools) == ["describe_table", "export_result", "list_objects", "query_sql"], tools
print("  ✅ tools/list 恰好暴露四个工具：%s" % ",".join(sorted(tools)))

query = by_id[3]["result"]
assert query["isError"] is False, query
assert "doyah_manual_test" in query["content"][0]["text"], query
print("  ✅ 只读查询免审批，且真的在库里跑出了结果（current_database）")

write = by_id[4]["result"]
assert write["isError"] is True and "审批" in write["content"][0]["text"], write
print("  ✅ 写语句（哪怕塞在 query_sql 里）要审批：%s" % write["content"][0]["text"][:40])

approved = by_id[7]["result"]
assert approved["isError"] is False, approved
print("  ✅ 按次批准：只放行被点名的那一条写语句，它真的执行了")

run_shell = by_id[5]["result"]
assert run_shell["isError"] is True and "没有暴露" in run_shell["content"][0]["text"], run_shell
print("  ✅ 没暴露的工具被拒")

unknown = [l for l in lines if l.get("id") == 6][0]["error"]
assert unknown["code"] == -32601, unknown
print("  ✅ 不实现的方法回 -32601（method not found）")

bad = [l for l in lines if l.get("id") is None and "error" in l]
assert bad and bad[0]["error"]["code"] == -32700, bad
print("  ✅ 坏报文回 -32700（parse error）")

audit = open(work + "/audit.jsonl", encoding="utf-8").read().splitlines()
kinds = [json.loads(a)["tool"] for a in audit]
assert "initialize" in kinds and "query_sql" in kinds, kinds
assert any("refused" not in a and "needs-approval" in a for a in audit), audit
print("  ✅ 审计文件留下了每一次调用（%d 条）" % len(audit))
PY
[ $? -eq 0 ] && check "方向 A 七项（详见上）" 0 || check "方向 A 七项（详见上）" 1

echo ""
echo "== 2) 方向 A：只读会话下写语句被拒（批准也不能绕过） =="
python3 - "$CLI" "$WORK" <<'PY'
import json, subprocess, sys
cli, work = sys.argv[1], sys.argv[2]
requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "query_sql", "arguments": {"sql": "UPDATE customers SET name = 'x'"}}},
]
stdin = "\n".join(json.dumps(r) for r in requests) + "\n"
proc = subprocess.run([cli, "mcp", "serve", "--read-only",
                       "--approve-write", "UPDATE customers SET name = 'x'"],
                      input=stdin.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
lines = [json.loads(l) for l in proc.stdout.decode().splitlines() if l.strip()]
result = [l for l in lines if l.get("id") == 2][0]["result"]
assert result["isError"] is True, result
assert "只读" in result["content"][0]["text"], result
print("  ✅ 只读会话：写语句被拒，且已批准也救不回来")
PY
[ $? -eq 0 ] && check "只读会话拒写（详见上）" 0 || check "只读会话拒写（详见上）" 1

echo ""
echo "== 3) 方向 B：我们当 host（假 MCP server） =="
cat > "$WORK/fake_server.py" <<'PY'
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {
            "protocolVersion": "2024-11-05",
            "serverInfo": {"name": "fake-files", "version": "0.2"},
            "capabilities": {"tools": {}}}}), flush=True)
    elif method == "tools/list":
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {"tools": [
            {"name": "read_file", "description": "Read a file"},
            {"name": "write_file", "description": "Write a file"}]}}), flush=True)
    elif method == "tools/call":
        args = message.get("params", {}).get("arguments", {})
        text = "echo:" + json.dumps(args, ensure_ascii=False, sort_keys=True)
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {
            "content": [{"type": "text", "text": text}], "isError": False}}), flush=True)
PY
OUT="$("$CLI" mcp call --command "python3 $WORK/fake_server.py" --tool read_file --args '{"path":"/tmp/a.txt"}' 2>/dev/null)"
echo "$OUT" > "$WORK/call.out"
grep -q "server=fake-files" "$WORK/call.out" && check "握手里读到了对端名字" 0 || check "握手里读到了对端名字" 1
grep -q "tools=read_file,write_file" "$WORK/call.out" && check "tools/list 解析出两个工具（顺序保持）" 0 || check "tools/list 解析出两个工具（顺序保持）" 1
grep -q 'echo:{"path": "/tmp/a.txt"}' "$WORK/call.out" && check "tools/call 的结果原样回传（中文/JSON 不丢）" 0 || check "tools/call 的结果原样回传（中文/JSON 不丢）" 1

echo ""
echo "== 4) 方向 B：对端报错要如实透出 =="
cat > "$WORK/bad_server.py" <<'PY'
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Method not found"}}), flush=True)
PY
"$CLI" mcp call --command "python3 $WORK/bad_server.py" > "$WORK/bad.out" 2>/dev/null
grep -q "error=Method not found" "$WORK/bad.out" && check "对端的 JSON-RPC 错误如实透出" 0 || check "对端的 JSON-RPC 错误如实透出" 1

echo ""
echo "== 5) 界面审批通道：入队 → 人点 → 按决定执行（FR-AI-10 的界面那一半） =="
# 三条路径分开验，**重点是"没人点的时候会怎样"**：
# 默认放行是最危险的默认值，所以拒绝与超时都必须如实回错误内容、且都不执行。
QUEUE="$WORK/approvals"
mkdir -p "$QUEUE"

if python3 Scripts/mcp-stub/approval_host.py --cli "$CLI" --queue "$QUEUE" --work "$WORK" \
    --mode deny --sql "CREATE TEMP TABLE mcp_deny (id int)" > "$WORK/approve-deny.out" 2>&1; then
    check "拒绝路径：入队 → 拒绝 → 如实回错误（不执行）" 0
else
    check "拒绝路径：入队 → 拒绝 → 如实回错误（不执行）" 1
    tail -5 "$WORK/approve-deny.out"
fi
grep -q "进了待审批队列" "$WORK/approve-deny.out" && check "需要的调用确实进了队列" 0 || check "需要的调用确实进了队列" 1

if python3 Scripts/mcp-stub/approval_host.py --cli "$CLI" --queue "$QUEUE" --work "$WORK" \
    --mode allow --sql "CREATE TEMP TABLE mcp_allow (id int)" > "$WORK/approve-allow.out" 2>&1; then
    check "批准路径：入队 → 批准 → 真执行 + 审计留痕" 0
else
    check "批准路径：入队 → 批准 → 真执行 + 审计留痕" 1
    tail -5 "$WORK/approve-allow.out"
fi

if python3 Scripts/mcp-stub/approval_host.py --cli "$CLI" --queue "$QUEUE" --work "$WORK" \
    --mode timeout --sql "CREATE TEMP TABLE mcp_timeout (id int)" > "$WORK/approve-timeout.out" 2>&1; then
    check "超时路径：没人确认就不放行（默认拒绝）" 0
else
    check "超时路径：没人确认就不放行（默认拒绝）" 1
    tail -5 "$WORK/approve-timeout.out"
fi

echo ""
echo "== 6) 队列本身：坏行不致命、待办可被脚本列出 =="
printf '{这不是 JSON}\n' >> "$QUEUE/pending.jsonl"
"$CLI" mcp pending --approval-queue "$QUEUE" --json > "$WORK/pending-after.json" 2>&1
grep -q '"pending":\[' "$WORK/pending-after.json" && check "有坏行时队列仍可读（逐行 JSONL）" 0 || check "有坏行时队列仍可读（逐行 JSONL）" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ MCP 双向全部通过（含界面审批通道：入队 → 人点 → 按决定执行）"
else
    echo "❌ 有断言失败，见上"
fi
exit "$fail"
