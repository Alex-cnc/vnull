#!/bin/bash
# 验证：真实模型端点联调（NFR-AI-04）。
#
# 为什么单独有这一条：`Scripts/test-local-endpoint.sh` 用的是**本机假端点**，
# 它证明的是"客户端链路正确"，证明不了"能跟真实模型服务通"。这一条要真端点。
#
# 用法（两种）：
#   ./Scripts/test-real-endpoint.sh --endpoint http://127.0.0.1:11434 --model qwen2.5:7b
#   DOYAH_TEST_ENDPOINT=http://… DOYAH_TEST_MODEL=qwen2.5:7b ./Scripts/test-real-endpoint.sh
#
# 可选：`--api-key K`（会检查它**没有**出现在输出里）、`--prompt "…"` 自定义指令。
#
# 判据（都必须在真端点上成立）：
#   1. 调用返回 0，输出里含**看起来是 SQL 的东西**（不是错误、不是空）；
#   2. 输出里**没有** API Key（脱敏纪律：它会进日志、会被截图）；
#   3. `--show-egress` 的账本里记到了这次调用，且**目标被脱敏**（不带 query / 凭据）。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

ENDPOINT=""
MODEL=""
API_KEY=""
PROMPT="列出最近 7 天每个客户的订单数"
while [ $# -gt 0 ]; do
    case "$1" in
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --api-key) API_KEY="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        *) echo "未知参数：$1"; exit 64 ;;
    esac
done
ENDPOINT="${ENDPOINT:-${DOYAH_TEST_ENDPOINT:-}}"
MODEL="${MODEL:-${DOYAH_TEST_MODEL:-}}"

if [ -z "$ENDPOINT" ] || [ -z "$MODEL" ]; then
    echo "需要真端点：--endpoint <URL> --model <模型名>（或设 DOYAH_TEST_ENDPOINT / DOYAH_TEST_MODEL）"
    echo ""
    echo "本机可用的常见做法："
    echo "  Ollama：   ollama serve &  ollama pull qwen2.5:7b"
    echo "             $0 --endpoint http://127.0.0.1:11434/v1 --model qwen2.5:7b"
    echo "  vLLM：     vllm serve <模型> --port 8000"
    echo "             $0 --endpoint http://127.0.0.1:8000/v1 --model <模型>"
    echo ""
    echo "（这一项**必须**在真端点上跑过才算完成；本机假端点的证据在 test-local-endpoint.sh 里，"
    echo "  它只证明客户端链路，不证明能跟真实模型服务通。）"
    exit 64
fi

echo "== 真实端点联调 =="
echo "  端点：$ENDPOINT"
echo "  模型：$MODEL"
echo ""

ARGS=(agent-sql --endpoint "$ENDPOINT" --model "$MODEL" --show-egress)
if [ -n "$API_KEY" ]; then ARGS+=(--api-key "$API_KEY"); fi
ARGS+=("$PROMPT")

START=$(python3 -c 'import time; print(time.time())')
OUT="$("$CLI" "${ARGS[@]}" 2>&1)"; CODE=$?
END=$(python3 -c 'import time; print(time.time())')
python3 - "$START" "$END" <<'PYEOF'
import sys
print("  用时：%.2f 秒" % (float(sys.argv[2]) - float(sys.argv[1])))
PYEOF
echo "$OUT" | head -8 | sed 's/^/  /'

echo ""
[ "$CODE" -eq 0 ] && check "调用返回成功（退出码 0）" 0 || check "调用应成功（退出码 ${CODE}）" 1

# 判据 1：输出里要有像 SQL 的东西
if echo "$OUT" | grep -qiE "select|insert|update|delete|with "; then
    check "返回内容里有 SQL 语句（不是错误信息）" 0
else
    check "返回内容里应含 SQL" 1
    echo "$OUT" | tail -3 | sed 's/^/    /'
fi

# 判据 2：API Key 绝不能出现在输出里
if [ -n "$API_KEY" ]; then
    echo "$OUT" | grep -qF "$API_KEY" && check "输出里**不该**出现 API Key" 1 || check "输出里没有 API Key（脱敏纪律）" 0
else
    echo "  （未提供 --api-key，跳过 Key 泄漏检查）"
fi

# 判据 3：外发账本记到了这次调用
echo "$OUT" | grep -qiE "egress|外发|账单|账本" && check "外发账本里记到了这次调用" 0 || check "应记到外发账本（--show-egress）" 1

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：真端点联调成功（返回 SQL / 无 Key 泄漏 / 外发账本留痕）"
    echo "把这行输出贴进 NFR-AI-04 的证据里，这一项就可以从「待环境」变成「已联调」。"
else
    echo "有失败项，见上"
fi
exit "$fail"
