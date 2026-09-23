#!/bin/bash
# 真机/本地验证：本地模型端点全流程 + 零外发（NFR-AI-06）。
#
# 为什么用**本地假端点**而不是真 Ollama：这条需求要证的是**客户端行为** ——
# 指向本地端点时是否免 Key、请求怎么组装、响应怎么解析、外发日志是否只记本地目标。
# 用一个只回固定响应的本地 HTTP 服务就能把这些**完整**验一遍，而且不依赖任何外部环境。
# （真实 Ollama / vLLM 的联调仍需要那台机器上有模型，见运行手册"需要需求提出者"一节。）
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PORT=18134

# 外发日志写到临时目录：受限环境（沙箱）里 `~/Library/Application Support` 不可写，
# 不覆盖的话"日志真的记下来了"这条证据就拿不到。
export DOYAH_EGRESS_LOG_DIR="$(mktemp -d -t doyah-egress)"
export PGHOST

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

cleanup() {
    [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
    rm -f /tmp/doyah-stub-openai.py /tmp/doyah-stub.log
}
trap cleanup EXIT

echo "== 0) 起一个本地假端点（只回固定响应，不连外网）=="
cat > /tmp/doyah-stub-openai.py <<'PY'
#!/usr/bin/env python3
"""本地假 OpenAI 兼容端点：验证「指向本地端点即零外发」这条链路。"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18134
SQL = "SELECT id, payload FROM orders WHERE created_at > now() - interval '7 days'"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}
        sys.stderr.write("STUB_REQ model=%s auth=%s body_bytes=%d\n" % (
            payload.get("model"), self.headers.get("Authorization"), length))
        sys.stderr.flush()
        response = {
            "model": payload.get("model", "stub"),
            "choices": [{
                "message": {"role": "assistant", "content": SQL + "\n\n这条查询只看最近 7 天的订单。"},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 120, "completion_tokens": 40, "total_tokens": 160},
        }
        data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
python3 /tmp/doyah-stub-openai.py "$PORT" 2>/tmp/doyah-stub.log &
STUB_PID=$!
sleep 1
kill -0 "$STUB_PID" 2>/dev/null && echo "  ✅ 假端点已监听 127.0.0.1:${PORT}（pid ${STUB_PID}）" || { echo "  ❌ 假端点没起来"; exit 1; }

echo ""
echo "== 1) 本地端点：免 API Key 全流程 =="
OUT="$("$CLI" agent-sql \
    --endpoint "http://127.0.0.1:${PORT}/v1" \
    --model "qwen2.5:7b" \
    --schema "orders,customers" \
    --show-egress \
    "找出最近 7 天的订单" 2>&1)"
CODE=$?
echo "$OUT" | sed 's/^/  /'
[ "$CODE" -eq 0 ] && check "命令成功（退出码 0）" 0 || check "命令成功" 1
echo "$OUT" | grep -q "本地端点判定：是（免 API Key）" && check "识别为本地端点且免 Key" 0 || check "本地端点识别" 1
echo "$OUT" | grep -q "SELECT id, payload FROM orders" && check "取到了模型给的 SQL" 0 || check "取到 SQL" 1
echo "$OUT" | grep -q "这条查询只看最近 7 天的订单" && check "解释文本保留（可复核，NFR-AI-05）" 0 || check "解释保留" 1
echo "$OUT" | grep -q "是否已执行：否" && check "结果**未执行**（FR-AI-02）" 0 || check "结果未执行" 1
echo "$OUT" | grep -q "配额账本：请求 1 次 / 160 token" && check "配额账本记账正确" 0 || check "配额记账" 1

echo ""
echo "== 2) 零外发核对：请求只发到本地，且外发日志如实记录 =="
grep -q "STUB_REQ model=qwen2.5:7b auth=None" /tmp/doyah-stub.log \
    && check "假端点收到的请求没有 Authorization 头（本地免 Key 是真的）" 0 \
    || { check "请求不带 Authorization" 1; head -2 /tmp/doyah-stub.log; }
echo "$OUT" | grep -q "agentModel → http://127.0.0.1:${PORT}" \
    && check "外发日志里的目标就是本地端点（agentModel → http://127.0.0.1:${PORT}）" 0 \
    || { check "外发日志目标应指向本地端点" 1; echo "$OUT" | grep "外发日志" -A 3; }

echo ""
echo "== 3) 反向核对：**总开关关闭时一个请求都不发**（NFR-AI-02 / AC-AI-01）=="
BEFORE=$(grep -c "STUB_REQ" /tmp/doyah-stub.log || true)
OUT2="$("$CLI" agent-sql --endpoint "http://127.0.0.1:${PORT}/v1" --model "qwen2.5:7b" --disabled "找出最近 7 天的订单" 2>&1)"
AFTER=$(grep -c "STUB_REQ" /tmp/doyah-stub.log || true)
[ "$BEFORE" = "$AFTER" ] && check "假端点没有收到任何新请求（$BEFORE → ${AFTER}）" 0 \
    || check "关闭总开关后仍发了请求（$BEFORE → ${AFTER}）" 1
echo "$OUT2" | grep -qi "生成失败" && check "失败时有可读提示" 0 || { check "失败提示" 1; echo "$OUT2" | head -3; }
echo "$OUT2" | grep -qi "关闭\|disabled\|未开启" && check "原因指向总开关关闭（而不是网络失败）" 0 \
    || { check "原因指向总开关" 1; echo "$OUT2" | tail -2; }

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：本地端点全流程可用、免 Key、零外发，且外发日志如实记录"
else
    echo "有失败项，见上"
fi
exit "$fail"
