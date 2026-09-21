# GBase 8a 驱动技术验证记录

| 项目 | 内容 |
|---|---|
| 文档编号 | PC-DRV-001 |
| 版本 | v1.1 |
| 日期 | 2026-09-21 |
| 关联需求 | FR-DRV-01 ~ 08、FR-META-01 / 02 / 10、NFR-COMP-04（T-15） |
| 当前状态 | 方言层 ✅ 已实现并有单测；驱动层 ⬜ 未实现（**阻塞：无 GBase 8a 实例可验证**） |
| 关联文档 | `Docs/需求规范书.md`（§3.6 驱动与方言、§10.3 GBase 适配要点）、`Docs/兼容性矩阵.md` |

---

## 1. 结论与阻塞条件

| 结论 | 说明 |
|---|---|
| 架构上不需要为 GBase 改 UI / 业务层 | 目标形态是新增 `GBaseService`（协议层）复用现有 `SQLDialect`（方言层），UI 与 `AppState` 只依赖 `DatabaseService` 协议 |
| 方言层已完成 | `GBaseDialect`：库列表 `SHOW DATABASES`、反引号标识符、`LIMIT` 语法、关键字与内建函数表；`StatementSplitter` 支持客户端 `DELIMITER` 指令；单测覆盖（`Tests/DialectTests.swift`、`Tests/StatementSplitterTests.swift`） |
| 驱动层未实现的原因 | 需要引入 MySQLNIO 依赖，**且必须对接真实 GBase 8a 实例**才能确认认证插件、`information_schema` 可用性、多语句行为与类型映射；当前开发环境只有 PostgreSQL，无 GBase / MySQL 实例 |
| 解除阻塞所需 | 一个可达的 GBase 8a 实例：`host:port`、账号 / 密码（**只读账号即可**）、版本号、字符集；或允许本工程用 MySQL 8.0 做「协议层等价替换验证」（两者在协议层差异较大，不能替代 GBase 验证） |

> 结论：本文件先交付**验证方案与逐项检查表**，使实例就绪后可一次性完成验证；驱动代码实现排在所有任务最后（用户明确要求）。

---

## 2. GBase 8a 与 PostgreSQL 的差异（客户端需要处理的部分）

| 维度 | PostgreSQL（已实现） | GBase 8a（待实现） | 客户端影响 |
|---|---|---|---|
| 协议 | PostgreSQL 协议 v3（PostgresNIO） | MySQL 协议（需 MySQLNIO） | 新增协议层实现，`DatabaseService` 协议不变 |
| 标识符引用 | `"name"` | `` `name` `` | 方言层 `identifierQuote`（已实现） |
| 库列表 | `pg_database` + 权限过滤 | `SHOW DATABASES`（是否可用 `information_schema.SCHEMATA` 待验证） | 方言层 `listDatabasesQuery`（已实现，需实测确认） |
| 建库权限 | `pg_roles` 的 `rolsuper` / `rolcreatedb`（无权限则客户端不呈现「新建数据库」） | 无等价函数，需解析 `SHOW GRANTS` 输出（G-17 验证后实现） | 方言层 `databaseCreationPrivilegeQuery()` 现返回 `nil` → 客户端不呈现「新建数据库」 |
| 层级结构 | 服务器 → 数据库 → schema → 表 → 列 | 服务器 → 数据库 → 表 → 列（**通常无 schema 概念**；可能存在 db 内虚拟 schema） | `MetadataService` 已有「GBase 跳过 schema 层」分支（已实现，需实测确认） |
| 语句分隔 | `;` + dollar-quoting | `;` + 客户端 `DELIMITER` 指令（存储过程体内分号） | `StatementSplitter` 已支持（已实现，需实测） |
| 多语句执行 | 协议原生支持，一次一条 | 依赖 `CLIENT_MULTI_STATEMENTS` 或逐条执行 | 驱动层需逐条执行或打开多语句标志（待定，倾向逐条执行以复用现有事件流） |
| 影响行数 | command tag（`INSERT 0 3`） | `affected_rows`（MySQL 协议字段） | 驱动层直接映射到 `QueryResult.affectedRows`（比 PG 更简单） |
| 取消 | 另开连接 `pg_cancel_backend(pid)` | `KILL QUERY <connection_id>`（需权限）或发送 `COM_QUIT` | 驱动层 `cancel()`：查询 `CONNECTION_ID()` 后用独立连接执行 `KILL QUERY` |
| 超时 | 未下发 statement_timeout | 可 `SET SESSION max_execution_time`（或驱动侧主动取消） | 驱动层可在 `connect()` 后下发 |
| 认证 | trust / md5 / SCRAM-SHA-256 | MySQL 认证插件（`mysql_native_password` / `caching_sha2_password` 是否支持待验证） | MySQLNIO 支持 `mysql_native_password`；`caching_sha2_password` 支持情况需实测 |
| 字符集 | UTF8 / UTF8MB4 | 需确认 `character_set_client` / `_connection` | 连接参数需显式设置字符集，避免中文乱码 |
| 事务 | `BEGIN` / `COMMIT` | `START TRANSACTION` / `COMMIT`（等价） | 方言层 `beginTransactionSQL` 之类差异（若需要） |

