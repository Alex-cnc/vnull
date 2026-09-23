import SwiftUI
import AppKit
import DoyahCore

/// 行详情侧栏（FR-DATA-05 的界面部分）：把**一行**按列顺序竖排出来。
///
/// 为什么要有它：宽表（几十列）在结果表里必须横向滚来滚去才看得全一行，长 JSON 更惨 ——
/// 它被压进一个单元格宽度，只能靠 tooltip 猜。侧栏把"一行"摊成竖直的一列字段、
/// 值用等宽字体保留换行，对标 Postico 的行详情侧栏 / DataGrip 的 Value Editor。
///
/// **它只做排版**：形态判定、JSON 美化、截断与长度报告全在 `Core/CellInspector`
/// （那一层能单测，界面这一层不能）。三条语义必须原样透出来，不许被排版抹平：
///   ① **NULL ≠ 空字符串** —— 写回数据库时前者是"没有值"、后者是"值是零个字符"；
///   ② JSON 已美化（键按字典序）且**保留换行** —— 不要用单行截断样式把它压回一行；
///   ③ 截断要**同时**说出原始长度（用 Core 给的 `summary`）—— 只说一句"…"，
///      用户会以为看到的就是全部。
///
/// 外观全部走设计令牌（`Theme` / `Spacing` / `Radius` / `HairlineView`）：
/// 系统文本样式与语义色不在我们的字号刻度与色板里，混用就会出现"这块跟别处差一点点"。
struct RowDetailPanel: View {

    /// 列定义：决定字段的**顺序与条数**，与结果表看到的完全一致。
    let columns: [ColumnMeta]

    /// 选中的那一行。**必须是调用方按分页内索引取出的 `page.rows[index]`** ——
    /// 传错来源就会出现"侧栏显示的不是我选的那行"，那是欺骗性显示，不是小瑕疵。
    /// nil = 当前没有有效选中行（没选，或索引已越界）。
    let row: [String?]?

    /// 选中行在**当前结果视图**里的 1 起序号（已含分页偏移），只用于标题。
    ///
    /// 筛选 / 排序之后它是"视图里的第几行"，不是数据库里的行号 —— 所以不加文案解释，
    /// 免得把"视图位置"说成"表里的第 N 行"。
    var rowNumber: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineView()

            if let row {
                fieldList(row)
            } else {
                noSelection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface(.panel))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Text(L(.rowDetailTitle))
                .font(Theme.font(.title))
                .foregroundStyle(Theme.text(.primary))

            if let rowNumber {
                // `#N` 不配文案：它是视图内序号，用语言无关的记号就够，
                // 也免得为一个数字再添一个本地化键。
                Text("#\(rowNumber)")
                    .font(Theme.font(.data))
                    .foregroundStyle(Theme.text(.tertiary))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
    }

    /// 没选中任何行时的空态。这里要把"为什么是空的"说清楚，
    /// 否则一片留白会被当成渲染坏了。
    private var noSelection: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "sidebar.trailing")
                .imageScale(.large)
                .foregroundStyle(Theme.text(.tertiary))

            // 文案里带 `**` 强调：`Text(String)` **不解析** Markdown，会原样显示星号；
            // 走 `LocalizedStringKey` 才会把强调渲染出来（译文字符串查不到就回落到它自己）。
            Text(LocalizedStringKey(L(.rowDetailNoSelection)))
                .font(Theme.font(.body))
                .foregroundStyle(Theme.text(.secondary))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.l)
    }

    // MARK: - 字段列表（竖排）

    private func fieldList(_ row: [String?]) -> some View {
        // 竖排的代价是行数 = 列数，宽表要滚很久；`LazyVStack` 让"滚过去的字段"
        // 不参与布局，200 列的表也不会卡在首屏。
        let fields = CellInspector.row(columns: columns, row: row)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(fields.indices, id: \.self) { index in
                    fieldCard(fields[index], raw: row.indices.contains(index) ? row[index] : nil)
                    HairlineView()
                }
            }
        }
    }

    private func fieldCard(_ field: CellInspector.Field, raw: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(field.columnName)
                    .font(Theme.font(.bodyStrong))
                    .foregroundStyle(Theme.text(.primary))
                    .lineLimit(1)
                    // 宽表的列名很容易比侧栏还宽；中间截断比尾部截断更容易认出是哪一列。
                    .truncationMode(.middle)
                    .help(field.columnName)

                // 类型名是**弱化**信息：它回答"这值该怎么读"，但不该跟列名抢注意力。
                Text(field.typeName)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .lineLimit(1)

                Spacer(minLength: Spacing.xs)

                copyButton(raw: raw)
            }

            valueView(field.value)

            // 摘要行：形态 + 原始长度 + 行数 + 是否截断。只在它比正文多说了一点时才显示 ——
            // NULL / 空串的摘要就是正文本身，再抄一遍只是噪音。
            if let summary = summaryLine(for: field.value) {
                Text(summary)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 值

    @ViewBuilder
    private func valueView(_ value: CellInspector.Value) -> some View {
        switch value.shape {
        case .null:
            // NULL 用弱化斜体，与空字符串**长得不一样**：这两者在界面上一旦混同，
            // 用户就会把"没有值"当成"值是空串"（写回时结果完全不同）。
            Text(value.display)
                .font(Theme.font(.mono))
                .italic()
                .foregroundStyle(Theme.text(.tertiary))

        case .empty:
            // 空串用 SQL 的空串字面量 `''` 表示：语言无关，也不会与 NULL 混淆。
            // （Core 的 `summary` 对空串给的是中文"空字符串"，放进英文界面不合适，
            //   所以这里只拿它当 tooltip，不当作正文。）
            Text("''")
                .font(Theme.font(.mono))
                .italic()
                .foregroundStyle(Theme.text(.tertiary))
                .help(value.summary)

        default:
            // **不要**加 `lineLimit(1)` / `truncationMode(...)`：JSON 已经美化换行，
            // 压成一行就等于把"格式化查看"这件事又收回去。
            // `fixedSize(horizontal: false, vertical: true)` 是让长值在 LazyVStack 里
            // 按真实高度撑开 —— 不给它的话会被压扁成一行高。
            Text(value.display)
                .font(Theme.font(.mono))
                .foregroundStyle(Theme.text(.primary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryLine(for value: CellInspector.Value) -> String? {
        switch value.shape {
        case .null, .empty:
            // 摘要就是 "NULL" / "空字符串"，正文已经把它说完了。
            return nil
        default:
            return value.summary
        }
    }

    /// 复制**原始值**（不是美化后的展示文本、也不是被截断的那一截）：
    /// 用户点"复制值"是想把它贴进别处，贴出来必须是数据库里真正存着的东西。
    /// NULL 没有"值"可复制，所以按钮禁用而不是复制一个 "NULL" 字面量进去。
    private func copyButton(raw: String?) -> some View {
        Button {
            guard let raw else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(raw, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .disabled(raw == nil)
        .help(L(.rowDetailCopyValue))
    }
}
