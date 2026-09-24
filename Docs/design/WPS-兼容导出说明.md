# WPS 表格兼容导出说明（FR-IO-07 / FR-RES-14）

> 需求提出者原话：「除了支持 xlsx 还要支持导出 CSV 和 WPS 的格式」。
> 本文把这句话拆成两半，并给出**可核实**的结论：**CSV 已支持（并补上了中文编码选择）；
> 而「WPS 的格式」如果指的是 `.et`，本产品不生成它 —— 原因与替代路径写在下面。**
> 相关需求：FR-IO-07（导出编码，✅）· FR-RES-14（xlsx 导出，🟡 待人工开一次）· R-48（`.et` 待决）。

## 1. 结论先行

| 你要的东西 | 现在的状态 | 怎么拿到它 |
|---|---|---|
| **CSV** | ✅ 早就支持（FR-RES-06），本轮补上**编码选择** | 结果区导出菜单 →「导出为 CSV…」（UTF-8 带 BOM，默认）或「导出为 CSV（GB18030，中文 Windows 直接打开）…」；CLI：`export --format csv [--encoding gb18030]` |
| **Excel 工作簿 `.xlsx`** | ✅ 已交付（FR-RES-14，自写 ZIP + OOXML，不引第三方库） | 导出菜单 →「导出为 Excel（.xlsx）…」；CLI：`export --format xlsx` |
| **WPS 表格能不能打开上面两个** | ✅ 能。WPS 表格官方支持 `.xlsx` / `.xls` / `.csv`（与 `.et` 共用同一个表格工作区） | 用 WPS 直接「打开」即可；命令行验证：`open -a wpsoffice <文件>` |
| **WPS 专有格式 `.et`** | ❌ **不生成**（不是"没排期"，是做不了/不该做，见 §3） | 需要 `.et` 时：用 WPS 打开我们导出的 `.xlsx` → 「另存为」→ 选 `.et`（手工一步，见 §4） |

## 2. `.et` 到底是什么（引官方说法，不凭印象）

- `.et` 是 **WPS 表格自己的工作簿格式**（金山 Office，与 Excel 的 `.xlsx` 角色相当但**不是同一种文件**）。
- 微软 **Excel 打不开 `.et`**：WPS 官方页面原文写着「Excel has no built-in ET decoder」「Changing the letters after the dot does not convert the file」——
  也就是说，**把 `.xlsx` 改名成 `.et`（或反过来）只会得到一个打不开的文件**。
- WPS 官方给出的跨应用路径就是：**在 WPS 里打开 → 另存为 `.xlsx` / `.xls`**。

来源（外部资料，2026-09-24 查阅）：

- WPS 官方功能页「What Is an ET File?」：<https://www.wps.com/feature/et-file/>
- WPS 官方博客「XLS vs XLSX vs ET」：<https://www.wps.com/blog/xls-vs-xlsx-vs-et/>
- 反向例证（Excel 关联到 `.et` 打开报错）：<https://learn.microsoft.com/zh-cn/answers/questions/4828414/excel-et>
- 中文乱码与编码（WPS 自己的排查文）：<https://www.wps.cn/article/wps-biao-ge-gu-zhang-jie-jue-2026-wP3OZIls.html>

## 3. 为什么本产品不生成 `.et`

1. **没有公开规范**：`.et` 是金山自有格式，公开资料里没有可供第三方实现的二进制/容器规范 ——
   要实现只能靠逆向或使用金山自己的转换组件。
2. **要么引 SDK，要么产出假文件**：真要在产品内直出 `.et`，只能引入金山的转换 SDK / 授权
   （商业条款、安装体积、平台覆盖都是新的约束）。**不做**的另一条"捷径"是把 `.xlsx` 改名为 `.et` ——
   那不是兼容，那是制造打不开的文件，比不支持更糟。
3. **需求本身能用现成路径满足**：需要 `.et` 的场合通常是"对方的系统只收 `.et`"。
   用 WPS 打开 `.xlsx` 再「另存为 `.et`」，一步搞定，且**公式、列宽、数字格式由 WPS 自己保证**，
   比第三方猜着写更可靠。

