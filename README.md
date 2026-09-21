# PostgreSQL / GBase 8a 客户端（macOS）

Xcode + SwiftUI 工程骨架，按需求分析与概要设计 v1.2 搭建。

> 需求基线与实现状态见 [`Docs/需求规范书.md`](Docs/需求规范书.md)（SRS，持续维护）。

## 当前阶段

这是 **工程骨架**，不是完整可发布版本。

已经搭好：

- XcodeGen `project.yml`
- `PostgresClientCore` framework：模型、方言、语句拆分、服务协议、配置存储、Keychain
- `PostgresClient` macOS App：SwiftUI 主窗口、连接列表、连接表单、查询工作区、结果表格、对象树
- `PostgresClientTests`：语句拆分、配置 Codable、方言、SQL 静态检查/词法着色、元数据映射、保存查询、本地化、格式化、页签编号、结果导出、影响行数判定、编辑器文本同步、建库权限探测单元测试（89 项）
- App Sandbox：网络客户端 + 用户选择文件读写

已经接入：

- **PostgreSQL 驱动：PostgresNIO 1.33.1**
  - `PostgresService`：连接、`SHOW server_version`、查询执行、事务
  - `PostgresCellFormatter`：把 PostgresNIO 的 binary Cell 转成 UI 可展示字符串
  - `DatabaseServiceFactory` 已把 PostgreSQL 分支切到 `PostgresService`
  - `Package.resolved` 已固定 12 个远程传递依赖版本
  - **PostgresNIO 1.33.1 源码已打包到工程 `Vendor/postgres-nio`，Xcode 工程直接引用本地包**
  - 连接表单的“测试连接”按钮已接到真实 `PostgresService`
  - 新增 `PostgresClientCLI` 命令行工具，可在没有 UI 的情况下验证真实连接
  - **App 查询工作区已接入真实执行链路**（「执行」按钮，⌘↩）：
    - `AppState` 按连接缓存 `DatabaseService`，密码从 Keychain 读取
    - SQL 经 `StatementSplitter` 拆分后逐条执行，多语句/多结果集可用结果选择器切换
    - 执行状态、行数/列数、单条语句耗时、SQL 错误详情都显示在编辑器下方
    - 执行中的页签会显示进度，且不可关闭
    - 「停止」先取消客户端执行 Task，再另开连接执行 `pg_cancel_backend(pid)` 做**服务端取消**（语句真正中断、连接保持可用）
    - DML（`INSERT` / `UPDATE` / `DELETE`）显示**影响行数**（状态栏 + 结果区 + CLI `affectedRows: N`）
  - **元数据对象树已接入**：
    - `MetadataService` 按方言生成 SQL，再通过 `DatabaseService` 执行
    - 层级：**服务器 → 数据库 → Schema → Table / View → Column**（GBase 无 Schema 层）
    - 数据库列表按当前用户 CONNECT 权限过滤；展开非当前库时**按需建立该库的独立连接**并缓存
    - 懒加载：展开节点时才查询下一层（系统 schema 自动过滤）
    - 服务器节点右键菜单（FR-META-11）：连接 / 断开 / 编辑连接…；**按当前登录用户权限**决定是否呈现「新建数据库…」（权限未知或无权限时不呈现），建库后自动刷新数据库下拉与对象树
  - **结果表格已升级为 `NSTableView` 桥接**：
    - 列宽按内容估算、可拖动调整、可重排
    - 支持多选、`⌘C` / 右键复制（TSV 格式，可直接粘贴进 Excel）
    - 单元格视图复用，适合较大结果集
  - **SQL 编辑器已升级为 `NSTextView` 桥接**：
    - 关键字自动显示为紫色，函数/字符串/注释/数字分别配色
    - 客户端静态检查：未闭合字符串、双引号、块注释、dollar-quote、括号不配平 → 红色虚下划线 + 提示条
    - 「检查」按钮：对可 EXPLAIN 的语句执行 `EXPLAIN`（只解析/规划，不真正执行 DML），把服务器报错显示出来
    - 执行按钮为绿色实心三角形 ▶，⌘↩ 快捷键不变
  - **工作区上下文栏**：服务器选择器 + 数据库下拉框（只显示当前用户有 CONNECT 权限的库，选择结果决定查询 / 语法检查的目标库）
  - **编辑区 / 结果区可拖拽分隔**：`VSplitView`，两区最小高度 120 pt
  - **保存查询**：工具栏书签按钮命名保存当前 SQL + 已保存列表回填；JSON 持久化在 Application Support（不含密码）
  - **国际化**：菜单「语言」可切简体中文 / English；选择持久化、默认跟随系统，切换立即生效
  - **查询文件**：打开 SQL / 文本文件到新页签（默认不绑定连接，标题 = 文件名）；保存按钮主体直接保存，下拉箭头「另存为…」
  - **编辑菜单**：系统 Find Bar 查找 / 替换、跳到行 / 列、缩进（4 空格）/ 反缩进、清除查询（可撤销）、保守格式化 SQL
  - **帮助按钮**：问号图标，当前为「帮助内容待补充」占位
  - **结果导出**：结果区右上角导出菜单 → CSV（UTF-8 BOM + RFC 4180 转义）/ JSON（列定义 + 行数据）→ `NSSavePanel` 选路径
  - **SQL 补全**：方言关键字 + 内建函数，F5 / Esc / ⌃Space 触发
  - **查询历史**：工具栏时钟菜单，本次运行的历史（内存态、不落盘），可回填当前页签 / 一键清空
  - **记忆上次连接**：启动后自动恢复上次选中的连接（该连接已删除时回退首条）
  - **删除连接二次确认**：确认框明示「同时删除钥匙串密码且不可撤销」；表单校验复用 `ConnectionConfig.isValid`（端口 1–65535）
  - `Package.swift` 新增 `PostgresClientApp` 可执行目标，可在不打开 Xcode 的情况下编译 App 源码
  - 修复「点击编辑连接却弹出新建、字段为空」：连接表单改用 `.sheet(item:)`，避免 SwiftUI 复用旧 sheet 内容

