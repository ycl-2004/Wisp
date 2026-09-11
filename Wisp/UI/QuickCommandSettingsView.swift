import KeyboardShortcuts
import SwiftUI

/// 常用指令：左边是列表（拖动排序、增删），右边编辑选中的那一条。
struct QuickCommandSettingsView: View {
    @ObservedObject private var store = QuickCommandStore.shared
    @State private var selection: QuickCommand.ID?
    @State private var confirmsRestore = false

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 200)
            Divider()
            if let index = store.commands.firstIndex(where: { $0.id == selection }) {
                editor($store.commands[index])
            } else {
                Text("选择或新建一条指令")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.commands.first?.id } }
        .confirmationDialog("恢复默认指令？", isPresented: $confirmsRestore) {
            Button("恢复默认", role: .destructive) {
                store.restoreDefaults()
                selection = store.commands.first?.id
            }
        } message: {
            Text("自己加的和改过的指令都会被替换，它们的快捷键也会清掉。")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("常用指令").font(.system(size: 13, weight: .semibold))
                InfoButton(message: String(localized: "指令连同当前屏幕上下文一起发送，就像你亲手输入的问题。输入框里已经写了东西时，那段文字会作为材料跟在指令后面，比如先贴一段话再点「翻译」。快捷键在任何应用里都能用：先唤起面板读取当前窗口，再执行。"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            List(selection: $selection) {
                ForEach(store.commands) { command in
                    Label(command.displayTitle,
                          systemImage: command.symbol)
                        .lineLimit(1)
                        .help(command.displayTitle)
                        .tag(command.id)
                }
                .onMove { store.commands.move(fromOffsets: $0, toOffset: $1) }
            }
            HStack(spacing: 2) {
                Button { selection = store.add().id } label: { Image(systemName: "plus").frame(width: 20, height: 18) }
                    .help("新建指令")
                    .accessibilityLabel("新建指令")
                Button {
                    guard let id = selection else { return }
                    let index = store.commands.firstIndex { $0.id == id } ?? 0
                    store.delete(id)
                    selection = store.commands.indices.contains(index) ? store.commands[index].id : store.commands.last?.id
                } label: { Image(systemName: "minus").frame(width: 20, height: 18) }
                    .disabled(selection == nil)
                    .help("删除选中的指令")
                    .accessibilityLabel("删除选中的指令")
                Spacer()
                Button("恢复默认") { confirmsRestore = true }
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func editor(_ command: Binding<QuickCommand>) -> some View {
        Form {
            TextField("名称", text: command.title)
            Picker("回答模式", selection: command.mode) {
                Text("跟随当前模式").tag(ResponseMode?.none)
                ForEach(ResponseMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(Optional(mode))
                }
            }
            KeyboardShortcuts.Recorder("快捷键", name: command.wrappedValue.shortcutName)
            Section {
                TextEditor(text: command.prompt)
                    .font(DS.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.chipCorner, style: .continuous)
                            .strokeBorder(DS.hairline, lineWidth: 0.5)
                    )
                    .accessibilityLabel("提问内容")
            } header: {
                Text("提问内容")
            }
        }
        .formStyle(.grouped)
    }
}
