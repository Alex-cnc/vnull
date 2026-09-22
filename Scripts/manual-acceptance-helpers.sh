#!/bin/bash
set -euo pipefail

# 手工验收辅助脚本 —— 为「T-52 手工回归清单」里那两步**需要第二个会话**的用例造现场。
#
# 背景：这两步不是单机能点出来的，必须有另一个连接在服务端制造状态：
#   第 7 步：另开会话连上目标库，再在 App 里删除该库 → 应报「该库仍有其他会话连接……」
#   第 13 步：会话 A 开着事务改某行不提交，会话 B 改同一行 → App 的「锁与阻塞…」面板应列出
#            「被阻塞 pid = B、阻塞者 pid = A」并可「定位阻塞者」
#
# 本脚本用**本工程自己的 CLI**（`.build/debug/DoyahCLI`）造这些状态，
# 不需要装 psql / pg_isready。用完 `cleanup` 收尾，不留垃圾。
#
# 用法：
#   ./Scripts/manual-acceptance-helpers.sh hold [库名]   # 第 7 步：占住某库的连接（默认取连接档里的库）
#   ./Scripts/manual-acceptance-helpers.sh lock          # 第 13 步：造一条真实的行锁等待
#   ./Scripts/manual-acceptance-helpers.sh status        # 看当前挂着哪些会话（本地进程 + 服务端后端）
#   ./Scripts/manual-acceptance-helpers.sh cleanup       # 收尾：取消服务端会话 + 杀掉本地进程 + 清理测试表
#
# 连接参数走标准 PG* 环境变量（与其它脚本一致）；密码优先取 PGPASSWORD，
# 没给就按连接档的 UUID 去登录钥匙串取（可能弹一次系统授权框）。
#
#   PGHOST=<host> PGPORT=5432 PGUSER=<user> PGDATABASE=<db> PGSSLMODE=disable \
#     ./Scripts/manual-acceptance-helpers.sh lock
#
# ⚠️ 实测教训（2026-09-22，真机 PG 18.6）：**客户端进程死掉，服务端那条查询还会继续跑**。
#    实测：`SELECT pg_sleep(100)` 的本地进程被 SIGTERM 后，服务端后端仍在执行（计数 1 不变），
#    直到 `pg_cancel_backend` 才归零 —— 这是 PostgreSQL 的正常语义（后端忙于执行时不会去读
#    客户端 socket，因此察觉不到对端已断开），不是 CLI 的缺陷。后果是：
#    残留后端会一直占着锁 / 占着某个库，后续 `DROP TABLE` / `DROP DATABASE` 就会卡住
#    （实测把 cleanup 卡到 60s 超时）。所以：
#      ① 本脚本的每一次 CLI 调用都带 `--cancel-after`（服务端取消兜底），不会再无限等；
#      ② cleanup 必须走**服务端**取消（`pg_cancel_backend`，同角色即可，无需超级用户），
#         只 kill 本地 PID 是不够的。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${ROOT}/.build/debug/DoyahCLI"
STATE="${TMPDIR:-/tmp}/pc-acceptance-pids"
LOCK_TABLE="ic_lock_demo"
HOLD_SECONDS=900
# 只按「查询文本 + 当前角色」匹配，**不能**再按 datname 过滤：第 7 步 hold 的是
# 另一个库，而取消语句是在当前库里执行的，加 datname 过滤就会看不见那个后端。
SERVER_MATCH="usename = current_user AND (query LIKE '%${LOCK_TABLE}%' OR query LIKE '%pg_sleep(${HOLD_SECONDS})%')"

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGSSLMODE="${PGSSLMODE:-disable}"

if [ ! -x "${CLI}" ]; then
  echo "未找到 CLI：${CLI}"
  echo "先跑一次 ./Scripts/verify-core.sh（它会编译）再来。"
  exit 1
fi

# 统一的 CLI 调用：永远带服务端取消兜底，绝不无限等。
cli() { "${CLI}" --cancel-after "${CANCEL_AFTER:-20}" "$@"; }

# 密码：环境变量优先；否则按连接档的 UUID 去钥匙串取。
resolve_password() {
  if [ -n "${PGPASSWORD:-}" ]; then return; fi
  # 先找改名后的新容器，找不到再退回旧容器（迁移前后都能跑）。
  local support="Library/Application Support"
  local plist=""
  local bundle=""
  local candidate
  for candidate in \
    "$HOME/Library/Containers/studio.doyah.DoyahStudio/Data/${support}/DoyahStudio/connections.json" \
    "$HOME/Library/Containers/com.vnull.PostgresClient/Data/${support}/PostgresClient/connections.json"
  do
    if [ -f "${candidate}" ]; then
      plist="${candidate}"
      bundle="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "${candidate}")")")")")"
      break
    fi
  done
  local account=""
  if [ -n "${plist}" ]; then
    account="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[0]['id'] if d else '')" "${plist}" 2>/dev/null || true)"
    if [ -z "${PGDATABASE:-}" ]; then
      PGDATABASE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d[0].get('database','') if d else '')" "${plist}" 2>/dev/null || true)"
      export PGDATABASE
    fi
  fi
  if [ -z "${account}" ]; then
    echo "没找到连接档，也没给 PGPASSWORD。"
    echo "请显式提供：PGPASSWORD='…' $0 $*"
    return 1
  fi
  echo "→ 从登录钥匙串取密码（service=${bundle}，account=${account}），可能弹一次系统授权框…"
  PGPASSWORD="$(security find-generic-password -s "${bundle}" -a "${account}" -w)"
  export PGPASSWORD
}