暂未接入：

- `MySQLNIO` / GBase 8a 驱动（优先级最低）：方言层（`GBaseDialect`、`DELIMITER` 拆分）已就绪，
  驱动层需引入 MySQLNIO 并对接真实 GBase 8a 实例，验证清单见 [`Docs/GBase-技术验证.md`](Docs/GBase-技术验证.md)
- 结果集分页 / 虚拟滚动（超大数据量仍是一次性载入，见 SRS 的 R-03）
- `WITH … UPDATE`、`COPY`、DDL 的影响行数（PostgreSQL 协议本身不提供 / 驱动未解析）
- PostgreSQL 12–15 / 17 的实机回归（当前只有 16.2 本地与 18.6 真机；
  可用 [`Scripts/test-postgres-version-matrix.sh`](Scripts/test-postgres-version-matrix.sh) 对有实例的版本一键补测，结果记入 `Docs/兼容性矩阵.md`）

`DatabaseService` 协议已经稳定，后续只需要实现 `GBaseService`
并替换 `DatabaseServiceFactory` 中的 stub。

## 生成 Xcode 工程

本机 XcodeGen 路径：

```bash
$HOME/tools/xcodegen-dist/xcodegen/bin/xcodegen
```

生成工程：

```bash
cd ~/Projects/PostgresClient
$HOME/tools/xcodegen-dist/xcodegen/bin/xcodegen generate
```

然后打开：

```bash
open PostgresClient.xcodeproj
```

## PostgresNIO 依赖与国内网络

工程已声明：

```text
PostgresNIO 1.33.1
```

及其 12 个传递依赖，全部版本已固定在 `Package.resolved`。

如果 Xcode 解析 GitHub 依赖很慢或失败：

```bash
cd ~/Projects/PostgresClient
./Scripts/setup-package-mirrors.sh
```

然后在 Xcode 中执行：

```text
File → Packages → Reset Package Caches
File → Packages → Resolve Package Versions
```

该脚本会把 SwiftPM / Xcode 的依赖请求镜像到 gitclone.com。
如果以后网络恢复，可以删除：

```bash
rm ~/.swiftpm/configuration/mirrors.json
```

### 如果 Xcode 报 “Missing package product 'PostgresNIO'”

这是 XcodeGen 在生成本地包引用时，没有给
`XCSwiftPackageProductDependency` 自动补上 `package` 关联导致的。

工程已经在 `project.yml` 中配置：

```yaml
postGenCommand: ./Scripts/patch-xcodeproj.sh
```

每次执行：

```bash
xcodegen generate
```

之后会自动修复。

如果当前 Xcode 已经打开旧工程：

1. 退出 Xcode；
2. 确认 `Vendor/postgres-nio/Package.swift` 存在；
3. 重新打开 `PostgresClient.xcodeproj`；
4. `File → Packages → Reset Package Caches`；
5. `File → Packages → Resolve Package Versions`。

