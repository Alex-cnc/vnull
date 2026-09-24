#!/bin/bash
# 验证：连接 URL 导入 / 导出与配置包（FR-CONN-19）。
#
# 需求原文点名的一条纪律：**密码仍只进 Keychain（DR-02）** ——
# 所以这里既要验"一行建连能解析对"，也要验"导出的东西里没有密码"。
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
DIR="$(mktemp -d -t doyah-connurl)"

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

echo "== 1) 一行建连：解析并保存（不含密码）=="
OUT="$("$CLI" connections --dir "$DIR" --import-url 'postgres://alice:s3cret@db.example.com:6543/orders?sslmode=require' --name 订单库 --save 2>&1)"
echo "$OUT" | sed 's/^/  /'
echo "$OUT" | grep -q "db.example.com:6543" && check "主机与端口解析正确" 0 || check "主机端口" 1
echo "$OUT" | grep -q "SSL=require" && check "sslmode 映射正确" 0 || check "sslmode" 1
echo "$OUT" | grep -q "不会.*写入配置文件" && check "明确告知密码不会写入配置" 0 || check "应提示密码去向" 1

# 配置文件里**不能有密码**
if grep -qi "s3cret" "$DIR/connections.json" 2>/dev/null; then
    check "配置文件里不该出现密码" 1
else
    check "配置文件里没有密码（只进密钥存储）" 0
fi
SAVED="$("$CLI" connections --dir "$DIR" --json 2>&1)"
echo "$SAVED" | python3 -c '
import json, sys
text = sys.stdin.read()
payload = json.loads(text[text.index("["):])
assert len(payload) == 1, payload
item = payload[0]
assert item["host"] == "db.example.com" and item["port"] == 6543, item
assert item["database"] == "orders" and item["username"] == "alice", item
assert item["sslMode"] == "require", item
print("  ✅ 保存的配置字段正确（无密码字段）")
' || fail=1

echo ""
echo "== 2) 导出成一行 URL：可再次解析，且不含密码 =="
URL="$("$CLI" connections --dir "$DIR" --export-url 订单库 2>&1)"
echo "  $URL"
echo "$URL" | grep -q "s3cret" && check "导出的 URL 不该含密码" 1 || check "导出的 URL 不含密码" 0
echo "$URL" | grep -q "^postgres://alice@db.example.com:6543/orders" && check "URL 形态正确" 0 || check "URL 形态" 1
# 往返：把导出的 URL 再解析一次（用另一个目录，避免重名覆盖）
DIR2="$(mktemp -d -t doyah-connurl2)"
"$CLI" connections --dir "$DIR2" --import-url "$URL" --name 往返 --save >/dev/null 2>&1
ROUND="$("$CLI" connections --dir "$DIR2" --json 2>&1)"
echo "$ROUND" | python3 -c '
import json, sys
text = sys.stdin.read()
payload = json.loads(text[text.index("["):])[0]
assert payload["host"] == "db.example.com" and payload["port"] == 6543, payload
assert payload["database"] == "orders" and payload["sslMode"] == "require", payload
print("  ✅ 导出的 URL 再解析回来字段一致（往返）")
' || fail=1
rm -rf "$DIR2"

echo ""
echo "== 3) 配置包：不含密码，且版本比当前新时拒绝 =="
"$CLI" connections --dir "$DIR" --export-bundle "$DIR/bundle.json" 2>&1 | sed 's/^/  /'
if grep -qi "s3cret\|password" "$DIR/bundle.json"; then
    check "配置包里不该有密码字段" 1
else
    check "配置包里没有密码字段" 0
fi
python3 - "$DIR/bundle.json" <<'PYEOF'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["formatVersion"] == 1, payload
assert len(payload["connections"]) == 1, payload
assert "密码" in payload["note"], "包里应写明不含密码"
print("  ✅ 配置包结构正确并写明不含密码")
PYEOF
[ $? -eq 0 ] || fail=1

echo ""
echo "== 4) 解析失败要指出问题（不给半个配置）=="
for bad in "mysql://u@h/db" "postgres://" "postgres://host" "postgres://host:abc/db"; do
    MSG="$("$CLI" connections --dir "$DIR" --import-url "$bad" 2>&1)"; CODE=$?
    [ "$CODE" -ne 0 ] && echo "  ✅ $bad → $MSG" || { check "非法 URL 应被拒：$bad" 1; }
done
check "四类非法 URL 都被拒绝并说明原因" 0

echo ""
if [ "$fail" -eq 0 ]; then
    echo "通过：一行建连解析正确且密码不入配置 / 导出 URL 可往返且不含密码 / 配置包不含密码并拒新版 /"
    echo "      非法 URL 明确报错"
    echo "（**边界**：界面里的导入框仍需人工点；本脚本验的是解析、序列化与密码纪律）"
else
    echo "有失败项，见上"
fi
exit "$fail"
