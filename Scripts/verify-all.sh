#!/bin/bash
set -euo pipefail

# 本工程的一条命令验证闭环。
#
# 拆开跑过很多次、也就漏跑过很多次（尤其是文档计数与设计令牌这两项），
# 所以合成一条：**改完代码跑它，十四项全过才算完**。
#
#   1. Core 单测（SwiftPM，不需要数据库）+ 平台适配层单测
#   2. Core 平台中立性（Core 里不得出现平台专属依赖 —— 否则 Linux 编译不过）
#   3. Core 展示文本本地化棘轮（R-45：用户可见文案不得硬编码中文，只能比基线更少）
#   4. 文档表格列数与派生计数一致
#   5. 需求状态一致性（§10.1 索引表 ↔ 正文定义行）
#   6. 设计令牌棘轮（App/ 里的裸颜色 / 裸字号 / 裸间距不得比基线更差）
#   7. 平台等价矩阵与 §10.9 登记表一致
#   8. 平台中立性棘轮（需求规范书里的平台专属词汇不得比基线更差）
#   9. 命令面板接线（清单 ↔ 分派器 ↔ 视图绑定；见脚本注释里的真实缺陷）
#  10. 插件装配链（笔记模块解耦 FR-PLUG-07 + 装配与许可 FR-PLUG-01/02/03/06 + ADR-35）
#  11. 打包 .app（沙箱构建）
#  12. 脚本 shell 多字节安全（bash 3.2 的变量名坑，见 `check-shell-locale-safety.py`）
#  13. 脚本连接信息参数化（连真库的脚本不许写死端口 / 地址 / 账号，见 `check-script-env-parameterization.py`）
#  14. 连接失败的文案覆盖面（驱动错误码 ↔ 文案台账，见 `check-connection-failure-coverage.py`）
#
# 第 8 项是 2026-09-23 补的：那天发现命令面板有 9 条命令「设了标志位但没人读」，
# 用户点了完全没反应，而当时已有的 7 项门禁**全部看不见**这类缺陷（编译、单测、
# 文档、令牌、矩阵、打包全过）。所以"命令列出来了"与"命令真能打开东西"之间补一道闸。
#
# 第 10 项 2026-09-26（L-04）改了两处：① 加了 `check-plugin-assembly.py`（原先只有解耦一条）；
# ② **失败要真的让闭环失败** —— 原写法 `if ...; then :; else FAILED=1; fi` 把 FAILED 记下来
# 却没人读，结尾照样打印"全部通过"并以 0 退出（门禁红着、闭环绿着的假绿）。
# 现在两条都直接跑：`set -e` 会让失败当场中止并给出非零退出码。
#
# 第 12 项 2026-09-26（L-05）补的：macOS 自带 `/bin/bash` 是 **3.2.57**，而本工程脚本的 Shebang
# 全是 `#!/bin/bash`。实测：`echo "中文：$X）"` 在 bash 3.2 下会把 `$X` **静默展开成空**（后一个
# 字符也被切坏）；加了 `set -u` 则直接 `X?: unbound variable` 中止脚本。而这类写法在证据脚本里
# 是**不报错的**——脚本照常 exit 0、照常打勾，只是那一行的值空了（与第 10 项那次的假绿同一族）。
# 修法：变量写成 `${X}`。门禁 `check-shell-locale-safety.py` 把这个坑变成机械检查。
#
# 第 14 项 2026-09-26（L-14）补的：驱动是随仓库带走的 Vendor，升版可能多出新的 `PSQLError.Code`，
# 而文案层的 `switch` 有 `default:` 兜底 —— 新原因**不会报错**，只会被说成最泛的那句
# （「连接数据库失败」）。L-14 修掉的正是这一族：主机名解析不了被驱动压成 `serverClosedConnection`
# 且不带原因，用户看到的是「与数据库的连接中断了」。门禁把「每个码怎么处置」变成台账
# （`Scripts/connection-failure-dispositions.json`）与驱动源码、映射文件、解析前置检查、证据脚本逐条对账。
#
# 需要非沙箱构建（例如要跑 dsh-tui 的终端）时单独执行：
#   DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${ROOT}"

echo "==> 1/14 Core 与平台适配层单测"
./Scripts/verify-core.sh

echo "==> 2/14 Core 平台中立性"
python3 Scripts/check-core-portability.py

echo "==> 3/14 Core 展示文本本地化棘轮（R-45）"
python3 Scripts/check-core-localization.py

echo "==> 4/14 文档表格与派生计数"
python3 Scripts/check-doc-tables.py
# 派生文件不得漂移：终端配色 JSON ↔ Core ↔ 人读文档三方一致（FR-EDIT-29 的跨平台交接物）
python3 Scripts/check-terminal-palette.py

echo "==> 5/14 需求状态一致性（索引表 ↔ 正文定义行）"
python3 Scripts/check-status-consistency.py

echo "==> 6/14 设计令牌棘轮"
python3 Scripts/check-design-tokens.py

echo "==> 7/14 平台等价矩阵"
python3 Scripts/gen-platform-parity.py --check

echo "==> 8/14 平台中立性棘轮"
python3 Scripts/check-platform-neutrality.py

echo "==> 9/14 命令面板接线（FR-EDIT-25）"
python3 Scripts/check-palette-wiring.py

echo "==> 10/14 插件装配链（FR-PLUG-01~03 / 06 / 07 + ADR-35）"
python3 Scripts/check-note-module-isolation.py
python3 Scripts/check-plugin-assembly.py

echo "==> 11/14 打包 .app（沙箱）"
./Scripts/build-app.sh

echo "==> 12/14 脚本 shell 多字节安全（bash 3.2 变量名坑）"
python3 Scripts/check-shell-locale-safety.py

echo "==> 13/14 脚本连接信息参数化（连真库的脚本不许写死端口 / 地址 / 账号）"
python3 Scripts/check-script-env-parameterization.py

echo "==> 14/14 连接失败的文案覆盖面（驱动错误码 ↔ 文案台账）"
python3 Scripts/check-connection-failure-coverage.py

echo "✅ 验证闭环全部通过（十四项）"
