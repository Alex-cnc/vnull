#!/bin/bash
# FR-DRV-09 MySQL 驱动的可复跑证据。
#
# **这一套验的是"我们这一侧的接线"**：认证握手之后的语句下发、结果集解码（中文 / NULL / 空串 /
# 引号 / 转义）、影响行数、事务语句、错误包变成可读错误。用的是一台**假 MySQL 服务器**
# （`Scripts/mysql-stub/fake_mysql_server.py`，真跑 MySQL 线协议）。
#
# **没验什么（如实写）**：真实 MySQL 实例上的认证（caching_sha2_password / TLS）、
# 真实的数据类型二进制形态、prepared statement、字符集协商、取消（`KILL QUERY` 的下发路径）。
# 那些需要一台真实例：`Scripts/test-mysql-real.sh`（需要时跑）。
#
# 用法：./Scripts/test-mysql-driver.sh
set -uo pipefail

cd "$(dirname "$0")/.."
CLI=".build/debug/DoyahCLI"
PORT=33091
LOG="$PWD/.build/fake-mysql-$$.log"
SERVER_PID=""

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

echo "== 0) 构建 CLI =="
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"
if swift build --disable-sandbox --cache-path "$PWD/.build-cache" --scratch-path "$PWD/.build" \
    --manifest-cache local -Xswiftc -disable-sandbox --product DoyahCLI > .build/mysql-build.log 2>&1; then
    check "CLI 构建成功" 0
else
    check "CLI 构建成功" 1
    tail -5 .build/mysql-build.log
    exit 1
fi

echo ""
echo "== 1) 起假 MySQL 服务器（真跑线协议） =="
rm -f "$LOG"
python3 Scripts/mysql-stub/fake_mysql_server.py --port "$PORT" --log "$LOG" &
SERVER_PID=$!
for _ in $(seq 1 30); do
    grep -q "listening" "$LOG" 2>/dev/null && break
    sleep 0.2
done
if grep -q "listening" "$LOG" 2>/dev/null; then
    check "假服务器已在 127.0.0.1:$PORT 上监听" 0
else
    check "假服务器已在 127.0.0.1:$PORT 上监听" 1
    exit 1
fi

run_mysql() { "$CLI" mysql --host 127.0.0.1 --port "$PORT" --user root --password secret \
    --database testdb --ssl-mode disable --json "$@"; }

echo ""
echo "== 2) 连接与自省（版本 / 当前库 / 当前用户） =="
CONNECT_JSON="$(run_mysql)"
connect_ok=1
echo "$CONNECT_JSON" | grep -q '"ok":true' && connect_ok=0
check "连接成功（ok:true）" "$connect_ok"
echo "$CONNECT_JSON" | grep -q '"version":"8.0.36-fake"' && v=0 || v=1
check "版本读到了（SELECT VERSION()）" "$v"
echo "$CONNECT_JSON" | grep -q '"database":"testdb"' && d=0 || d=1
check "当前库读到了（SELECT DATABASE()）" "$d"
echo "$CONNECT_JSON" | grep -q '"user":"root@localhost"' && u=0 || u=1
check "当前用户读到了（SELECT CURRENT_USER()）" "$u"

echo ""
echo "== 3) 结果集解码（中文 / NULL / 空串 / 引号 / 转义） =="
SELECT_JSON="$(run_mysql --sql "SELECT id, name, note, amount FROM t")"
echo "$SELECT_JSON" | grep -q '"columns":\["id","name","note","amount"\]' && c=0 || c=1
check "列名与顺序正确" "$c"
echo "$SELECT_JSON" | grep -q '"客户甲"' && zh=0 || zh=1
check "中文值原样（客户甲）" "$zh"
echo "$SELECT_JSON" | grep -q '"rows":\[\["1","客户甲","NULL","12"\]' && n=0 || n=1
check "NULL 与空串分得开（第一行 note 是 NULL）" "$n"
echo "$SELECT_JSON" | grep -q '\["2","","空串与 NULL 必须分得开"' && e=0 || e=1
check "空串仍是空串（第二行 name 为空）" "$e"
echo "$SELECT_JSON" | grep -q "it's quoted" && q=0 || q=1
check "单引号原样（it's quoted）" "$q"
echo "$SELECT_JSON" | grep -q '"affectedRows":null' && a=0 || a=1
check "有结果集的语句不报影响行数（affectedRows 为 null）" "$a"
echo "$SELECT_JSON" | grep -q '3 行\|}\s*$' && r=0 || r=1
check "JSON 可被解析（以 } 收尾、无多余输出）" "$r"

echo ""
echo "== 4) 影响行数（走 ROW_COUNT()，不是自己数行） =="
INSERT_JSON="$(run_mysql --sql "INSERT INTO t VALUES (1)")"
echo "$INSERT_JSON" | grep -q '"affectedRows":3' && i=0 || i=1
check "INSERT 的影响行数是服务端给的 3" "$i"

echo ""
echo "== 5) 事务语句（START TRANSACTION / COMMIT） =="
run_mysql --sql "START TRANSACTION" >/dev/null 2>&1 && t1=0 || t1=1
check "START TRANSACTION 成功" "$t1"
run_mysql --sql "COMMIT" >/dev/null 2>&1 && t2=0 || t2=1
check "COMMIT 成功" "$t2"

echo ""
echo "== 6) 错误路径（服务端 ERR 包要变成可读错误、退出码非零） =="
ERROR_JSON="$(run_mysql --sql "SELECT * FROM missing_table")"
if [ $? -ne 0 ]; then ec=0; else ec=1; fi
check "语句出错时退出码非零" "$ec"
echo "$ERROR_JSON" | grep -q '"ok":false' && eo=0 || eo=1
check "错误以 ok:false 报出" "$eo"
echo "$ERROR_JSON" | grep -qi "missing" && em=0 || em=1
check "错误信息里带着服务端说的话" "$em"

echo ""
echo "== 7) 假服务器侧看到的语句（证明真的发过去了，而不是本地假装） =="
grep -q "query: SELECT id, name, note, amount FROM t" "$LOG" && s1=0 || s1=1
check "服务器收到了那条 SELECT" "$s1"
grep -q "query: INSERT INTO t VALUES (1)" "$LOG" && s2=0 || s2=1
check "服务器收到了那条 INSERT" "$s2"
grep -q "query: SELECT ROW_COUNT(), LAST_INSERT_ID()" "$LOG" && s3=0 || s3=1
check "影响行数是问服务端要的（ROW_COUNT()）" "$s3"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ MySQL 驱动链路全部通过（假服务器真跑线协议）"
else
    echo "❌ 有断言失败，见上"
fi
exit "$fail"