---

## 3. 实现方案（待实例确认后落地）

### 3.1 依赖引入

| 步骤 | 内容 | 风险 |
|---|---|---|
| 1 | `Package.swift` 增加 `mysql-nio` 依赖（Vapor 官方，MIT） | 需确认版本与本工程 Swift 6.4 工具链兼容 |
| 2 | 依赖解析走 `Scripts/setup-package-mirrors.sh`（gitclone.com 镜像）；若镜像不可用则 `Vendor/` 内置源码 | 与 postgres-nio 同样的镜像 / 沙箱问题，已在 PG 上踩过 |
| 3 | `project.yml`（XcodeGen）增加包产品与链接脚本 `Scripts/patch-xcodeproj.sh` 同步 | Xcode 工程由 XcodeGen 生成，需同时改工程与包 |
| 4 | 保持 `Core/` 不 import SwiftUI / AppKit；`MySQLNIO` 只允许出现在 `Core/GBaseService.swift` | 架构约束（NFR-MAINT-02 / DR-03） |

### 3.2 代码落点

| 文件 | 职责 |
|---|---|
| `Core/GBaseService.swift`（新） | `DatabaseService` 实现：`connect()` / `execute()` 事件流 / `cancel()` / 事务；类型映射与 NULL 处理 |
| `Core/GBaseMetadataService.swift`（或复用 `MetadataService`） | 复用现有 `MetadataService`（它只依赖 `DatabaseService` + `SQLDialect`），按方言分支处理「无 schema」层级 |
| `Core/Dialects.swift` | `GBaseDialect` 已就绪，需按实测结果补齐：时间函数、类型名、`BEGIN` / 事务语句、`KILL QUERY` 方言方法 |
| `App/Views/ConnectionFormView.swift` | 已支持 `dbType == .gbase8a`（端口默认 5258，SSL 默认 disable） |
| `CLI/main.swift` | 需要把 `PostgresService` 换成按 `dbType` 选择驱动（`ProviderFactory`），便于脚本化验证 |

### 3.3 事件映射（与 PostgreSQL 对齐）

| `QueryEvent` | GBase 实现方式 |
|---|---|
| `.started(index)` | 每条语句执行前发出 |
| `.resultSet(QueryResult)` | 有结果集时：列元数据来自 MySQL 协议列定义，行值经 `GBaseCellFormatter`（与 `PostgresCellFormatter` 同规则：NULL → `nil`，二进制 → `<binary N bytes>`） |
| `.affectedRows(n)` | 直接使用 `affectedRows`（INSERT / UPDATE / DELETE / REPLACE） |
| `.notice(message)` | 映射 MySQL 警告数量 / 文本（可选） |
| `.finished(summary)` | 语句数与总耗时（与 PG 一致） |

---

## 4. 验证清单（实例就绪后逐项执行）

> 判定标准：每项都要有**可复制的命令 + 实际输出**，通过后把结论写回本表；
> 任一项失败都要在 `Docs/需求规范书.md` 的 R-18（GBase 适配风险）中登记差异。

