# -*- coding: utf-8 -*-
'''一次性补丁：登记「单实例保护静默自杀」（v3.79）。长文本一律用单引号串 + 「」，避免定界符冲突。'''
import pathlib

ROOT = pathlib.Path('/Users/alex/.dsh/projects/DoyahStudio')
p = ROOT / 'Docs/需求规范书.md'
t = p.read_text(encoding='utf-8')

old = '实测：`open -n` 强制新实例后进程数仍为 **1**。'
new = (
    '实测：`open -n` 强制新实例后进程数仍为 **1**。'
    '**2026-09-23 第二次实测又抓到一个**：单实例保护只比对 PID，'
    '**没排除「正在退出」的实例**，也没看 `activate()` 的返回值 —— '
    '于是「杀掉旧实例后立刻启动」会让新实例**静默 `exit(0)`**，用户看到的是'
    '**「界面干脆不出来了」**（无窗口、无崩溃报告、进程也没了）。'
    '已改为：① 排除 `isTerminated` 的实例；② 只有 `activate()` 成功才退出自己，'
    '失败就继续启动（宁可短暂多一个实例，也不能让用户看不到界面）；'
    '③ 新增 `startup.log` 记录启动决策，让这类**静默退出**变成可查。'
)
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new, 1)

ENTRY = (
    '| **v3.79** | 2026-09-23 | **修「界面干脆不出来了」——单实例保护会静默自杀**。'
    '需求提出者反馈界面起不来。**先排掉一个假线索**：`~/Library/Logs/DiagnosticReports` 里那份 '
    '`EXC_BREAKPOINT`（栈顶 `_libsecinit_appsandbox`）是**我自己早先「直接执行 bundle 内二进制」的无效测试**留下的 —— '
    '沙箱初始化要求经 LaunchServices 启动，直接跑必然 `Trace/BPT trap: 5`，不是应用缺陷。'
    '**真正原因**：单实例保护 `otherRunningInstance()` 只比对 PID，**没排除正在退出的实例**，'
    '也不看 `activate()` 的返回值 —— 「杀掉旧实例后立刻启动」（我自己反复做的动作）会让新实例'
    '**静默 `exit(0)`**：无窗口、无崩溃报告、进程也没了。**修法**：① 排除 `isTerminated`；'
    '② 只有 `activate()` 成功才退出自己，失败就继续启动自己；③ 新增 `startup.log`（应用数据目录）'
    '记录启动决策，把静默退出变成可查。**实测**：杀掉后立刻启动 → 进程稳定存活、'
    'LaunchServices 认它、日志为「正常启动」；运行中 `open -n` → 新实例「已激活它并退出自己」，'
    '仍只有 1 个实例（原始实例存活）。`verify-all.sh` 七项全过'
    '（本次校验与提交串成 `&&`，不重犯上轮「检查失败仍提交」的错） | 鲸鱼娘（开发助理） |\n'
)
head = '| 版本 | 日期 | 变更摘要 | 作者 |\n|---|---|---|---|\n'
assert t.count(head) == 1
t = t.replace(head, head + ENTRY, 1)
p.write_text(t, encoding='utf-8')
print('✅ 需求书：R-36 补第二个根因 + 变更记录 v3.79')
