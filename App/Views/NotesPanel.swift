import DoyahCore
import SwiftUI

/// 笔记区的两块（DOYAH-01 / 03）：**列表**进侧栏、**编辑器**进右侧。
///
/// 为什么拆成两个视图而不是原来那个"一个面板装下所有"：
/// 笔记在 Standard 下就是**整个应用**（活动栏只有它一项），必须有正经的侧栏 + 正文两栏，
/// 而不是浮在别人界面上的一个弹窗 —— 弹窗被关掉以后，用户会不确定笔记还在不在。
/// 两栏的分工也正好对上活动栏的信息架构：「看哪个视图」（笔记）与「视图里看什么」（哪一条）。
///
/// 两条刻意的口径（与拆分前一致）：
/// ① **来源与「含数据」必须一眼可见** —— 笔记将来会同步到云端，"这条是哪来的、含不含数据"
///    是用户必须能直接看出来的事实，不能藏在详情里；
/// ② 编辑已有笔记时**保留原来源**（来源是事实，不该因为改了几个字就丢掉）。
struct NotesListView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField(L(.notesSearchPlaceholder), text: $appState.notesQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Spacing.s)
            if appState.visibleNotes.isEmpty {
                // 分两种"空"：一条笔记都没有，和"搜不到"—— 后者要提示改搜索词，
                // 否则用户会以为笔记丢了。
                Text(appState.notesQuery.isEmpty ? L(.notesEmpty) : L(.noteSearchNoMatch))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                    .padding(Spacing.s)
                Spacer()
            } else {
                List(appState.visibleNotes) { note in
                    Button {
                        appState.edit(note)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Spacing.xs) {
                                Text(note.title)
                                    .font(Theme.font(.body))
                                    .lineLimit(1)
                                if note.containsRowData {
                                    Text(L(.notesContainsRowData))
                                        .font(Theme.font(.caption))
                                        .foregroundStyle(Theme.status(.warning))
                                }
                            }
                            Text(note.source.kind.displayName + " · " + (note.source.connectionName ?? "—"))
                                .font(Theme.font(.caption))
                                .foregroundStyle(Theme.text(.secondary))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note-row-\(note.id.uuidString)")
                }
            }
        }
        .padding(.vertical, Spacing.s)
        .accessibilityIdentifier("notes-list")
    }
}

/// 笔记正文（标题 / 标签 / 正文 / 保存 + 新建）。
struct NotesEditorView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(.notesTitle))
                    .font(Theme.font(.title))
                Text("\(appState.notes.count)")
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                Spacer()
                Button(L(.notesNew)) { appState.beginNewNote() }
            }
            TextField(L(.notesUntitled), text: $appState.noteEditorTitle)
                .textFieldStyle(.roundedBorder)
            TextField(L(.notesTagsPlaceholder), text: $appState.noteEditorTags)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(.caption))
            TextEditor(text: $appState.noteEditorBody)
                .font(Theme.font(.mono))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.surface(.panel), lineWidth: 1)
                )
            HStack(spacing: Spacing.s) {
                Button(L(.notesSave)) {
                    Task { await appState.saveNoteFromEditor() }
                }
                .keyboardShortcut(.defaultAction)
                Text(L(.notesSourceHint))
                    .font(Theme.font(.caption))
                    .foregroundStyle(Theme.text(.secondary))
                Spacer()
            }
        }
        .padding(Spacing.l)
        .accessibilityIdentifier("notes-editor")
    }
}
