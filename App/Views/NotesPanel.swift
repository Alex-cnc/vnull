import DoyahCore
import SwiftUI

/// 「笔记」面板（DOYAH-01 / 03）：左侧列表 + 右侧编辑，来源与「含数据」标记都露出来。
///
/// 两条刻意的口径：
/// ① **来源与「含数据」必须一眼可见** —— 笔记将来会同步到云端，"这条是哪来的、含不含数据"
///    是用户必须能直接看出来的事实，不能藏在详情里；
/// ② 编辑已有笔记时**保留原来源**（来源是事实，不该因为改了几个字就丢掉）。
struct NotesPanel: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 240, idealWidth: 280)
                editor
                    .frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 620)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L(.notesTitle))
                .font(Theme.font(.title))
            Text("\(appState.notes.count)")
                .font(Theme.font(.caption))
                .foregroundStyle(Theme.text(.secondary))
            Spacer()
            Button(L(.commonClose)) { dismiss() }
        }
        .padding(Spacing.l)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField(L(.notesSearchPlaceholder), text: $appState.notesQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Spacing.s)
            if appState.visibleNotes.isEmpty {
                Text(L(.notesEmpty))
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
                }
            }
        }
        .padding(.vertical, Spacing.s)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField(L(.notesUntitled), text: $appState.noteEditorTitle)
                .textFieldStyle(.roundedBorder)
            TextField(L(.notesSearchPlaceholder), text: $appState.noteEditorTags)
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
                Spacer()
            }
        }
        .padding(Spacing.l)
    }

    private var footer: some View {
        HStack(spacing: Spacing.m) {
            Button(L(.notesNew)) { appState.beginNewNote() }
            Spacer()
        }
        .padding(Spacing.l)
    }
}