因此这条落在 **R-48（待决）**：是否值得为"直出 `.et`"引入金山 SDK 由需求提出者拍定；
在拍定之前，本说明就是对外可给的准确答复。

## 4. 手工把我们的导出变成 `.et`（WPS 12.1.28496，本机已装）

1. 在 DoyahStudio 里导出 `.xlsx`（导出菜单 →「导出为 Excel（.xlsx）…」）。
2. 用 WPS 表格打开它：`open -a wpsoffice <文件.xlsx>`，或右键「打开方式 → WPS Office」。
3. WPS 里 `文件 → 另存为`，格式选 **WPS 表格文件（*.et）**，保存。
4. 用 Excel 试开那个 `.et` 会失败 —— **这是正常的**（Excel 没有 ET 解码器），不是我们或 WPS 出错。

## 5. 中文 Windows 上"双击就能看"的那件事：编码

CSV 是纯文本，**能不能看懂中文取决于打开它的人按什么编码解**：

- 默认导出是 **UTF-8 带 BOM** —— 现代 Excel（2016+）、WPS、Numbers、LibreOffice 都认；
- 旧版 Office、部分自研导表程序、`cmd` 里 `type` 输出，按**本地代码页**（CP936 / GBK / 俗称 ANSI）解，
  对它们 UTF-8 中文必然是乱码 —— 这时用「导出为 CSV（**GB18030**）」。

**为什么是 GB18030 而不是 GBK**：GB18030 是 GBK / GB2312 的**超集**（GBK 能表示的它都能表示，
它还能表示 emoji 与生僻字 —— 实测 `😀` → `94 39 FC 36`）。用它导出的文件按 GBK 解也能读出其中的
GBK 子集，所以对旧工具一样可用，而不会因为遇到生僻字直接失败。

**导入侧对称**：我们自己读 CSV 时同样是「有 UTF-8 BOM 认 BOM → 否则严格试 UTF-8 → 再退 GB18030」，
所以从 WPS / Excel（中文 Windows）另存出来的 GBK 文件也能直接导入，而不是报"读取文件失败"。
界面（导入面板）与 CLI 都会**显示实际用的编码**，不猜着用。

## 6. 怎么验收（都可复跑）

| 验什么 | 命令 / 步骤 | 现状 |
|---|---|---|
| 两种编码的**字节**都对（中文字节与 GBK 码表逐字节相同、无 BOM、emoji 往返、逐行分页与一次性一致、负例、整库导出、导入闭环） | `bash Scripts/test-csv-encoding.sh` | ✅ 16 项断言，退出码 0（Python `gb18030` / `utf-8-sig` 独立核对） |
| `.xlsx` 文件本身合法且内容正确 | `bash Scripts/test-xlsx-export.sh` | ✅ 8 项断言（Python `zipfile` + `ElementTree` 独立解析） |
| **WPS / Excel 真打开一次**（观感、数字列、中文列宽） | `open -a wpsoffice <导出的文件>` | ⚠️ **只能人工**（脚本验的是文件合法性，不是软件的显示效果） |

## 7. 诚实边界

- `.et` **不生成**；改名不算转换（官方原文同此）。
- CSV 格式本身**无法区分 NULL 与空串**：导出都写成空字段，导入都成为 NULL —— 这是格式限制，不是实现缺陷（需要区分请用 `.xlsx`，那里 NULL 是"整格缺省"、空串是"存在但内容为空"）。
- GB18030 的**解码判决**是启发式（BOM → 严格 UTF-8 → GB18030）：一份"恰好也是合法 UTF-8"的 GBK 文件会被当成 UTF-8（现实里极罕见）。这里不引入统计检测，因为主场景是"读回自己 / 办公软件导出的文件"。
- 需要"直出 `.et`"的硬需求，走 R-48 拍板（引入金山 SDK/授权）而不是悄悄降级。
