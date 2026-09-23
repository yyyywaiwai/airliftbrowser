import SwiftUI

struct AppFilesView: View {
    @Bindable var manager: AppManager
    @State private var showName = false
    @State private var newName = ""
    @State private var renameFile: AppFile?
    @State private var deleteFile: AppFile?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("上のフォルダ", systemImage: "arrow.up") {
                    let parts = manager.relativePath.split(separator: "/").dropLast()
                    manager.navigate(parts.joined(separator: "/"))
                }.labelStyle(.iconOnly).disabled(manager.relativePath.isEmpty)
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        Button("ルート") { manager.navigate("") }
                        let parts = manager.relativePath.split(separator: "/").map(String.init)
                        ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Button(part) { manager.navigate(parts.prefix(index + 1).joined(separator: "/")) }
                        }
                    }.buttonStyle(.plain)
                }
                TextField("このフォルダを検索", text: $manager.fileSearch)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
            }.padding(12).disabled(manager.busy || manager.editor?.isDirty == true)
            HSplitView {
                Table(manager.visibleFiles, selection: $manager.selection) {
                    TableColumn("名前") { file in
                        Label(file.name, systemImage: file.symbol)
                            .foregroundStyle(file.isDirectory ? Color.accentColor : Color.primary)
                    }.width(min: 140, ideal: 250)
                    TableColumn("サイズ") { file in Text(file.sizeLabel).monospacedDigit() }.width(85)
                    TableColumn("種類", value: \.kindLabel).width(70)
                    TableColumn("更新日時") { file in
                        Text(Date(timeIntervalSince1970: file.modified), format: .dateTime.year().month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }.width(135)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first, let file = manager.files.first(where: { $0.id == id }) {
                        Button(file.isDirectory ? "開く" : "閲覧・編集") { manager.openFile(file) }
                        Button("Macに保存…") { manager.exportFile(file) }
                        Divider()
                        Button("名前を変更…") { renameFile = file; newName = file.name; showName = true }
                            .disabled(!manager.canEdit)
                        Button("削除…", role: .destructive) { deleteFile = file }
                            .disabled(!manager.canEdit)
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let file = manager.files.first(where: { $0.id == id }) {
                        manager.openFile(file)
                    }
                }
                .disabled(manager.busy || manager.editor?.isDirty == true)
                .overlay {
                    if manager.visibleFiles.isEmpty && !manager.busy {
                        ContentUnavailableView(manager.fileListingError != nil ? "一覧を取得できませんでした" : manager.fileSearch.isEmpty ? "項目はありません" : "一致する項目はありません",
                                               systemImage: "folder", description: Text(manager.fileListingError ?? ""))
                            .allowsHitTesting(false)
                    }
                }
                if manager.editor != nil {
                    AppEditorView(manager: manager).frame(minWidth: 320, idealWidth: 420)
                }
            }
            Divider()
            HStack {
                Button("開く", systemImage: "doc.text.magnifyingglass") {
                    if let file = manager.selectedFile { manager.openFile(file) }
                }
                .disabled(manager.selectedFile == nil || manager.selectedFile?.kind == "link" || manager.selectedFile?.kind == "other")
                Button("フォルダ作成", systemImage: "folder.badge.plus") {
                    renameFile = nil; newName = ""; showName = true
                }.disabled(!manager.canEdit)
                Menu("送信", systemImage: "square.and.arrow.up") {
                    Button("ファイル／フォルダを追加…") { manager.upload(overwrite: false) }
                    Button("同名項目を上書きして送信…") { manager.upload(overwrite: true) }
                }.disabled(!manager.canEdit)
                Button("Macに保存", systemImage: "square.and.arrow.down") {
                    if let file = manager.selectedFile { manager.exportFile(file) }
                }.disabled(manager.selectedFile == nil)
                Spacer()
                Text("\(manager.visibleFiles.count) 項目").font(.caption).foregroundStyle(.secondary)
            }.controlSize(.small).padding(12)
                .disabled(manager.busy || manager.regionID == nil || manager.editor?.isDirty == true)
        }
        .sheet(isPresented: $showName) {
            VStack(alignment: .leading, spacing: 16) {
                Text(renameFile == nil ? "フォルダを作成" : "名前を変更").font(.headline)
                TextField("名前", text: $newName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("キャンセル", role: .cancel) { showName = false }
                    Button("保存") {
                        manager.mutate(operation: renameFile == nil ? "mkdir" : "rename", file: renameFile, name: newName)
                        showName = false
                    }.keyboardShortcut(.defaultAction).disabled(newName.isEmpty)
                }
            }.padding(24).frame(width: 360)
        }
        .confirmationDialog("「\(deleteFile?.name ?? "")」を削除しますか？", isPresented: Binding(
            get: { deleteFile != nil }, set: { if !$0 { deleteFile = nil } }), titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let file = deleteFile { manager.mutate(operation: "delete", file: file) }
                    deleteFile = nil
                }
            }
    }
}
