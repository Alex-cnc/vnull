#!/bin/bash
set -euo pipefail

# 本工程的一条命令验证闭环。
#
# 拆开跑过很多次、也就漏跑过很多次（尤其是文档计数与设计令牌这两项），
# 所以合成一条：**改完代码跑它，十五项全过才算完**。
#
#   1. Core 单测（SwiftPM，不需要数据库）+ 平台适配层单测
#   2. Core 平台中立性（Core 里不得出现平台专属依赖 —— 否则 Linux 编译不过）
#   3. 本地化：Core 展示文本棘轮（R-45：用户可见文案不得硬编码中文，只能比基线更少）
#      + 「当前语言只有一个来源」（L-13：显式传语言必须走 `effectiveLanguage`）
#   4. 文档表格列数与派生计数一致
#   5. 需求状态一致性（§10.1 索引表 ↔ 正文定义行）
#   6. 设计令牌棘轮（App/ 里的裸颜色 / 裸字号 / 裸间距不得比基线更差）
#   7. 平台等价矩阵与 §10.9 登记表一致
#   8. 平台中立性棘轮（需求规范书里的平台专属词汇不得比基线更差）
#   9. 命令面板接线（清单 ↔ 分派器 ↔ 视图绑定；见脚本注释里的真实缺陷）
#  10. 插件装配链（笔记模块解耦 FR-PLUG-07 + 装配与许可 FR-PLUG-01/02/03/06 + ADR-35）
#      + 笔记模块的**零网络出口**（FR-PLUG-05 ②：数据不外发，见 `check-notes-offline.py`）
#  11. 打包 .app（沙箱构建）
#  12. 脚本 shell 多字节安全（bash 3.2 的变量名坑，见 `check-shell-locale-safety.py`）
#  13. 脚本连接信息参数化（连真库的脚本不许写死端口 / 地址 / 账号，见 `check-script-env-parameterization.py`）
#  14. 连接失败的文案覆盖面（驱动错误码 ↔ 文案台账，见 `check-connection-failure-coverage.py`）
#  15. 命令行失败输出的可读化覆盖面（L-15：不许出现「有话说却直接打英文串」的 print，
#      见 `check-cli-failure-readability.py`）
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
# 而文案层的 `switch` 有 `default:` 兜底 —— 新原因**不会报错**，只会被说成一句与它无关的话。
# L-14 修掉的正是这一族：主机名解析不了被驱动压成 `serverClosedConnection`
# 且不带原因，用户看到的是「与数据库的连接中断了」。门禁把「每个码怎么处置」变成台账
# （`Scripts/connection-failure-dispositions.json`）与驱动源码、映射文件、解析前置检查、证据脚本逐条对账。
# 第 8 轮（R-60）又加了两条：**兜底不许给方向结论**（`default:` 必须 `return nil`），
# 以及台账标「中性归因」的那 9 个码（用户取消 / 主动断开 / 协议层 / LISTEN 通道…）
# 必须在 `nonConnectionKeys` 里逐条点名 + 给出语言表键，且**调用方真的接上了这一档**
# （CLI / ErrorPresenter / 连接表单）—— 否则 `describe` 返回 nil 时用户只剩一句英文调试串。
#
# 需要非沙箱构建（例如要跑 dsh-tui 的终端）时单独执行：
#   DOYAH_NO_SANDBOX=1 ./Scripts/build-app.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${ROOT}"

echo "==> 1/15 Core 与平台适配层单测"
./Scripts/verify-core.sh

echo "==> 2/15 Core 平台中立性"
python3 Scripts/check-core-portability.py

echo "==> 3/15 本地化：Core 展示文本棘轮（R-45）+「当前语言只有一个来源」（L-13）"
python3 Scripts/check-core-localization.py
# L-13：界面语言有两条路 —— `L(...)` 与**显式传语言下去**（`summary(language:)` 之类）。
# 后者原先取的是**用户选择**（`LocalizationManager.shared.language`），绕过了渲染语境：
# 第 13 轮读图抓到的真缺陷就是它 —— 中文界面的行详情侧栏写着 `Text · 12 characters`。
# 收成一个口子 `effectiveLanguage`（宿主语境优先），并把这个口径变成机械判据。
python3 Scripts/check-effective-language.py

echo "==> 4/15 文档表格与派生计数"
python3 Scripts/check-doc-tables.py
# 派生文件不得漂移：终端配色 JSON ↔ Core ↔ 人读文档三方一致（FR-EDIT-29 的跨平台交接物）
python3 Scripts/check-terminal-palette.py

echo "==> 5/15 需求状态一致性（索引表 ↔ 正文定义行）"
python3 Scripts/check-status-consistency.py

echo "==> 6/15 设计令牌棘轮"
python3 Scripts/check-design-tokens.py

echo "==> 7/15 平台等价矩阵"
python3 Scripts/gen-platform-parity.py --check

echo "==> 8/15 平台中立性棘轮"
python3 Scripts/check-platform-neutrality.py

echo "==> 9/15 命令面板接线（FR-EDIT-25）"
python3 Scripts/check-palette-wiring.py

echo "==> 10/15 插件装配链（FR-PLUG-01~03 / 06 / 07 + ADR-35）"
python3 Scripts/check-note-module-isolation.py
python3 Scripts/check-plugin-assembly.py
# L-22：FR-PLUG-05 的「Linux 笔记＝本地离线、数据不外发（公司合规）」不能只是一句话 ——
# 笔记模块范围内**逐行扫网络 API 令牌表**（URLSession / import Network / NWConnection /
# http(s) 字面量 / URL(string: …），命中即红并点名文件与行号；范围声明与磁盘事实、
# 与上面那份解耦清单**两边对账**（漏登一个源文件也是红）。判据与台账见
# `Scripts/notes-offline-gate.json`（关键令牌不许被拿掉、例外要写明理由且锚点陈旧报红）。
python3 Scripts/check-notes-offline.py

echo "==> 11/15 打包 .app（沙箱）"
./Scripts/build-app.sh

echo "==> 12/15 脚本 shell 多字节安全（bash 3.2 变量名坑）"
python3 Scripts/check-shell-locale-safety.py

echo "==> 13/15 脚本连接信息参数化（连真库的脚本不许写死端口 / 地址 / 账号）"
python3 Scripts/check-script-env-parameterization.py

echo "==> 14/15 连接失败的文案覆盖面（驱动错误码 ↔ 文案台账）"
python3 Scripts/check-connection-failure-coverage.py

echo "==> 15/15 命令行失败输出的可读化覆盖面（L-15）"
# L-15：CLI 有 57 处「把失败说给用户看」的输出原先各写各的（`print("…：\(error.localizedDescription)")`），
# 打出来是 `The operation couldn't be completed. (PostgresNIO.PSQLError error 1.)` —— 既不是人话、
# 也没给方向，而驱动其实说过原因（SQLSTATE / 驱动码），只是没人接。这一项把「每一处用户可见的
# 失败输出都必须经同一个入口」变成**结构**判据（新增一处裸英文输出当场报红并指名行号），
# 并把入口自己的三条口径（认得出给方向 / 中性归因 / 认不出原样）与调用处数棘轮一起钉住。
python3 Scripts/check-cli-failure-readability.py

echo "✅ 验证闭环全部通过（十五项）"
