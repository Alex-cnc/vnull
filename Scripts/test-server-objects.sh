#!/bin/bash
# 验证：服务器级对象管理（FR-SESS-03）在**真库**上的行为。
#
# 这一项的核心是「说的话要算数」，所以脚本不靠单测的假结果：
#   ① 列出角色 —— 能找到当前用户（查询就是 Core 里那条 pg_roles 查询）
#   ② 建一个一次性角色 doyah_ss3_probe → 改它 → 删掉；每步都真跑 SQL，
#      并回查 pg_roles / pg_authid 核对「登录开关变了、口令真的换了、最后真的没了」
#   ③ 列出扩展 —— 至少能看到 plpgsql
#   ④ CREATE EXTENSION：找一个可用但还没装的扩展（pg_stat_statements → vector）走成功路径
#      （并收尾删掉）；另外**总是**跑一次「重复创建 plpgsql」，确认服务端错误被如实报出来
#   ⑤ 表空间：只读列出（**不 CREATE** —— 那需要超级用户加真实磁盘目录，容易污染机器）
#   ⑥ 无论中途是否失败，trap 里都清掉自己建的角色与扩展
#   ⑦ 用**新的 CLI 子命令**（`DoyahCLI server-objects …`）再走一遍：列表 / --json /
#      dry-run 不写库 / --yes 真建 / 注入名被拒 / 方言不支持时不发 SQL / --yes 真删
#
# 关于 SQL 的来源：第 1–7 节直接跑 SQL，是为了在**没有 CLI 子命令**时也能验 Core 的查询与语句；
# 第 0 节用 python 把抄来的 SQL 与 Core/ServerObjects.swift 里的原文逐字对账，防止两边漂移。
# 第 8 节起走 CLI 子命令 —— 那条路径同时验到 CLI 的参数解析与 Core 的规划（不抄 SQL）。
#
# 纪律：本机没有 `timeout`，不用；不用 `pgrep -c`（无效）；CJK 紧邻变量一律写 ${VAR}。
set -uo pipefail

cd "$(dirname "$0")/.."

# ── 自己的 scratch 目录优先；退回到主线 .build —— 脚本要能独立复跑 ──
CLI="${DOYAH_CLI:-}"
if [ -z "${CLI}" ]; then
    for candidate in ".build-agent-ss3/debug/DoyahCLI" ".build/debug/DoyahCLI"; do
        if [ -x "${candidate}" ]; then CLI="${candidate}"; break; fi
    done
fi
if [ -z "${CLI}" ] || [ ! -x "${CLI}" ]; then
    echo "❌ 找不到 DoyahCLI（先构建，或用 DOYAH_CLI 指定路径）"
    exit 1
fi

# Apple Silicon 上内核要求可执行文件至少有 ad-hoc 签名：未签名的 arm64 二进制一执行就被杀掉
# （Killed: 9，退出码 137，且没有任何输出）。本轮实测 scratch 目录里的产物是未签名的
# （主线 .build 里那份是签过的）—— 这里就地补签，免得把"环境问题"误报成"断言失败"。
if ! codesign -dv "${CLI}" >/dev/null 2>&1; then
    echo "  · CLI 未签名，就地补 ad-hoc 签名：${CLI}"
    codesign --force --sign - "${CLI}" >/dev/null 2>&1
fi

# 连接信息（本机过渡集群 / 远程专用库）由共用入口决定 —— 三档端口与目录只写在它里面
source "$(cd "$(dirname "$0")" && pwd)/lib/test-env.sh"
doyah_test_env_summary

