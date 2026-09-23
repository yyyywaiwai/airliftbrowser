import SwiftUI
import QuickLookUI

struct AppEditorView: View {
    @Bindable var manager: AppManager
    @State private var confirmClose = false

    var body: some View {
        if let document = manager.editor {
            VStack(spacing: 0) {
                HStack {
                    Text(document.file.name).font(.headline).lineLimit(1)
                    if document.isDirty { Text("未保存").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Button("閉じる", systemImage: "xmark") {
                        if document.isDirty { confirmClose = true } else { manager.closeEditor() }
                    }.labelStyle(.iconOnly)
                }.padding(12)
                HStack {
                    Picker("表示形式", selection: Binding(get: { document.mode }, set: { manager.changeEditorMode($0) })) {
                        Text("テキスト").tag("text")
                        Text("plist").tag("plist")
                        Text("16進数").tag("hex")
                        Text("プレビュー").tag("preview")
                    }.disabled(document.isDirty)
                    Button("保存", systemImage: "checkmark", action: manager.saveEditor)
                        .disabled(!document.isDirty || !manager.canEdit).keyboardShortcut("s")
                }.padding(.horizontal, 12).padding(.bottom, 10)
                Divider()
                if document.mode == "preview" {
                    AppFilePreview(url: document.localURL)
                } else {
                    TextEditor(text: Binding(get: { manager.editor?.text ?? "" }, set: { manager.editor?.text = $0 }))
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .padding(6)
                        .accessibilityLabel(document.mode == "hex" ? "16進数エディタ" : "ファイルエディタ")
                        .disabled(!manager.canEdit)
                }
                if document.mode == "hex" {
                    Divider()
                    HStack {
                        Button("前のページ", systemImage: "chevron.left") { manager.editorPage(-1) }
                            .labelStyle(.iconOnly).disabled(document.offset == 0 || document.isDirty)
                        Text("\(document.offset)–\(document.offset + Int64(document.pageBytes)) / \(document.size) bytes")
                            .font(.caption).monospacedDigit()
                        Button("次のページ", systemImage: "chevron.right") { manager.editorPage(1) }
                            .labelStyle(.iconOnly).disabled(document.offset + 4096 >= document.size || document.isDirty)
                    }.padding(10)
                }
            }
            .disabled(manager.busy)
            .confirmationDialog("編集内容を破棄しますか？", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("破棄して閉じる", role: .destructive, action: manager.closeEditor)
            }
        }
    }
}