run_bg() { # $1=标签，其余为 CLI 参数
  local label="$1"; shift
  "${CLI}" --cancel-after "${HOLD_SECONDS}" "$@" >/dev/null 2>&1 &
  local pid=$!
  echo "${pid} ${label}" >> "${STATE}"
  echo "  ✔ 已启动后台会话：${label}（本地 pid ${pid}，服务端会在 ${HOLD_SECONDS}s 后自动取消）"
}

# 取消我们自己在服务端留下的后端（同角色可取消，无需超级用户）。
cancel_server_backends() {
  local out
  out="$(cli -c "SELECT pid, datname, pg_cancel_backend(pid) AS cancelled FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND ${SERVER_MATCH};" 2>&1 || true)"
  if grep -qE '[0-9]+ \| t' <<<"${out}"; then
    echo "  ✔ 已取消服务端残留后端："
    grep -E '[0-9]+ \| t' <<<"${out}" | sed 's/^/      /'
  else
    echo "  （服务端没有我们留下的后端）"
  fi
}

kill_local() {
  [ -f "${STATE}" ] || return 0
  while read -r pid label; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      echo "  ✔ 已结束本地进程 ${label}（pid ${pid}）"
    fi
  done < "${STATE}"
}

cmd_hold() {
  resolve_password || exit 1
  local db="${1:-${PGDATABASE:-postgres}}"
  echo "== 第 7 步准备：占住数据库「${db}」的一条连接（保持 ${HOLD_SECONDS}s）=="
  PGDATABASE="${db}" run_bg "hold:${db}" -c "SELECT pg_sleep(${HOLD_SECONDS});"
  echo
  echo "现在去 App 里右键该库（服务器节点 → 数据库 → 该库）→「删除数据库…」并输入库名，"
  echo "应看到可读提示：「该库仍有其他会话连接……请先断开这些连接再试」。"
  echo "点完回来执行：$0 cleanup"
}

cmd_lock() {
  resolve_password || exit 1
  echo "== 第 13 步准备：造一条真实的行锁等待（表 ${LOCK_TABLE}）=="
  cli -c "DROP TABLE IF EXISTS ${LOCK_TABLE}; CREATE TABLE ${LOCK_TABLE}(id int PRIMARY KEY, v int); INSERT INTO ${LOCK_TABLE} VALUES (1, 0);" >/dev/null
  echo "  ✔ 测试表已建好"
  run_bg "lock-holder(A)" -c "BEGIN; UPDATE ${LOCK_TABLE} SET v = v + 1 WHERE id = 1; SELECT pg_sleep(${HOLD_SECONDS});"
  sleep 2   # 等 A 真正拿到行锁，再让 B 去撞
  run_bg "lock-waiter(B)" -c "UPDATE ${LOCK_TABLE} SET v = v + 1 WHERE id = 1;"
  echo
  echo "现在去 App 里右键服务器节点 →「锁与阻塞…」，应看到一行："
  echo "  被阻塞 pid = 服务端 pid(B)、阻塞者 pid = 服务端 pid(A)，含锁模式与已等待秒数；"
  echo "  点「定位阻塞者」应高亮 A 行。（面板显示的是**服务端 pid**，与上面本地 pid 不同）"
  echo "看完回来执行：$0 cleanup"
}

cmd_status() {
  if [ -f "${STATE}" ]; then
    echo "== 本地后台进程 =="
    while read -r pid label; do
      if kill -0 "${pid}" 2>/dev/null; then echo "  ✔ 存活  pid=${pid}  ${label}"; else echo "  ✗ 已退出 pid=${pid}  ${label}"; fi
    done < "${STATE}"
  else
    echo "（没有记录在案的本地后台进程）"
  fi
  echo "== 服务端会话（本库、非本连接）=="
  resolve_password >/dev/null 2>&1 || true
  if [ -n "${PGPASSWORD:-}" ]; then
    cli -c "SELECT pid, datname, state, wait_event_type FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND usename = current_user;" 2>&1 | tail -10
  else
    echo "  （取不到密码，跳过服务端查询）"
  fi
  return 0
}

cmd_cleanup() {
  echo "== 收尾 =="
  kill_local
  resolve_password >/dev/null 2>&1 || true
  if [ -z "${PGPASSWORD:-}" ]; then
    echo "  ⚠️ 取不到密码，无法做服务端清理；请带 PGPASSWORD 重跑 cleanup。"
    rm -f "${STATE}"
    return 0
  fi
  cancel_server_backends
  cli -c "DROP TABLE IF EXISTS ${LOCK_TABLE};" >/dev/null 2>&1 || true
  echo "  ✔ 测试表 ${LOCK_TABLE} 已清理（若仍存在，说明还有会话占着它，重跑一次 cleanup）"
  rm -f "${STATE}"
}

case "${1:-}" in
  hold)    shift; cmd_hold "$@" ;;
  lock)    cmd_lock ;;
  status)  cmd_status ;;
  cleanup) cmd_cleanup ;;
  *) sed -n '3,31p' "$0"; exit 1 ;;
esac