PGBIN="${DOYAH_TEST_PG_BIN}"
DATADIR="${DOYAH_TEST_LOCAL_DATADIR}"
PORT="${DOYAH_TEST_PGPORT}"
PROBE="doyah_ss3_probe"           # 一次性角色：带脚本前缀，不会撞上别人的对象
PROBE_PW="ss3_probe_pw"
PROBE_PW2="ss3_probe_pw2"
# CLI 子命令那一节用**另一个**名字：它验的是"CLI 真建 / 真删"，与上面的内联 SQL 一节互不干扰，
# 也避免两节共用同一个角色时把彼此的断言搞乱。
CLI_PROBE="doyah_ss3_cli_probe"
CLI_PROBE_PW="ss3_cli_probe_pw"
STARTED=0
READY=0

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
assert_eq() {  # 描述 期望 实际
    if [ "$2" = "$3" ]; then
        echo "  ✅ $1"
    else
        echo "  ❌ $1：期望 [${2}]，实际 [${3}]"
        fail=1
    fi
}
assert_ok() {  # 描述 退出码 输出
    if [ "$2" = "0" ]; then
        echo "  ✅ $1"
    else
        echo "  ❌ $1：期望退出码 0，实际 [${2}]；输出尾部：$(printf '%s' "$3" | tail -3 | tr '\n' ' ')"
        fail=1
    fi
}
assert_contains() {  # 描述 期望子串 实际文本
    case "$3" in
        *"$2"*) echo "  ✅ $1" ;;
        *) echo "  ❌ $1：期望包含 [${2}]，实际 [$(printf '%s' "$3" | head -3 | tr '\n' ' ')]"; fail=1 ;;
    esac
}

psql_q() {  # 只跑一条幂等 / 只读语句，返回单值
    PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}

