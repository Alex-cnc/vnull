import SwiftUI
import AppKit
import DoyahCore

/// 「导入数据」面板（FR-IO-03 的整套界面）。
///
/// 这是本工程**第一处**导入界面（此前导入只在 Core 与 CLI 里）。顺序按"风险从低到高"排：
/// 选文件 → 选目标表 → **先解析再看**（列映射 / 未匹配列 / 必填缺失 / 非法值）→
/// 写入通道 → 前几行预览 → 执行（带进度与逐批日志）。
///
/// 四条不能做松的口径：
/// 1. **列映射用 Core 的 `TableImport.plan`**：界面不自己写"名字对上就映射"的第二套规则，
///    否则界面与 CLI 对同一份文件会给出不同的映射；
/// 2. **优先 COPY，取不到要说明理由**：`TableImport.copySupport` 给出可用性与原因，
///    取不到时**不摆一个点不动的勾选框**，而是直接写明"走批量 INSERT"并附上理由 ——
///    静默退回逐行 INSERT 与"灰掉的选项"都算不上说明；
/// 3. **写语句走既有 `ExecutionSafety`**（"在编辑器里敲一条 INSERT"是同一类动作）：
///    只读连接直接拒绝、需要确认时二次确认；确认前一行都不写；
/// 4. **读数与解析在后台**：`String(contentsOf:)` + 解析都不在主线程上做，
///    否则一个大文件会让窗口卡住 —— 而"卡住"与"没反应"在用户眼里是一回事。
struct ImportPanel: View {
    /// 文件格式。TSV 与 CSV 走同一个读取器，只是分隔符不同；JSON 只接受对象数组。
    private enum Format: String, Hashable {
        case csv
        case tsv
        case json
        /// Excel 工作簿（FR-IO-06）：二进制 ZIP + OOXML，走 `XLSXReader`（按工作表选）。
        case xlsx
    }

    /// 后台解析的结论：**不跨线程抛 `Error`**（`Result` 带 `Error` 在并发里不好送），
    /// 失败只带底层原因，本地化文案回到主线程再拼。
    private enum ParseOutcome: Sendable {
        /// 解析成功 + **实际使用的文本编码**（GB18030 时界面要提示一句）。
        case parsed(DelimitedTextReader.Result, ResultExportEncoding)
        case readFailed(String)
        case parseFailed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var filePath = ""
    @State private var format: Format = .csv
    @State private var hasHeader = true
    @State private var targetTable = ""
    @State private var parsed: DelimitedTextReader.Result?
    @State private var plan: TableImport.Plan?
    @State private var parseError: String?
    @State private var isParsing = false
    /// 这次解析实际用的文本编码（默认 UTF-8；GB18030 时在文件行下面提示）。
    @State private var sourceEncoding: ResultExportEncoding = .utf8
    /// 选中的 xlsx 里有哪几张工作表（选了文件就列出来，让用户挑，而不是默认第一张）。
    @State private var sheetNames: [String] = []
    @State private var sheetIndex: Int = 0
    @State private var mode: ImportWriteMode = .batchInsert
    @State private var copyReason: String?
    @State private var pendingConfirmation: ExecutionSafety.Decision?
    @State private var hasParsedOnce = false