| 编号 | 验证项 | 命令 / 操作 | 预期 | 状态 |
|---|---|---|---|---|
| G-01 | 连接与认证 | 客户端用 `dbType = gbase8a` 连接实例（端口 5258） | 连接成功；返回版本、当前库、当前用户 | ⬜ |
| G-02 | 认证插件 | 观察认证阶段（`mysql_native_password` / `caching_sha2_password`） | 至少一种可用；记录实际插件 | ⬜ |
| G-03 | 字符集 | `SHOW VARIABLES LIKE 'character_set%';` + 建表插入中文 | 中文往返正确、无乱码 | ⬜ |
| G-04 | 库列表 | 客户端打开对象树服务器节点 | 列出当前用户可见数据库（权限过滤行为记录实际结果） | ⬜ |
| G-05 | 库 → 表（无 schema） | 展开某库 | 直接列出表 / 视图，不出现 schema 层（或出现虚拟 schema，按实际结果调整方言） | ⬜ |
| G-06 | 表 → 列与类型 | 展开表 + 打开「显示列」 | 列名、类型名可读；类型映射表补全 | ⬜ |
| G-07 | 简单查询 | `SELECT 1 AS one, NULL AS empty, 'a;b' AS semi;` | 分号留在字符串内；NULL 显示为 NULL | ⬜ |
| G-08 | 多语句 | `CREATE TABLE …; INSERT …; SELECT …;` | 3 条语句依次执行并各自给出结果 / 影响行数 | ⬜ |
| G-09 | 影响行数 | `INSERT`（多行）/ `UPDATE` / `DELETE` | 分别显示受影响行数 | ⬜ |
| G-10 | 错误处理 | `SELECT * FROM no_such_table;` | 返回可读错误 + 错误码；不崩溃、连接可继续使用 | ⬜ |
| G-11 | 取消 | 执行长查询（如 `SELECT SLEEP(30)`）后点「停止」 | 语句在 1–2 s 内被取消，错误信息可读 | ⬜ |
| G-12 | 事务 | `START TRANSACTION; …; COMMIT;` / `ROLLBACK` | 行为与 PG 一致（含回滚验证） | ⬜ |
| G-13 | 语句拆分 | 存储过程 / `DELIMITER $$` 脚本 | 函数体内分号不被拆分 | ⬜ |
| G-14 | 权限不足场景 | 用无权限账号连接 | 给出可读错误；不出现「连接成功但列表为空且无提示」 | ⬜ |
| G-15 | 断网 / 超时 | 执行中切断网络 | 连接错误可读、可重连，不崩溃 | ⬜ |
| G-16 | 应用层回归 | App 内走通 AC-REL-04 的同类场景 | 与 PostgreSQL 体验一致（对象树 / 查询 / 导出 / 历史） | ⬜ |
| G-17 | 建库权限探测（FR-META-11） | 执行 `SHOW GRANTS` / 查询 `information_schema` 中与 `CREATE` 相关的授权记录 | 能判定「当前用户能否建库」；据此实现 `GBaseDialect.databaseCreationPrivilegeQuery()`（当前返回 `nil`＝不呈现「新建数据库」入口） | ⬜ |

---

## 5. 需要的环境信息（待用户提供）

| 项 | 示例 | 是否必需 |
|---|---|---|
| 主机 / 端口 | `10.0.0.10:5258` | ✅ |
| 账号 / 密码 | 只读账号即可（用于对象树与查询验证） | ✅ |
| GBase 8a 版本号 | `SELECT VERSION();` 输出 | ✅ |
| 认证插件 | `mysql_native_password` / `caching_sha2_password` | ✅ |
| 字符集 | `utf8` / `gbk` / `utf8mb4` | ✅ |
| 是否允许建测试表 | 需要（G-03 ~ G-09、G-13 需要写入） | ⬜（否则只做只读用例） |
| 网络可达性 | 客户端所在网段能否直连（参考 PG 的 `pg_hba.conf` 放行问题） | ✅ |

---

## 6. 风险与待确认

| 编号 | 风险 | 等级 | 应对 |
|---|---|---|---|
| GR-01 | 引入 MySQLNIO 可能与现有依赖版本冲突（NIOCore / swift-log 版本） | 中 | 在独立分支上先跑 `swift build`，确认依赖图无冲突再合并；必要时 `Vendor/` 内置源码 |
| GR-02 | GBase 8a 的 MySQL 协议实现与标准 MySQL 存在差异（认证插件 / `information_schema` 字段） | 高 | G-01 ~ G-06 逐项实测；驱动层只依赖实测确认的语句 |
| GR-03 | 无 schema 层级导致 `DatabaseObject` 语义差异 | 中 | 复用现有 `.database → .table` 分支；UI 与对象树已支持任意层级 |
| GR-04 | 多语句与 `DELIMITER` 行为差异 | 中 | 默认逐条执行（复用 `StatementSplitter`）；确需多语句时再打开标志 |
| GR-05 | 取消需要 `KILL` 权限 | 中 | 无权限时退化为「只取消本地等待」并给出提示（与 PG 的降级路径一致） |
| GR-06 | 无法在开发机上构建 GBase 专用测试环境 | 中 | 依赖用户提供的实例；验证清单可分批执行（只读优先） |

---

## 7. 变更记录

| 版本 | 日期 | 变更摘要 |
|---|---|---|
| v1.0 | 2026-09-21 | 首版：现状结论（方言层就绪 / 驱动层阻塞）、差异对照、实现方案、16 项验证清单、环境信息需求、6 项风险（T-15 交付物） |
| v1.1 | 2026-09-21 | 新增 G-17「建库权限探测」验证项与差异对照行（FR-META-11 在 GBase 上暂不呈现建库入口） |