cleanup() {
    # 清账要**无条件**做：中途失败留下的角色会让下一次复跑卡在「角色已存在」。
    if [ "${READY}" = "1" ]; then
        PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
            "DROP ROLE IF EXISTS ${PROBE};" >/dev/null 2>&1
        PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
            "DROP ROLE IF EXISTS ${CLI_PROBE};" >/dev/null 2>&1
        PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
            "DROP EXTENSION IF EXISTS pg_stat_statements;" >/dev/null 2>&1
        PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" "$PGBIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
            "DROP EXTENSION IF EXISTS vector;" >/dev/null 2>&1
    fi
    [ "${STARTED}" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────
# 三条查询：与 Core/ServerObjects.swift 里 ServerObjects 生成的文本一致
# ─────────────────────────────────────────────────────────────
ROLE_SQL="SELECT r.rolname AS name,
       r.rolcanlogin AS can_login,
       r.rolsuper AS is_superuser,
       pg_catalog.shobj_description(r.oid, 'pg_authid') AS comment
FROM pg_catalog.pg_roles r
ORDER BY r.rolname
LIMIT 200"

TABLESPACE_SQL="SELECT t.spcname AS name,
       pg_catalog.pg_get_userbyid(t.spcowner) AS owner,
       pg_catalog.pg_tablespace_location(t.oid) AS location,
       pg_catalog.pg_tablespace_size(t.oid) AS bytes,
       pg_catalog.shobj_description(t.oid, 'pg_tablespace') AS comment
FROM pg_catalog.pg_tablespace t
ORDER BY t.spcname
LIMIT 200"

EXTENSION_SQL="SELECT e.extname AS name,
       e.extversion AS version,
       n.nspname AS schema,
       pg_catalog.pg_get_userbyid(e.extowner) AS owner,
       pg_catalog.obj_description(e.oid, 'pg_extension') AS comment
FROM pg_catalog.pg_extension e
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname
LIMIT 200"

echo "== 0) 脚本里的 SQL 与 Core/ServerObjects.swift 对账（防止两边漂移）=="
export SS3_ROLE_SQL="${ROLE_SQL}"
export SS3_TABLESPACE_SQL="${TABLESPACE_SQL}"
export SS3_EXTENSION_SQL="${EXTENSION_SQL}"
python3 - <<'PYEOF'
import os, pathlib, re, sys
source = pathlib.Path("Core/ServerObjects.swift").read_text(encoding="utf-8")

def norm(text):
    return re.sub(r"\s+", " ", text).strip()

# Core 里的上限是 \(bounded) 插值，所以只比 LIMIT 之前的部分（那才是「查什么」的契约）。
def head(text):
    return re.split(r"\s+LIMIT\s+", norm(text))[0]

source_head = norm(source)
ok = True
for label in ("ROLE", "TABLESPACE", "EXTENSION"):
    sql = head(os.environ["SS3_" + label + "_SQL"])
    if sql and sql in source_head:
        print("  ✅ %s_SQL 与 Core 里生成的文本逐字一致（空白归一后）" % label)
    else:
        print("  ❌ %s_SQL 与 Core/ServerObjects.swift 不一致：\n      %s" % (label, sql))
        ok = False
sys.exit(0 if ok else 1)
PYEOF
[ $? -eq 0 ] || fail=1

echo ""
echo "== 1) 起本机临时集群（端口 ${PORT}）=="
if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    echo "  · 初始化临时集群 ${DATADIR}"
    mkdir -p "${DATADIR}"
    "$PGBIN/initdb" -D "${DATADIR}" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1 \
        || { echo "  ❌ initdb 失败"; exit 1; }
fi
if ! "$PGBIN/pg_ctl" -D "${DATADIR}" status >/dev/null 2>&1; then
    "$PGBIN/pg_ctl" -D "${DATADIR}" -o "-p ${PORT} -k /tmp" -l /tmp/doyah-ss3-pg.log start >/dev/null 2>&1
    STARTED=1
    sleep 2
fi
if "$PGBIN/pg_ctl" -D "${DATADIR}" status >/dev/null 2>&1; then
    check "临时实例在跑（端口 ${PORT}）" 0
    READY=1
else
    check "临时实例在跑（端口 ${PORT}）" 1
    echo "  日志尾部："
    tail -5 /tmp/doyah-ss3-pg.log 2>/dev/null | sed 's/^/    /'
    echo "有失败项，见上"
    exit 1
fi

# CLI 从环境变量取连接参数（默认端口是 5432，必须显式指到临时集群）。
export PGHOST="${DOYAH_TEST_PGHOST}" PGPORT="${PORT}" PGUSER="${DOYAH_TEST_PGUSER}" PGPASSWORD="${DOYAH_TEST_PGPASSWORD}" PGDATABASE="${DOYAH_TEST_ADMIN_DB}"

echo "  · 用 CLI：${CLI}"
SERVER_VERSION="$(psql_q 'SHOW server_version;')"
echo "  · 服务端版本：${SERVER_VERSION}"

echo ""
echo "== 2) 列出角色：能找到当前用户（Core 里那条 pg_roles 查询）=="
ROLE_OUT="$("${CLI}" -c "${ROLE_SQL}" 2>&1)"
echo "${ROLE_OUT}" | grep -q "name:" && check "查询返回了 name 列" 0 \
    || { check "查询返回 name 列" 1; echo "${ROLE_OUT}" | tail -3; }
echo "${ROLE_OUT}" | grep -qE "^postgres \|" && check "当前用户 postgres 出现在角色列表里" 0 \
    || { check "当前用户 postgres 应出现在角色列表里" 1; echo "${ROLE_OUT}" | tail -5; }
assert_eq "pg_roles 里确实有 current_user" "1" "$(psql_q "SELECT count(*) FROM pg_roles WHERE rolname = current_user;")"

echo ""
echo "== 3) 一次性角色 ${PROBE}：建 → 改 → 删（每步都回查 pg_roles）=="
psql_q "DROP ROLE IF EXISTS ${PROBE};" >/dev/null
CREATE_SQL="CREATE ROLE \"${PROBE}\" WITH LOGIN PASSWORD '${PROBE_PW}'"
CREATE_OUT="$("${CLI}" -c "${CREATE_SQL}" 2>&1)"
CREATE_CODE=$?
assert_ok "CREATE ROLE 执行成功" "${CREATE_CODE}" "${CREATE_OUT}"
assert_eq "pg_roles 里 rolcanlogin = t（真的可登录）" "t" \
    "$(psql_q "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${PROBE}';")"
HASH_BEFORE="$(psql_q "SELECT rolpassword FROM pg_authid WHERE rolname = '${PROBE}';")"
[ -n "${HASH_BEFORE}" ] && check "pg_authid 里存了口令（非空）" 0 || check "pg_authid 里应存有口令" 1
LIST_AFTER_CREATE="$("${CLI}" -c "${ROLE_SQL}" 2>&1)"
echo "${LIST_AFTER_CREATE}" | grep -q "${PROBE}" && check "新角色出现在角色列表里（浏览 → 写 → 复览 闭环）" 0 \
    || { check "新角色应出现在角色列表里" 1; echo "${LIST_AFTER_CREATE}" | tail -5; }

ALTER_SQL="ALTER ROLE \"${PROBE}\" WITH NOLOGIN PASSWORD '${PROBE_PW2}'"
ALTER_OUT="$("${CLI}" -c "${ALTER_SQL}" 2>&1)"
ALTER_CODE=$?
assert_ok "ALTER ROLE 执行成功" "${ALTER_CODE}" "${ALTER_OUT}"
assert_eq "改完 rolcanlogin = f（登录开关真的变了）" "f" \
    "$(psql_q "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${PROBE}';")"
HASH_AFTER="$(psql_q "SELECT rolpassword FROM pg_authid WHERE rolname = '${PROBE}';")"
if [ -n "${HASH_AFTER}" ] && [ "${HASH_AFTER}" != "${HASH_BEFORE}" ]; then
    check "改完口令哈希变了（口令真的换了，不是只改了开关）" 0
else
    check "改完口令哈希应当变化" 1
fi

DROP_SQL="DROP ROLE \"${PROBE}\""
DROP_OUT="$("${CLI}" -c "${DROP_SQL}" 2>&1)"
DROP_CODE=$?
assert_ok "DROP ROLE 执行成功" "${DROP_CODE}" "${DROP_OUT}"
assert_eq "pg_roles 里已经没有 ${PROBE}" "0" \
    "$(psql_q "SELECT count(*) FROM pg_roles WHERE rolname = '${PROBE}';")"

echo ""
echo "== 4) 列出扩展：至少能看到 plpgsql =="
EXT_OUT="$("${CLI}" -c "${EXTENSION_SQL}" 2>&1)"
echo "${EXT_OUT}" | grep -q "plpgsql" && check "扩展列表里有 plpgsql" 0 \
    || { check "扩展列表里应有 plpgsql" 1; echo "${EXT_OUT}" | tail -5; }
assert_eq "pg_extension 里 plpgsql 计数为 1" "1" \
    "$(psql_q "SELECT count(*) FROM pg_extension WHERE extname = 'plpgsql';")"

echo ""
echo "== 5) CREATE EXTENSION：成功路径 + 错误必须被如实报出 =="
# 成功路径需要一个"可用但还没装"的扩展：优先 pg_stat_statements；本机没装它时退到 vector
# （PG 16.2 + pgvector）。两个都没有时只验错误路径 —— 如实打印这一点，不假装验过。
TEST_EXT=""
for candidate in pg_stat_statements vector; do
    if [ "$(psql_q "SELECT count(*) FROM pg_available_extensions WHERE name = '${candidate}';")" = "1" ]; then
        TEST_EXT="${candidate}"
        break
    fi
done
if [ -n "${TEST_EXT}" ]; then
    psql_q "DROP EXTENSION IF EXISTS ${TEST_EXT};" >/dev/null
    EXT_CREATE_OUT="$("${CLI}" -c "CREATE EXTENSION \"${TEST_EXT}\"" 2>&1)"
    EXT_CREATE_CODE=$?
    assert_ok "CREATE EXTENSION ${TEST_EXT} 成功" "${EXT_CREATE_CODE}" "${EXT_CREATE_OUT}"
    assert_eq "pg_extension 里出现了 ${TEST_EXT}" "1" \
        "$(psql_q "SELECT count(*) FROM pg_extension WHERE extname = '${TEST_EXT}';")"
    EXT_DROP_OUT="$("${CLI}" -c "DROP EXTENSION \"${TEST_EXT}\"" 2>&1)"
    EXT_DROP_CODE=$?
    assert_ok "DROP EXTENSION ${TEST_EXT} 成功" "${EXT_DROP_CODE}" "${EXT_DROP_OUT}"
    assert_eq "收尾后 ${TEST_EXT} 已删除" "0" \
        "$(psql_q "SELECT count(*) FROM pg_extension WHERE extname = '${TEST_EXT}';")"