    /// 预览取前几行。执行时仍然是**全部行**（按批处理），预览只是给人看的。
    private let previewLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(.importTitle))
                    .font(Theme.font(.title))
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(appState.isImportRunning)
            }

            Text(L(.importHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 660, alignment: .leading)

            HairlineView()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    sourceSection
                    if let plan {
                        mappingSection(plan)
                        writeModeSection(plan)
                    }
                    previewSection
                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.status(.danger))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HairlineView()
            footer
        }
        .padding(Spacing.l)
        .frame(width: 780, height: 760, alignment: .leading)
        .onAppear(perform: prepare)
        .onChange(of: format) { _, _ in invalidate() }
        .onChange(of: hasHeader) { _, _ in invalidate() }
        .onChange(of: appState.selectedConnection?.id) { _, _ in refreshWriteMode() }
        .alert(
            L(.importConfirmTitle),
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            )
        ) {
            Button(L(.commonCancel), role: .cancel) { pendingConfirmation = nil }
            Button(L(.importExecute), role: .destructive) {
                pendingConfirmation = nil
                run(bypassingSafetyCheck: true)
            }
        } message: {
            Text(L(.importConfirmMessage, pendingConfirmation?.message ?? ""))
        }
    }

    // MARK: - 文件 / 目标表 / 格式

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text(L(.importFile))
                    .font(Theme.font(.body))
                    .frame(width: 90, alignment: .leading)
                Text(filePath.isEmpty ? L(.importNoFile) : filePath)
                    .font(Theme.font(.monoSmall))
                    .foregroundStyle(filePath.isEmpty ? Theme.text(.tertiary) : Theme.text(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L(.importChooseFile)) { chooseFile() }
            }

            // 不是 UTF-8 就写明按什么编码读的（FR-IO-07）：中文列名 / 值会不会乱码，
            // 取决于这一步，用户需要看得见。
            if sourceEncoding != .utf8 {
                Text(L(.importEncodingFallback, sourceEncoding.shortName))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Spacing.l) {
                Text(L(.importFormat))
                    .font(Theme.font(.body))
                    .frame(width: 90, alignment: .leading)
                Picker("", selection: $format) {
                    Text("CSV").tag(Format.csv)
                    Text("TSV").tag(Format.tsv)
                    Text("JSON").tag(Format.json)
                    Text("Excel（.xlsx）").tag(Format.xlsx)
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: format) { _, newValue in handleFormatChange(newValue) }
                Toggle(L(.importHasHeader), isOn: $hasHeader)
                    .font(Theme.font(.caption))
                    .disabled(format == .json)
                Spacer()
            }

            if format == .xlsx {
                HStack(spacing: Spacing.l) {
                    Text(L(.importSheet))
                        .font(Theme.font(.body))
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $sheetIndex) {
                        ForEach(Array(sheetNames.enumerated()), id: \.offset) { index, name in
                            Text("\(index + 1). \(name)").tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    .disabled(sheetNames.isEmpty)
                    if sheetNames.isEmpty {
                        Text(L(.importSheetPending))
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.tertiary))
                    }
                    Spacer()
                }
            }

            HStack(spacing: Spacing.s) {
                Text(L(.importTargetTable))
                    .font(Theme.font(.body))
                    .frame(width: 90, alignment: .leading)
                TextField("", text: $targetTable)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(.mono))
                Button(L(.importParse)) { Task { await parse() } }
                    .disabled(isParsing || filePath.isEmpty || targetTable.isEmpty)
                if isParsing { ProgressView().controlSize(.small) }
            }
            Text(L(.importTargetTableHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 列映射

    private func mappingSection(_ plan: TableImport.Plan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let parsed {
                Text(L(.importSourceSummary, filePath, parsed.rows.count, parsed.header.count))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                if !parsed.warnings.isEmpty {
                    Text(L(.importWarnings, min(3, parsed.warnings.count)))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                    ForEach(parsed.warnings.prefix(3), id: \.self) { warning in
                        Text("· " + warning)
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.tertiary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text(L(.importColumnMapping))
                .font(Theme.font(.bodyStrong))
            if plan.mappedColumns.isEmpty {
                Text(L(.importMappingEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
            } else {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    ForEach(Array(plan.mappings.enumerated()), id: \.offset) { _, mapping in
                        HStack(spacing: Spacing.s) {
                            Text(mapping.sourceName ?? "—")
                                .font(Theme.font(.monoSmall))
                                .frame(width: 140, alignment: .leading)
                            Text("→")
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.tertiary))
                            Text(mapping.targetName)
                                .font(Theme.font(.monoSmall))
                                .frame(width: 140, alignment: .leading)
                            Text(plan.valueTypes[mapping.targetName]?.displayName ?? "text")
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.tertiary))
                            if mapping.sourceIndex == nil {
                                Text(L(.importMappingMissing))
                                    .font(Theme.font(.caption))
                                    .foregroundStyle(Theme.text(.tertiary))
                            }
                            Spacer()
                        }
                    }
                }
            }

            if !plan.unknownSourceColumns.isEmpty {
                Text(L(.importMappingUnknown, plan.unknownSourceColumns.joined(separator: "、")))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plan.missingRequiredColumns.isEmpty {
                Label(
                    L(.importMappingMissingRequired, plan.missingRequiredColumns.joined(separator: "、")),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.status(.danger))
                .fixedSize(horizontal: false, vertical: true)
            }
            if let parsed {
                // Core 最多给 20 条；这里只列前 5 条，所以**数字也按实际列出的条数写**，
                // 免得文案说"前 20 条"而界面上只有 5 行。
                let invalid = TableImport.invalidValues(rows: parsed.rows, plan: plan)
                if !invalid.isEmpty {
                    Text(L(.importPrecheckInvalid, min(5, invalid.count)))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.status(.warning))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(invalid.prefix(5), id: \.self) { problem in
                        Text("· " + problem)
                            .font(Theme.font(.caption))
                            .foregroundStyle(Theme.text(.tertiary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 写入通道

    private func writeModeSection(_ plan: TableImport.Plan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.l) {
                Text(L(.importWriteMode))
                    .font(Theme.font(.body))
                    .frame(width: 90, alignment: .leading)
                if copyReason == nil {
                    Picker("", selection: $mode) {
                        Text(L(.importWriteModeCopy)).tag(ImportWriteMode.copy)
                        Text(L(.importWriteModeBatchInsert)).tag(ImportWriteMode.batchInsert)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 340)
                } else {
                    // COPY 取不到：**不摆一个点不动的选项**，直接把回退后的通道写出来，
                    // 理由紧跟在下面（静默降级与"灰掉的勾选框"都算不上说明）。
                    Label(L(.importWriteModeBatchInsert), systemImage: "arrow.triangle.2.circlepath")
                        .font(Theme.font(.body))
                }
                Spacer()
            }
            if let copyReason {
                Label(copyReason, systemImage: "info.circle")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mode == .copy {
                if let statement = copyStatement(plan) {
                    Text(L(.importCopyStatement))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                    Text(statement)
                        .font(Theme.font(.monoSmall))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L(.importCopyAtomicNote))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.importPreviewTitle, previewLimit))
                .font(Theme.font(.bodyStrong))
            if let parsed, !parsed.rows.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(parsed.header.joined(separator: " | "))
                            .font(Theme.font(.monoSmall))
                            .foregroundStyle(Theme.text(.tertiary))
                        ForEach(Array(parsed.rows.prefix(previewLimit).enumerated()), id: \.offset) { _, row in
                            Text(row.map { $0 ?? "NULL" }.joined(separator: " | "))
                                .font(Theme.font(.monoSmall))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                Text(L(.importSampleNote))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            } else {
                Text(L(.importPreviewEmpty))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
            }
        }
    }

    // MARK: - 执行与日志

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Button(L(.importExecute)) { run(bypassingSafetyCheck: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
                if appState.isImportRunning {
                    Button(L(.importStop)) { appState.cancelTableImport() }
                    ProgressView(value: appState.importProgress)
                        .tint(Theme.accentColor)
                        .frame(width: 160)
                    Text(L(.importRunning))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.secondary))
                }
                Spacer()
            }

            if let error = appState.importError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.danger))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let message = appState.importMessage {
                Text(message)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.success))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !appState.importLog.isEmpty {
                Text(L(.importLog))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        ForEach(Array(appState.importLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(Theme.font(.monoSmall))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 96)
            }
        }
    }

    private var canRun: Bool {
        guard plan != nil, parsed != nil, !appState.isImportRunning else { return false }
        guard let plan else { return false }
        return !plan.mappedColumns.isEmpty && plan.missingRequiredColumns.isEmpty
    }

    // MARK: - 行为

    private func prepare() {
        if targetTable.isEmpty, let object = appState.selectedTreeObject,
           object.kind == .table || object.kind == .view {
            targetTable = object.schema.map { "\($0).\(object.name)" } ?? object.name
        }
        refreshWriteMode()
    }

    /// 目标表文本 → (表, schema)。支持 `schema.table` 与纯表名。
    private var parsedTarget: (table: String, schema: String?) {
        let trimmed = targetTable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.firstIndex(of: ".") else { return (trimmed, nil) }
        let schema = String(trimmed[..<dot])
        let table = String(trimmed[trimmed.index(after: dot)...])
        return (table, schema.isEmpty ? nil : schema)
    }

    private func copyStatement(_ plan: TableImport.Plan) -> String? {
        TableImport.copyStatement(
            table: plan.table,
            schema: plan.schema,
            columns: plan.mappedColumns.map(\.targetName)
        )
    }

    /// 连接不给 COPY 时，**把理由记下来**并把选中项切回批量 INSERT。
    private func refreshWriteMode() {
        let databaseType = appState.selectedConnection?.dbType ?? .postgresql
        let preferred = TableImport.preferredWriteMode(databaseType: databaseType)
        copyReason = preferred.reason
        if preferred.reason != nil, mode == .copy {
            mode = .batchInsert
        } else if preferred.reason == nil, !hasParsedOnce {
            mode = preferred.mode
        }
    }

    /// 改动文件 / 格式 / 表头后，上一次的解析结论作废（否则会拿旧映射去写新数据）。
    /// 切格式时：切到 Excel 就补拉工作表列表；切走就把列表清掉（免得留着上一次的残留）。
    private func handleFormatChange(_ newValue: Format) {
        invalidate()
        guard newValue == .xlsx, !filePath.isEmpty else { return }
        Task { await loadSheetNames(path: filePath) }
    }

    private func invalidate() {
        parsed = nil
        plan = nil
        parseError = nil
        hasParsedOnce = false
        sheetNames = []
        sheetIndex = 0
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        filePath = url.path
        invalidate()
        Task { await loadSheetNames(path: url.path) }
    }

    /// 列出 xlsx 的工作表（只在选了文件 / 切到 Excel 时做一次，读的是 ZIP 中央目录，很轻）。
    private func loadSheetNames(path: String) async {
        let names = await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let sheets = try? XLSXReader.sheets(data) else { return [] }
            return sheets.map(\.name)
        }.value
        guard !names.isEmpty else { return }
        sheetNames = names
        sheetIndex = 0
    }

    /// 解析 + 生成列映射。两步都不在主线程上做重活（解析在后台，表结构走既有异步元数据查询）。
    private func parse() async {
        guard !isParsing else { return }
        isParsing = true
        parseError = nil
        // 上一次的日志随之作废：换文件后还留着旧批次行数只会让人误判。
        appState.clearImportLog()
        defer { isParsing = false }

        let path = filePath
        let format = self.format
        let hasHeader = self.hasHeader
        let sheetIndex = self.sheetIndex
        let outcome = await Task.detached(priority: .userInitiated) { () -> ParseOutcome in
            // Excel 工作簿是二进制（ZIP + OOXML）：不走文本编码，也不解析文本。
            if format == .xlsx {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    return .parsed(
                        try XLSXReader.importResult(data, sheet: sheetIndex, hasHeader: hasHeader),
                        .utf8
                    )
                } catch {
                    return .parseFailed(error.localizedDescription)
                }
            }
            // 编码不猜死 UTF-8（FR-IO-07）：中文 Windows 上从 Excel / WPS 另存的 CSV
            // 是 GBK / GB18030，只按 UTF-8 读会直接报"读不了"。
            let decoded: TextFileDecoder.Decoded
            do {
                decoded = try TextFileDecoder.decode(contentsOf: URL(fileURLWithPath: path))
            } catch {
                return .readFailed(error.localizedDescription)
            }
            let text = decoded.text
            do {
                switch format {
                case .json:
                    return .parsed(try DelimitedTextReader.readJSON(text), decoded.encoding)
                case .csv:
                    return .parsed(try DelimitedTextReader.read(
                        text,
                        options: DelimitedTextReader.Options(hasHeader: hasHeader)
                    ), decoded.encoding)
                case .tsv:
                    return .parsed(try DelimitedTextReader.read(
                        text,
                        options: DelimitedTextReader.Options(delimiter: "\t", hasHeader: hasHeader)
                    ), decoded.encoding)
                case .xlsx:
                    // 走不到这里：上面已经按二进制路径提前返回。留着是为了让 switch 穷尽 ——
                    // 而不是留一个"静默当成 CSV 解析"的口子。
                    return .parseFailed("xlsx 应走二进制读取路径")
                }
            } catch {
                return .parseFailed(error.localizedDescription)
            }
        }.value

        switch outcome {
        case .readFailed(let reason):
            parsed = nil
            plan = nil
            parseError = L(.importReadFailed, reason)
        case .parseFailed(let reason):
            parsed = nil
            plan = nil
            parseError = L(.importParseFailed, reason)
        case .parsed(let result, let encoding):
            sourceEncoding = encoding
            let target = parsedTarget
            guard !target.table.isEmpty else {
                parseError = L(.importTargetTableHint)
                return
            }
            do {
                let computed = try await appState.tableImportPlan(
                    table: target.table,
                    schema: target.schema,
                    sourceHeader: result.header,
                    hasHeader: self.hasHeader
                )
                parsed = result
                plan = computed
                hasParsedOnce = true
                refreshWriteMode()
            } catch {
                parsed = nil
                plan = nil
                parseError = L(.importStructureFailed, ErrorPresenter.message(for: error))
            }
        }
    }

    /// 执行（或先请求确认）。**安全检查在 AppState 里做**：这里只把结论翻成界面动作。
    private func run(bypassingSafetyCheck: Bool) {
        guard let plan, let parsed else {
            parseError = L(.importNeedsParsedFile)
            return
        }
        let target = parsedTarget
        let request = TableImportRequest(
            table: target.table,
            schema: target.schema,
            plan: plan,
            rows: parsed.rows,
            mode: mode,
            bypassingSafetyCheck: bypassingSafetyCheck
        )
        switch appState.startTableImport(request) {
        case .started:
            break
        case .needsConfirmation(let decision):
            // 只弹确认，**一行都不写** —— 确认后走 `bypassingSafetyCheck: true` 再回来。
            pendingConfirmation = decision
        case .refused:
            // 理由已由 `startTableImport` 写进 `importError`（只读连接等），这里不再重复一遍。
            break
        }
    }
}
