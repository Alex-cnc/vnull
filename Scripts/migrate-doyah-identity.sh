#!/bin/bash
set -euo pipefail

# 一次性迁移：把「PostgresClient」时代的应用数据与钥匙串条目迁到「Doyah Studio」身份下。
#
# 为什么必须迁移：改 bundle id 会同时换掉两样东西的「地址」——
#   1. **沙箱容器**：~/Library/Containers/<bundle-id>/Data/Library/Application Support/<目录名>/
#      → 连接档、保存的查询、智能体配置、数据任务、执行历史、审计日志、目录书签都在这里；
#   2. **钥匙串 service 名 = bundle id** → 数据库密码与智能体 API Key 都挂在旧 service 下。
# 不迁移的后果：App 起来后连接列表是空的、密码读不出来（得手动重配一遍）。
# 注意：**App 自己迁不了** —— 沙箱不允许它读别的容器，所以只能用这个脚本在沙箱外做。
#
# 用法：
#   ./Scripts/migrate-doyah-identity.sh            # 预演：只打印计划，不写任何东西
#   ./Scripts/migrate-doyah-identity.sh --apply    # 真正执行
#
# 安全约定：
#   - 只读旧位置、只写新位置；**从不删除旧数据**（随时可回退）
#   - 目标已存在则跳过（幂等，绝不覆盖）
#   - 执行前把旧目录快照到 .backups/<时间戳>-identity-migration/
#   - 钥匙串优先用 PGPASSWORD 环境变量（避免读旧条目时弹系统授权框），否则从旧 service 读
#   - 全程**不打印任何口令**，只打印账号与长度

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
STAMP="$(date +%Y%m%d-%H%M%S)"

CONTAINERS="$HOME/Library/Containers"
SUPPORT="Data/Library/Application Support"

NEW_ID="studio.doyah.DoyahStudio"
NEW_DIR="DoyahStudio"
OLD_ID="com.vnull.PostgresClient"
OLD_DIR="PostgresClient"

NEW_SUPPORT="${CONTAINERS}/${NEW_ID}/${SUPPORT}/${NEW_DIR}"
OLD_SUPPORT="${CONTAINERS}/${OLD_ID}/${SUPPORT}/${OLD_DIR}"

say() { printf '%s\n' "$*"; }
run() { if [ "${APPLY}" -eq 1 ]; then "$@"; else say "    [预演] $*"; fi; }

say "== Doyah Studio 身份迁移（$([ "${APPLY}" -eq 1 ] && echo 执行 || echo 预演)）=="
say "  旧：${OLD_ID} / ${OLD_DIR}"
say "  新：${NEW_ID} / ${NEW_DIR}"
say ""