else
    echo "  · 本实例既没有 pg_stat_statements 也没有 vector 可装，只验错误路径"
fi
# 无论上面走哪条路，都验一次「重复创建」：服务端报错必须原样透出，不能吞掉。
DUP_OUT="$("${CLI}" -c "CREATE EXTENSION \"plpgsql\"" 2>&1)"
DUP_CODE=$?
if [ "${DUP_CODE}" -ne 0 ]; then
    check "重复创建 plpgsql 被服务端拒绝（CLI 退出码 ${DUP_CODE}）" 0
else
    check "重复创建 plpgsql 应当失败" 1
fi
assert_contains "错误信息被如实报出（already exists）" "already exists" "${DUP_OUT}"

echo ""
echo "== 6) 表空间：只读列出（不 CREATE，避免污染机器）=="
TS_OUT="$("${CLI}" -c "${TABLESPACE_SQL}" 2>&1)"
echo "${TS_OUT}" | grep -q "pg_default" && check "表空间列表里有 pg_default" 0 \
    || { check "表空间列表里应有 pg_default" 1; echo "${TS_OUT}" | tail -5; }
echo "${TS_OUT}" | grep -q "location" && check "列表带上了磁盘目录（location 列）" 0 \
    || { check "列表应带 location 列" 1; echo "${TS_OUT}" | head -3; }
