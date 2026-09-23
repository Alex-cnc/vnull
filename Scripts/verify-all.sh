#!/bin/bash
set -euo pipefail

# 本工程的一条命令验证闭环。
#
# 拆开跑过很多次、也就漏跑过很多次（尤其是文档计数与设计令牌这两项），
# 所以合成一条：**改完代码跑它，四项全过才算完**。
#
#   1. Core 单测（SwiftPM，不需要数据库）
#   2. 文档表格列数与派生计数一致
#   3. 设计令牌棘轮（App/ 里的裸颜色 / 裸字号 / 裸间距不得比基线更差）
#   4. 打包 .app（沙箱构建）
#
# 需要非沙箱构建（例如要跑 dsh-tui 的终端）时单独执行：
#   DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${ROOT}"

echo "==> 1/4 Core 单测"
./Scripts/verify-core.sh

echo "==> 2/4 文档表格与派生计数"
python3 Scripts/check-doc-tables.py

echo "==> 3/4 设计令牌棘轮"
python3 Scripts/check-design-tokens.py

echo "==> 4/4 打包 .app（沙箱）"
./Scripts/build-app.sh

echo "✅ 验证闭环全部通过"
