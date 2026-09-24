#!/bin/bash
set -euo pipefail

# 本工程的一条命令验证闭环。
#
# 拆开跑过很多次、也就漏跑过很多次（尤其是文档计数与设计令牌这两项），
# 所以合成一条：**改完代码跑它，九项全过才算完**。
#
#   1. Core 单测（SwiftPM，不需要数据库）+ 平台适配层单测
#   2. Core 平台中立性（Core 里不得出现平台专属依赖 —— 否则 Linux 编译不过）
#   3. 文档表格列数与派生计数一致
#   4. 需求状态一致性（§10.1 索引表 ↔ 正文定义行）
#   5. 设计令牌棘轮（App/ 里的裸颜色 / 裸字号 / 裸间距不得比基线更差）
#   6. 平台等价矩阵与 §10.9 登记表一致
#   7. 平台中立性棘轮（需求规范书里的平台专属词汇不得比基线更差）
#   8. 命令面板接线（清单 ↔ 分派器 ↔ 视图绑定；见脚本注释里的真实缺陷）
#   9. 打包 .app（沙箱构建）
#
# 第 8 项是 2026-09-23 补的：那天发现命令面板有 9 条命令「设了标志位但没人读」，
# 用户点了完全没反应，而当时已有的 7 项门禁**全部看不见**这类缺陷（编译、单测、
# 文档、令牌、矩阵、打包全过）。所以"命令列出来了"与"命令真能打开东西"之间补一道闸。
#
# 需要非沙箱构建（例如要跑 dsh-tui 的终端）时单独执行：
#   DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${ROOT}"

echo "==> 1/9 Core 与平台适配层单测"
./Scripts/verify-core.sh

echo "==> 2/9 Core 平台中立性"
python3 Scripts/check-core-portability.py

echo "==> 3/9 文档表格与派生计数"
python3 Scripts/check-doc-tables.py
# 派生文件不得漂移：终端配色 JSON ↔ Core ↔ 人读文档三方一致（FR-EDIT-29 的跨平台交接物）
python3 Scripts/check-terminal-palette.py

echo "==> 4/9 需求状态一致性（索引表 ↔ 正文定义行）"
python3 Scripts/check-status-consistency.py

echo "==> 5/9 设计令牌棘轮"
python3 Scripts/check-design-tokens.py

echo "==> 6/9 平台等价矩阵"
python3 Scripts/gen-platform-parity.py --check

echo "==> 7/9 平台中立性棘轮"
python3 Scripts/check-platform-neutrality.py

echo "==> 8/9 命令面板接线（FR-EDIT-25）"
python3 Scripts/check-palette-wiring.py

echo "==> 9/9 打包 .app（沙箱）"
./Scripts/build-app.sh

echo "✅ 验证闭环全部通过（九项）"