TS_COUNT="$(psql_q "SELECT count(*) FROM pg_tablespace;")"
if [ -n "${TS_COUNT}" ] && [ "${TS_COUNT}" -ge 2 ]; then
    check "pg_tablespace 至少有 2 个（pg_default / pg_global）" 0
else
    echo "  ❌ pg_tablespace 至少应有 2 个，实际 [${TS_COUNT}]"
    fail=1
fi

echo ""
echo "== 7) 复跑安全性：再删一次同一角色应当是「无所谓」而不是报错 =="
psql_q "DROP ROLE IF EXISTS ${PROBE};" >/dev/null
assert_eq "DROP ROLE IF EXISTS 二次执行后角色仍不存在" "0" \
    "$(psql_q "SELECT count(*) FROM pg_roles WHERE rolname = '${PROBE}';")"

echo ""
echo "== 8) 用新的 CLI 子命令再走一遍（列表 → --json → dry-run → 真建 → 真删）=="
echo "  · 这一节不抄 SQL：语句由 \`server-objects\` 自己生成，CLI 的参数解析与 Core 的规划一起被验到"
psql_q "DROP ROLE IF EXISTS ${CLI_PROBE};" >/dev/null

# 8.1 三类列表 + --json
CLI_ROLES="$("${CLI}" server-objects roles 2>&1)"
assert_ok "CLI server-objects roles 执行成功" "$?" "${CLI_ROLES}"
assert_contains "CLI 角色列表里有当前用户 postgres" "postgres" "${CLI_ROLES}"
CLI_TS="$("${CLI}" server-objects tablespaces 2>&1)"
assert_ok "CLI server-objects tablespaces 执行成功" "$?" "${CLI_TS}"
assert_contains "CLI 表空间列表里有 pg_default" "pg_default" "${CLI_TS}"
CLI_EXT="$("${CLI}" server-objects extensions 2>&1)"
assert_ok "CLI server-objects extensions 执行成功" "$?" "${CLI_EXT}"
assert_contains "CLI 扩展列表里有 plpgsql" "plpgsql" "${CLI_EXT}"
CLI_JSON="$("${CLI}" server-objects roles --json 2>&1)"
assert_contains "CLI --json 给出结构化清单（sections）" "\"sections\"" "${CLI_JSON}"

