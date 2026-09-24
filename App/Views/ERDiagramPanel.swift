import DoyahCore
import SwiftUI

/// 「ER 图 / 关系图」面板（FR-DDL-05 的界面）。
///
/// 需求原文是「由外键生成可视化关系图」。这一版把 Core 已经算好的东西画出来：
/// **布局在 Core 里**（分层 + 走线 + 确定性），这里只负责把节点与连线画到画布上，
/// 因此"图每次打开位置都在跳""两张表叠在一起"这类问题不会出现在视图层。
///
/// 三处刻意的取舍：
/// ① **节点只画前若干列**（超出部分写 `…还有 N 列`）—— 一张 200 列的表会把画布撑到没法看，
///    而 ER 图要看的是**关系**，不是列清单；
/// ② **成环的表会点名提示**（`cyclicTables`）：它们无法拓扑排序、被放到最后一层，
///    不说一句的话，看的人会以为布局算错了；
/// ③ 面板**不写库、不执行任何语句**：只读元数据 + 复制 / 导出文本，没有第二条执行动线。
struct ERDiagramPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var schema = "public"
    @State private var diagram: ERDiagram?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var didCopy: String?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var layout: ERDiagram.Layout? { diagram?.layout() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            canvasArea
            Divider()
            footer
        }
        .frame(width: 900, height: 720)
        .onAppear { if diagram == nil { Task { await load() } } }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L(.erDiagramTitle))
                .font(Theme.font(.title))
            Text(L(.erDiagramHint))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: 控件

    private var controls: some View {
        HStack(spacing: Spacing.m) {
            Text(L(.erDiagramSchema))
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            TextField("", text: $schema)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            Button(L(.erDiagramGenerate)) { Task { await load() } }
                .disabled(isLoading)
            if isLoading { ProgressView().controlSize(.small) }

            Spacer()

            Button {
                copyDiagram { $0.mermaid() }
            } label: {
                Label(L(.erDiagramCopyMermaid), systemImage: "doc.on.doc")
            }
            .disabled(diagram?.isEmpty ?? true)

            Button {
                copyDiagram { $0.dot() }
            } label: {
                Label(L(.erDiagramCopyDOT), systemImage: "doc.on.doc")
            }
            .disabled(diagram?.isEmpty ?? true)

            Button {
                exportMermaid()
            } label: {
                Label(L(.erDiagramExport), systemImage: "square.and.arrow.up")
            }
            .disabled(diagram?.isEmpty ?? true)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    // MARK: 画布

    private var canvasArea: some View {
        ZStack {
            Theme.surface(.content)
            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.status(.danger))
                    .padding(Spacing.l)
            } else if let diagram, diagram.isEmpty {
                Text(L(.erDiagramEmpty))
                    .font(Theme.font(.body))
                    .foregroundStyle(Theme.text(.secondary))
            } else if let diagram, let layout {
                diagramCanvas(diagram: diagram, layout: layout)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func diagramCanvas(diagram: ERDiagram, layout: ERDiagram.Layout) -> some View {
        GeometryReader { geometry in
            let fitted = fitScale(layout: layout, size: geometry.size)
            Canvas { context, _ in
                let effective = scale * fitted
                context.translateBy(x: offset.width, y: offset.height)
                context.scaleBy(x: effective, y: effective)

                // 先画线再画节点：连线落在节点下面，看起来才像"接在框上"。
                for edge in layout.edges {
                    draw(edge: edge, in: &context)
                }
                for node in layout.nodes {
                    draw(node: node, diagram: diagram, in: &context)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in scale = min(3, max(0.2, lastScale * value)) }
                    .onEnded { _ in lastScale = scale }
            )
        }
    }

    /// 让整张图默认铺满可视区（用户再自己缩放 / 拖动）。
    private func fitScale(layout: ERDiagram.Layout, size: CGSize) -> CGFloat {
        guard layout.width > 0, layout.height > 0, size.width > 0, size.height > 0 else { return 1 }
        let margin: CGFloat = Spacing.xxl
        return min(1, (size.width - margin) / layout.width, (size.height - margin) / layout.height)
    }

    private func draw(edge: ERDiagram.Layout.RoutedEdge, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: edge.start.x, y: edge.start.y))
        let control = CGPoint(x: edge.waypoint.x, y: edge.waypoint.y)
        path.addQuadCurve(to: CGPoint(x: edge.end.x, y: edge.end.y), control: control)
        context.stroke(
            path,
            with: .color(Theme.text(.tertiary)),
            style: StrokeStyle(lineWidth: 1, dash: edge.isSelfReference ? [3, 2] : [])
        )

        // 箭头画在被引用的一方（父表）：方向语义要看得出来。
        var arrow = Path()
        let tip = CGPoint(x: edge.end.x, y: edge.end.y)
        arrow.move(to: CGPoint(x: tip.x - 5, y: tip.y + 8))
        arrow.addLine(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x + 5, y: tip.y + 8))
        context.stroke(arrow, with: .color(Theme.text(.tertiary)), lineWidth: 1)

        context.draw(
            Text(edge.label)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.tertiary)),
            at: CGPoint(x: edge.waypoint.x, y: edge.waypoint.y - 6),
            anchor: .bottom
        )
    }

    private func draw(node: ERDiagram.Layout.Node, diagram: ERDiagram, in context: inout GraphicsContext) {
        guard let table = diagram.tables.first(where: { $0.qualifiedName == node.table }) else { return }
        let rect = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
        let rounded = Path(roundedRect: rect, cornerRadius: Radius.card)

        context.fill(rounded, with: .color(Theme.surface(.raised)))
        context.stroke(rounded, with: .color(Theme.hairline(colorScheme)), lineWidth: Metrics.hairline)

        // 表头
        let headerRect = CGRect(x: node.x, y: node.y, width: node.width, height: ERDiagram.Layout.defaultHeaderHeight)
        context.fill(
            Path(roundedRect: headerRect, cornerRadius: Radius.card),
            with: .color(Theme.accentColor.opacity(0.16))
        )
        context.draw(
            Text(table.qualifiedName)
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.primary)),
            at: CGPoint(x: node.x + Spacing.s, y: node.y + ERDiagram.Layout.defaultHeaderHeight / 2),
            anchor: .leading
        )

        // 列：`名字 类型`，主键 / 外键各自一个记号。
        let visible = min(table.columns.count, ERDiagram.Layout.defaultMaximumVisibleColumns)
        for index in 0..<visible {
            let column = table.columns[index]
            let y = node.y + ERDiagram.Layout.defaultHeaderHeight + Double(index) * ERDiagram.Layout.defaultRowHeight + ERDiagram.Layout.defaultRowHeight / 2
            var label = column.name
            if !column.typeName.isEmpty { label += "  \(column.typeName)" }
            if column.isPrimaryKey { label = "🔑 " + label }
            if column.isForeignKey { label = "↗ " + label }
            context.draw(
                Text(label)
                    .font(Theme.font(.caption))
                    .foregroundStyle(column.isPrimaryKey || column.isForeignKey ? Theme.text(.primary) : Theme.text(.secondary)),
                at: CGPoint(x: node.x + Spacing.s, y: y),
                anchor: .leading
            )
        }
        if table.columns.count > visible {
            context.draw(
                Text(L(.erDiagramMoreColumns, table.columns.count - visible))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.tertiary)),
                at: CGPoint(x: node.x + Spacing.s, y: node.y + ERDiagram.Layout.defaultHeaderHeight + Double(visible) * ERDiagram.Layout.defaultRowHeight + ERDiagram.Layout.defaultRowHeight / 2),
                anchor: .leading
            )
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            if let diagram {
                Text(L(.erDiagramSummary, diagram.tables.count, diagram.relationships.count))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                if let cyclic = layout?.cyclicTables, !cyclic.isEmpty {
                    // 成环无法拓扑排序 —— 说清楚它们在最后一层，而不是让人以为布局算错了。
                    Text(L(.erDiagramCyclic, cyclic.joined(separator: "、")))
                        .font(Theme.font(.caption))
                        .foregroundStyle(Theme.text(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let didCopy {
                Text(didCopy)
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.status(.success))
            }
            Spacer()
            HStack(spacing: Spacing.xs) {
                Button { scale = max(0.2, scale - 0.1); lastScale = scale } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help(L(.erDiagramZoomOut))
                Button { scale = min(3, scale + 0.1); lastScale = scale } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help(L(.erDiagramZoomIn))
                Button(L(.erDiagramFit)) {
                    scale = 1
                    lastScale = 1
                    offset = .zero
                    lastOffset = .zero
                }
            }
            Button(L(.commonClose)) { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    // MARK: 动作

    private func load() async {
        isLoading = true
        errorMessage = nil
        didCopy = nil
        do {
            let loaded = try await appState.erDiagram(schema: schema, database: nil)
            diagram = loaded
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        } catch {
            diagram = nil
            errorMessage = ErrorPresenter.message(for: error)
        }
        isLoading = false
    }

    private func copyDiagram(_ build: (ERDiagram) -> String) {
        guard let diagram else { return }
        let text = build(diagram)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopy = L(.schemaDiffCopied)
    }

    private func exportMermaid() {
        guard let diagram else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(schema)-er.mmd"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagram.mermaid().write(to: url, atomically: true, encoding: .utf8)
            didCopy = L(.erDiagramExported, url.lastPathComponent)
        } catch {
            errorMessage = ErrorPresenter.message(for: error)
        }
    }
}