# ── 0. 一致性自检：三处声明的包标识必须一致 ────────────────────────────────
say "== 0. 包标识一致性自检 =="
# project.yml 里有三个 bundle id（app / core 框架 / 测试），这里只校验 **app 那个**
yml_id="${NEW_ID}"
yml_ok=0
grep -q "PRODUCT_BUNDLE_IDENTIFIER: ${NEW_ID}$" "${ROOT}/project.yml" && yml_ok=1
sh_id="$(sed -n 's/.*<string>\(studio\.doyah[^<]*\)<\/string>.*/\1/p' "${ROOT}/Scripts/build-app.sh" | head -1)"
core_id="$(sed -n 's/.*bundleIdentifier = "\([^"]*\)".*/\1/p' "${ROOT}/Core/DoyahIdentity.swift" | head -1)"
say "  project.yml（app 目标含该 id）: $([ "${yml_ok}" -eq 1 ] && echo "${NEW_ID}" || echo '<未找到>')"
say "  build-app.sh CFBundleIdentifier: ${sh_id:-<未找到>}"
say "  Core/DoyahIdentity.bundleIdentifier: ${core_id:-<未找到>}"
if [ "${yml_ok}" -ne 1 ] || [ "${sh_id}" != "${NEW_ID}" ] || [ "${core_id}" != "${NEW_ID}" ]; then
  say "  ❌ 三处不一致，先修代码再迁移。"
  exit 1
fi
say "  ✅ 一致"
say ""

# ── 1. 数据目录 ───────────────────────────────────────────────────────────
say "== 1. 应用数据目录 =="
if [ ! -d "${OLD_SUPPORT}" ]; then
  say "  旧目录不存在（${OLD_SUPPORT}），跳过。"
else
  say "  旧目录：${OLD_SUPPORT}"
  say "  新目录：${NEW_SUPPORT}"
  mkdir -p "${ROOT}/.backups/${STAMP}-identity-migration"
  cp -rp "${OLD_SUPPORT}" "${ROOT}/.backups/${STAMP}-identity-migration/" 2>/dev/null || true
  say "  快照：.backups/${STAMP}-identity-migration/$(basename "${OLD_SUPPORT}")"
  run mkdir -p "${NEW_SUPPORT}"
  copied=0
  for f in "${OLD_SUPPORT}"/*; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"
    [ "$name" = ".DS_Store" ] && continue
    if [ -e "${NEW_SUPPORT}/${name}" ]; then
      say "    ⏭  ${name}（新位置已存在，保留新文件）"
    else
      run cp -p "$f" "${NEW_SUPPORT}/${name}"
      say "    ✔  ${name}"
      copied=$((copied + 1))
    fi
  done
  say "  共 ${copied} 个文件待迁移/已迁移"
fi
say ""

# ── 2. 钥匙串 ─────────────────────────────────────────────────────────────
say "== 2. 钥匙串条目（service 名 = 包标识）=="
CONN_JSON="${NEW_SUPPORT}/connections.json"
[ -f "${CONN_JSON}" ] || CONN_JSON="${OLD_SUPPORT}/connections.json"

accounts=()
if [ -f "${CONN_JSON}" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] && accounts+=("$id")
  done < <(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(c.get('id','')) for c in d]" "${CONN_JSON}" 2>/dev/null || true)
fi
accounts+=("agent.api-key")

for account in "${accounts[@]}"; do
  [ -n "${account}" ] || continue
  if security find-generic-password -s "${NEW_ID}" -a "${account}" >/dev/null 2>&1; then
    say "    ⏭  ${account}（新 service 下已存在）"
    continue
  fi
  # ⚠️ 预演阶段**绝不触碰钥匙串**：读旧条目会弹系统授权框（无人应答就会一直挂着）。
  if [ "${APPLY}" -eq 0 ]; then
    say "    [预演] 将迁移 ${account}（执行时优先用 PGPASSWORD，否则读旧 service，可能弹一次授权框）"
    continue
  fi
  secret=""
  source=""
  # PGPASSWORD 只对**连接账号**（UUID 形态）生效 —— 否则会把数据库口令写成别的条目
  # （例如 agent.api-key），那是数据损坏而不是迁移。
  if [ -n "${PGPASSWORD:-}" ] && [[ "${account}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    secret="${PGPASSWORD}"; source="PGPASSWORD 环境变量"
  else
    secret="$(security find-generic-password -s "${OLD_ID}" -a "${account}" -w 2>/dev/null || true)"
    source="旧 service ${OLD_ID}"
  fi
  if [ -z "${secret}" ]; then
    say "    ⚠️  ${account}：旧 service 下没读到（可能本来就没存），跳过 —— 在 App 里重输一次即可"
    continue
  fi
  say "    →  ${account}：从「${source}」迁移（长度 ${#secret}）"
  # -U：已存在则更新；-T 信任新 App，减少首次读取时的授权弹窗
  security add-generic-password -s "${NEW_ID}" -a "${account}" -w "${secret}" -U \
    -T "${ROOT}/dist/DoyahStudio.app" >/dev/null
done
say ""

# ── 3. 收尾提示 ───────────────────────────────────────────────────────────
say "== 3. 下一步 =="
if [ "${APPLY}" -eq 0 ]; then
  say "  这是预演。确认无误后重跑：$0 --apply"
  say "  （若口令来源只能读旧钥匙串，执行时会弹一次系统授权框）"
else
  say "  1) 打开新 App：open \"${ROOT}/dist/DoyahStudio.app\""
  say "  2) 确认连接档（如 DemoPG）在列表里、能连上。"
  say "  3) 若连接列表是空的：先启动一次新 App（让系统正式建好沙箱容器）→ 退出 → 重跑本脚本（幂等）。"
  say "  4) 旧的 ${OLD_ID} 容器与钥匙串条目**原样保留**，确认无误后可自行清理。"
fi