也可以手动执行：

```bash
./Scripts/patch-xcodeproj.sh
```

## 目录结构

```text
PostgresClient/
├── project.yml
├── Package.swift                 # Core 的 SwiftPM 测试入口
├── Vendor/
│   └── postgres-nio              # PostgresNIO 1.33.1 源码
├── Core/                         # PostgresClientCore.framework
│   ├── AppError.swift
│   ├── ConnectionConfig.swift
│   ├── ConnectionStore.swift
│   ├── DatabaseService.swift
│   ├── DatabaseType.swift
│   ├── Dialects.swift
│   ├── KeychainHelper.swift
│   ├── MetadataService.swift
│   ├── PostgresCellFormatter.swift
│   ├── PostgresService.swift
│   ├── QueryModels.swift
│   ├── SQLTokenizer.swift
│   ├── SQLLinter.swift
│   └── StatementSplitter.swift
├── App/                          # PostgresClient.app
│   ├── PostgresClientApp.swift
│   ├── AppState.swift
│   ├── PostgresClient.entitlements
│   ├── Views/
│   │   ├── MainWindow.swift
│   │   ├── ConnectionListView.swift
│   │   ├── ConnectionFormView.swift
│   │   ├── QueryWorkspaceView.swift
│   │   ├── SQLEditorView.swift
│   │   ├── ResultTableView.swift
│   │   ├── ResultGrid.swift
│   │   └── ObjectTreeView.swift
│   └── Utilities/
│       ├── ErrorPresenter.swift
│       ├── SQLHighlighter.swift
│       ├── SQLCompleter.swift
│       └── SecureASCIIField.swift
├── Tests/
│   ├── StatementSplitterTests.swift
│   ├── ConnectionConfigTests.swift
│   ├── DialectTests.swift
│   ├── PostgresServiceTests.swift
│   └── SQLLinterTests.swift
├── CLI/
│   └── main.swift                # PostgresClientCLI：真实连接 / 查询执行
├── Docs/                         # 配套文档
│   ├── README.md                 # 文档索引与维护约定
│   ├── 需求规范书.md             # SRS：需求基线 + 实现状态 + 追溯表（持续维护）
│   └── archive/                  # 历史基线（只读）
│       └── 需求规范书_v1.0.md
└── Scripts/
    ├── setup-package-mirrors.sh   # 国内网络下的包依赖镜像配置
    ├── verify-core.sh             # SwiftPM 编译 + 单元测试
    ├── test-postgres-connection.sh # 连接真实 PostgreSQL 并执行验证 SQL
    ├── test-local-query-path.sh   # 用内置 PostgreSQL 跑完整查询链路
    ├── build-app.sh               # SwiftPM 编译 + 组装 .app + ad-hoc 签名
    └── patch-xcodeproj.sh         # 修复 Xcode 本地包 product 关联
```

## 构建与测试

### Core 单元测试

已经通过：

```text
Executed 56 tests, with 0 failures
```

其中包含：

- PostgresNIO 1.33.1 完整依赖解析
- `PostgresService` 连接配置映射
- PostgreSQL / GBase 语句拆分
- GBase `DELIMITER` / `END$` vs `END $`
- 配置 Codable 与方言
- SQL 静态检查（未闭合字符串/注释/dollar-quote、括号配对）
- SQL 词法着色 token（关键字、函数、字符串、注释、数字）

推荐直接用工程脚本：

```bash
cd ~/Projects/PostgresClient
./Scripts/verify-core.sh
```

也可以手动执行：

```bash
cd ~/Projects/PostgresClient
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test \
  --disable-sandbox \
  --cache-path ~/.swiftpm-cache \
  --scratch-path ~/.swiftpm-build3 \
  --manifest-cache local \
  -Xswiftc -disable-sandbox
```

### macOS App 编译

已经通过：

```text
** BUILD SUCCEEDED **
```

命令：

```bash
cd ~/Projects/PostgresClient
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project PostgresClient.xcodeproj \
  -scheme PostgresClient \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath ~/.dd/PostgresClient \
  CODE_SIGNING_ALLOWED=NO \
  build
```

> `project.yml` 中增加了
> `OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -disable-sandbox`。
> 这是为了兼容当前命令行/沙箱环境下的 SwiftUI 宏展开；
> 在普通 Xcode GUI 中可以按需移除。

### 不用 Xcode 直接出 .app

