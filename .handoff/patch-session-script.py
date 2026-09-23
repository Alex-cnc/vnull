# -*- coding: utf-8 -*-
'''修会话验证脚本：判据（state=active）+ 数据目录改到工作区内（沙箱外目录起不来）。跑完即删。'''

import pathlib

p = pathlib.Path('/Users/alex/.dsh/projects/DoyahStudio/Scripts/test-session-management.sh')
t = p.read_text(encoding='utf-8')

# 1) 数据目录改到工作区内：原目录在 ~/tools 下，本轮实测沙箱不允许写（postmaster.pid 创建失败）。
old = 'DATADIR="${PGSERVER_DATADIR:-$HOME/tools/pgdata-querytest}"\nPORT=55432'
new = ('# 数据目录放在**工作区内**：本轮实测 `~/tools/pgdata-querytest` 在当前沙箱下起不来\n'
       '# （`could not create lock file "postmaster.pid": Operation not permitted`）。\n'
       'DATADIR="${PGSERVER_DATADIR:-$PWD/.build/pgdata-session-test}"\n'
       'PORT="${TEST_PGPORT:-55433}"')
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new, 1)

# 需要时初始化新集群
old_init = 'if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then'
new_init = ('''if [ ! -f "${DATADIR}/PG_VERSION" ]; then
    echo "  · 初始化临时集群 ${DATADIR}"
    mkdir -p "$DATADIR"
    "$PGBIN/initdb" -D "$DATADIR" -U postgres --auth=trust -E UTF8 >/dev/null 2>&1 || {
        echo "  ❌ initdb 失败"; exit 1; }
fi
if ! "$PGBIN/pg_ctl" -D "$DATADIR" status >/dev/null 2>&1; then''')
assert t.count(old_init) == 1
t = t.replace(old_init, new_init, 1)

# 2) 取消判据：必须看 state，不能只看 query（取消后 query 仍保留上一条语句文本）
old_still = ("    STILL=\"$(\"$CLI\" -c \"SELECT count(*) AS n FROM pg_stat_activity WHERE pid = ${PID} AND query LIKE '%pg_sleep%';\" "
             "2>&1 | awk -F' \\| ' '/^[0-9]+ \\|/{print $1}' | tr -d ' ' | head -1)\"")
new_still = ("    # 判据是 `state = 'active'`：**取消之后 `query` 字段仍保留上一条语句文本**（本轮踩到），\n"
             "    # 只看 query 会把「已空闲」误判成「还在跑」。\n"
             "    STILL=\"$(\"$CLI\" -c \"SELECT count(*) AS n FROM pg_stat_activity WHERE pid = ${PID} AND state = 'active';\" "
             "2>&1 | awk -F' \\| ' '/^[0-9]+ \\|/{print $1}' | tr -d ' ' | head -1)\"")
assert t.count(old_still) == 1, 'STILL 行未找到'
t = t.replace(old_still, new_still, 1)
t = t.replace('check "那条语句确实不再执行（会话已空闲 / 已结束）" 0 || check "语句应被取消（仍在跑）" 1',
              'check "那条语句确实不再执行（state 已不是 active）" 0 || check "语句应被取消（仍是 active）" 1', 1)

# 3) 权限判据：PG 对「普通角色取消超级用户」是抛错（42501），不是返回 false
old_denied = '''    echo "$DENIED" | grep -qiE "\\| f|false" && check "普通角色拿到 false（权限不足如实反馈）" 0 \\
        || { check "普通角色应当拿到 false" 1; echo "$DENIED" | tail -3; }'''
new_denied = '''    DENIED_CODE=$?
    # PostgreSQL 对「普通角色取消超级用户」的行为是**抛错（42501 permission denied）**，
    # 同级别用户之间才返回 false。判据因此是：**失败必须被如实暴露**（报错或 false），
    # 绝不能看起来像成功 —— 产品侧两种都会被转成可读提示。
    if [ "$DENIED_CODE" -ne 0 ]; then
        echo "$DENIED" | grep -qi "permission denied" && check "权限不足时如实报错（permission denied）" 0 \\
            || { check "应报 permission denied" 1; echo "$DENIED" | tail -3; }
    elif echo "$DENIED" | grep -qiE "\\| f|false"; then
        check "同级别失败时返回 false（如实反馈）" 0
    else
        check "权限不足不该看起来像成功" 1
        echo "$DENIED" | tail -3
    fi'''
assert t.count(old_denied) == 1, 'DENIED 行未找到'
t = t.replace(old_denied, new_denied, 1)
t = t.replace('echo "== 5) 权限如实反馈：取消别人的会话应当得到 false（而不是假装成功）=="',
              'echo "== 5) 权限如实反馈：普通角色取消超级用户的会话**必须失败**（PG 会抛 permission denied）=="', 1)

# 清理里也把临时集群停掉（并保留目录，便于下次复用；临时目录在 .build 下不会进 git）
t = t.replace('    [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1',
              '    [ "$STARTED" = "1" ] && "$PGBIN/pg_ctl" -D "$DATADIR" stop >/dev/null 2>&1', 1)

p.write_text(t, encoding='utf-8')
print('✅ 脚本已修：工作区内数据目录 + state 判据 + 权限判据')