# 8.2 dry-run：打印语句，但**一个字都不写库**
DRY_OUT="$("${CLI}" server-objects create-role --name "${CLI_PROBE}" --password "${CLI_PROBE_PW}" 2>&1)"
assert_ok "CLI create-role 默认 dry-run 成功" "$?" "${DRY_OUT}"
assert_contains "dry-run 打印了将要执行的语句" "CREATE ROLE \"${CLI_PROBE}\" WITH LOGIN PASSWORD '${CLI_PROBE_PW}'" "${DRY_OUT}"
assert_contains "dry-run 自己说清「未执行」" "dry-run" "${DRY_OUT}"
assert_eq "dry-run 之后角色**仍然不存在**（真的没执行）" "0" \
    "$(psql_q "SELECT count(*) FROM pg_roles WHERE rolname = '${CLI_PROBE}';")"

# 8.3 真建（--yes）
CLI_CREATE="$("${CLI}" server-objects create-role --name "${CLI_PROBE}" --password "${CLI_PROBE_PW}" --yes 2>&1)"
assert_ok "CLI create-role --yes 真建成功" "$?" "${CLI_CREATE}"
assert_eq "CLI 建出来的角色可登录（rolcanlogin = t）" "t" \
    "$(psql_q "SELECT rolcanlogin FROM pg_roles WHERE rolname = '${CLI_PROBE}';")"

# 8.4 拒绝：注入名字连 --yes 也不许发语句
REJECT_OUT="$("${CLI}" server-objects drop-role --name 'x; DROP ROLE postgres' --yes 2>&1)"
assert_eq "注入名字被 CLI 拒绝（退出码 64）" "64" "$?"
assert_contains "拒绝理由可读（点名分号）" "分号" "${REJECT_OUT}"
assert_eq "被拒之后 postgres 角色**还在**" "1" \
    "$(psql_q "SELECT count(*) FROM pg_roles WHERE rolname = 'postgres';")"

# 8.5 方言不支持：人话 + 退出码 3 + **不生成任何 SQL**
GB_TS="$("${CLI}" server-objects tablespaces --dialect gbase8a 2>&1)"
assert_eq "GBase 表空间在 CLI 上是「不支持」（退出码 3）" "3" "$?"
assert_contains "不支持时给可读说明（点名 GBase 与表空间）" "没有表空间概念" "${GB_TS}"
case "${GB_TS}" in
    *SELECT*)
        echo "  ❌ 不支持的方言不该生成任何 SQL，但输出里出现了 SELECT"
        fail=1
        ;;
    *)
        echo "  ✅ 不支持时一条 SQL 都没生成（输出里没有 SELECT）"
        ;;
esac

# 8.6 真删（--yes）
CLI_DROP="$("${CLI}" server-objects drop-role --name "${CLI_PROBE}" --yes 2>&1)"
assert_ok "CLI drop-role --yes 真删成功" "$?" "${CLI_DROP}"
assert_eq "CLI 删完之后角色不存在" "0" \
    "$(psql_q "SELECT count(*) FROM pg_roles WHERE rolname = '${CLI_PROBE}';")"

echo ""
if [ "${fail}" -eq 0 ]; then
    echo "全部通过：角色浏览 / 一次性角色建改删（含 pg_roles 回查）/ 扩展列出与安装（含错误如实报出）/ 表空间只读列出"
    echo "            + 新 CLI 子命令（列表 / --json / dry-run / --yes 真建真删 / 注入拒绝 / 不支持不发 SQL）"
    echo "（**边界**：GBase 8a 侧本机没有实例，只有 Core 侧单测覆盖「不支持」的判定；界面仍需人工看）"
else
    echo "有失败项，见上"
fi
exit "${fail}"
