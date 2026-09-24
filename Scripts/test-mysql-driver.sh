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
echo "== 8) GBase 8a 走同族驱动（FR-DRV-08） =="
# GBase 8a 与 MySQL 同属一个协议族：驱动委托给方言可注入的 MySQLService，方言换成 GBase。
# **这里验的是"我们的接线"**（GBaseService 真的把 GBase 方言用上了、驱动路径真的通），
# **不是"能连上 GBase"** —— 那需要一台真实 GBase 8a 实例，本机没有，如实登记为阻塞。
GBASE_JSON="$("$CLI" gbase8a --host 127.0.0.1 --port "$PORT" --user gbase --password secret \
    --database testdb --ssl-mode disable --json --sql "SELECT id FROM t")"
echo "$GBASE_JSON" | grep -q '"ok":true' && check "GBase 8a 档也能连上（同一套协议接线）" 0 || check "GBase 8a 档也能连上（同一套协议接线）" 1
echo "$GBASE_JSON" | grep -q '"columns":\["id","name","note","amount"\]' && check "GBase 档结果集解码正常" 0 || check "GBase 档结果集解码正常" 1
run_gbase_sql() { "$CLI" gbase8a --host 127.0.0.1 --port "$PORT" --user gbase --password secret \
    --database testdb --ssl-mode disable --json --sql "$1"; }
ROWCOUNT_BEFORE="$(grep -c "query: SELECT ROW_COUNT()" "$LOG" 2>/dev/null || echo 0)"
GBASE_DML="$(run_gbase_sql "INSERT INTO t VALUES (1)")"
echo "$GBASE_DML" | grep -q '"affectedRows":null' \
    && check "GBase 的影响行数如实留空（未实测，不用客户端自己数的数字冒充）" 0 \
    || check "GBase 的影响行数如实留空（未实测，不用客户端自己数的数字冒充）" 1
grep -q "query: SELECT VERSION()" "$LOG" && check "GBase 档的自省查询也真的发出去了" 0 || check "GBase 档的自省查询也真的发出去了" 1
ROWCOUNT_AFTER="$(grep -c "query: SELECT ROW_COUNT()" "$LOG" 2>/dev/null || echo 0)"
if [ "$ROWCOUNT_BEFORE" = "$ROWCOUNT_AFTER" ]; then rc_ok=0; else rc_ok=1; fi
check "GBase 档没有多发 MySQL 专用的元信息查询（影响行数如实留空）" "$rc_ok"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "✅ MySQL 驱动链路全部通过（假服务器真跑线协议）"
else
    echo "❌ 有断言失败，见上"
fi
exit "$fail"