```bash
cd ~/Projects/PostgresClient
./Scripts/build-app.sh            # 或 ./Scripts/build-app.sh release
open dist/PostgresClient.app
```

脚本会用 SwiftPM 编译 `PostgresClientApp` 目标，组装
`dist/PostgresClient.app`，并用 ad-hoc 签名写入
`App/PostgresClient.entitlements`（App Sandbox + 网络客户端）。

### 本地完整查询链路（无需外部数据库）

如果机器上装了 `pgserver`（内置 PostgreSQL，不需要 Homebrew/Docker）：

```bash
pip3 install --target ~/tools/pgserver <pgserver wheel>
./Scripts/test-local-query-path.sh
```

脚本会启动一个临时本地 PostgreSQL，验证：

- 字符串里的分号不被拆句
- `CREATE / INSERT / SELECT` 多语句执行
- `NULL` 显示
- 美元引号函数体
- 元数据对象树（schema → table → column，含列类型）
- SQL 错误返回退出码 2

当前结果：`通过 18 项，失败 0 项`。

## 连接真实 PostgreSQL

现在有真实 PostgreSQL 服务后，可以直接用 CLI 验证驱动链路：

```bash
cd ~/Projects/PostgresClient

PGHOST=另一台笔记本的IP \
PGPORT=5432 \
PGUSER=postgres \
PGPASSWORD='你的密码' \
PGDATABASE=postgres \
PGSSLMODE=disable \
./Scripts/test-postgres-connection.sh
```

CLI 会执行：

```sql
SELECT version(), current_database(), current_user;
```

用 `-c` 也可以执行任意 SQL（多语句用分号分隔），或从标准输入读取：

```bash
./Scripts/test-postgres-connection.sh -c "SELECT 1 AS a; SELECT now();"
echo "SELECT * FROM pg_database;" | ./Scripts/test-postgres-connection.sh
```

查看对象树（元数据链路，`--columns` 会带出列类型）：

```bash
./Scripts/test-postgres-connection.sh --tree --columns
```

并打印：

- `server_version`
- 当前数据库
- 当前用户
- 每条语句的结果集 / 行数 / 耗时

如果 CLI 成功，说明：

```text
PostgresNIO 驱动 → TCP 连接 → 认证 → SQL 执行 → 结果解析
```

整条链路都通了。

之后在 App 里：

1. 打开 `PostgresClient`；
2. 新建连接，填写另一台笔记本的 IP、端口、用户、密码；
3. 点击「测试连接」；
4. 看到“连接成功：版本号 · 数据库 · 用户”后，再保存连接；
5. 在右侧查询工作区输入 SQL，按 ⌘↩ 执行；
   多语句会逐条执行，多个结果集用标题栏的下拉选择器切换。

App 执行失败时，错误详情会显示在编辑器下方（可选中复制），
常见原因是密码未保存、`pg_hba.conf` 未放行客户端 IP、SSL 模式不匹配。

## 下一步开发顺序

已完成：工程骨架、PostgreSQL 驱动、查询执行、元数据对象树、结果表格、SQL 编辑器、
国际化、保存查询、文件打开 / 保存、编辑菜单、结果导出、SQL 补全、查询历史、
影响行数、服务端取消、记忆上次连接、删除二次确认、配套文档（SRS / 概要设计 / 测试用例 /
兼容性矩阵 / 发布方案 / GBase 技术验证）。开发任务清单见 SRS 的 10.7 节。

剩余（按优先级）：

1. **真实库手工验收**：按 [`Docs/测试用例.md`](Docs/测试用例.md) 的 AC-REL-04 清单逐项执行
   （对象树 / 文件打开保存 / 编辑菜单 / 拖拽分隔 / 国际化 / 保存查询 / 页签编号 / 导出 / 历史）。
2. **PostgreSQL 12–15 / 17 实机回归**：拿到实例后执行
   `PGHOST=… ./Scripts/test-postgres-version-matrix.sh`，把输出行补进 `Docs/兼容性矩阵.md`。
3. **超大数据量体验**：结果集分页 / 虚拟滚动（SRS 的 FR-RES-07、R-03）。
4. **GBase 8a**（用户要求排期最后）：提供可达实例后按
   [`Docs/GBase-技术验证.md`](Docs/GBase-技术验证.md) 的 16 项清单走一遍，
   再实现 `GBaseService`（MySQLNIO）。

发布（正式对外）前请按 [`Docs/发布方案.md`](Docs/发布方案.md) 做 Developer ID 签名 + 公证。
