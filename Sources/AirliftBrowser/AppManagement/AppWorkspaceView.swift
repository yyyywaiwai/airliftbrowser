import SwiftUI

struct AppWorkspaceView: View {
    @Bindable var manager: AppManager
    let deviceID: String?
    let library: Bool
    @State private var restoreSource: AppBackup?
    @State private var showBackup = false
    @State private var backupName = ""

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(library ? "バックアップ" : "アプリ").font(.headline)
                        Spacer()
                        Button("一覧を更新", systemImage: "arrow.clockwise") {
                            manager.activate(device: deviceID, library: library)
                        }.labelStyle(.iconOnly).buttonStyle(.plain)
                        Text("\(library ? manager.visibleBackups.count : manager.visibleApps.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.padding(14)
                    TextField(library ? "バックアップを検索" : "アプリを検索", text: $manager.search)
                        .accessibilityIdentifier("app-manager-search")
                        .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
                    if !library {
                        Picker("種類", selection: $manager.category) {
                            Text("すべて").tag("all")
                            Text("インストール済み").tag("user")
                            Text("Apple製").tag("system")
                            Text("残りデータ").tag("orphan")
                        }.labelsHidden().padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    if library {
                        List(selection: $manager.backupID) {
                            ForEach(manager.visibleBackups) { backup in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(backup.name, systemImage: "archivebox")
                                    Text(backup.dateLabel).font(.caption).foregroundStyle(.secondary)
                                    HStack {
                                        Text(backup.statusLabel)
                                        Spacer()
                                        Text(ByteCountFormatter.string(fromByteCount: backup.totalBytes, countStyle: .file))
                                    }.font(.caption2).foregroundStyle(backup.status == "complete" ? Color.secondary : Color.orange)
                                }.padding(.vertical, 5).tag(backup.id)
                                    .contextMenu {
                                        AppBackupMenu(manager: manager, backup: backup, restoreSource: $restoreSource)
                                    }
                            }
                        }
                        .onChange(of: manager.backupID) { manager.selectBackup(manager.backupID) }
                        .onDeleteCommand {
                            if let backup = manager.backup { manager.deleteBackup(backup) }
                        }
                    } else {
                        List(selection: $manager.appID) {
                            ForEach(manager.visibleApps) { app in
                                ManagedAppRow(app: app, deviceID: deviceID).tag(app.id)
                            }
                        }
                        .onChange(of: manager.appID) { manager.selectApp(manager.appID) }
                    }
                }
                .frame(minWidth: 210, idealWidth: 265, maxWidth: 360)
                .disabled(manager.busy)
                if manager.canBrowse {
                    AppDetailView(manager: manager, restoreSource: $restoreSource, showBackup: $showBackup)
                        .id(library ? manager.backupID : manager.appID)
                        .frame(minWidth: 420, maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        library ? "バックアップを選んでください" : deviceID == nil ? "iPhoneまたはiPadを接続してください" : "アプリを選んでください",
                        systemImage: library ? "archivebox" : "square.grid.2x2",
                        description: Text(library ? "保存したバックアップは、デバイスを接続しなくても中身を確認できます。" : "アプリのデータを表示したり、バックアップしたりできます。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !manager.pending.isEmpty {
                HStack {
                    Label("中断した処理が \(manager.pending.count) 件あります", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("中断した処理を復旧", action: manager.recover).disabled(manager.busy)
                }.padding(12).background(.orange.opacity(0.1))
            }
            if !manager.warnings.isEmpty {
                DisclosureGroup("詳細（\(manager.warnings.count)）") {
                    ScrollView { Text(manager.warnings.joined(separator: "\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
            }
            Divider()
            HStack {
                if manager.busy {
                    if let fraction = manager.fraction {
                        ProgressView(value: fraction).frame(width: 110)
                    } else { ProgressView().controlSize(.small) }
                }
                Text(manager.status).lineLimit(2)
                Spacer()
                Button("ログを表示") { manager.showOperation = true }
                    .controlSize(.small)
                    .disabled(manager.operation == nil)
                if manager.busy { Button("中止", action: manager.cancel).controlSize(.small) }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .navigationTitle(library ? "バックアップ" : "アプリ")
        .toolbar {
            ToolbarItemGroup {
                Group {
                Button("更新", systemImage: "arrow.clockwise", action: manager.refresh).keyboardShortcut("r")
                Button("バックアップを読み込み", systemImage: "square.and.arrow.down", action: manager.importBackup)
                if !library {
                    Button("バックアップ", systemImage: "archivebox") { showBackup = true }
                        .disabled(manager.app == nil || manager.regions.isEmpty || deviceID == nil)
                } else if let backup = manager.backup {
                    Menu("書き出し", systemImage: "square.and.arrow.up") {
                        Button("Airlift形式…") { manager.exportBackup(backup, xcappdata: false) }
                        Button("Xcode形式（.xcappdata）…") { manager.exportBackup(backup, xcappdata: true) }
                            .disabled(!backup.regions.contains { $0.kind == "data" })
                    }
                    Button("復元", systemImage: "arrow.uturn.backward") { restoreSource = backup }
                        .disabled(deviceID == nil || !backup.canRestore)
                    Button("削除", systemImage: "trash", role: .destructive) { manager.deleteBackup(backup) }
                        .help("選んだバックアップをゴミ箱に入れます")
                }
                }.labelStyle(.iconOnly).disabled(manager.busy)
            }
        }
        .task(id: "\(deviceID ?? "offline")-\(library)") { manager.activate(device: deviceID, library: library) }
        .sheet(isPresented: Binding(
            get: { showBackup || restoreSource != nil || manager.showOperation },
            set: { if !$0 { showBackup = false; restoreSource = nil; manager.showOperation = false } }
        )) {
            if manager.showOperation, let operation = manager.operation {
                AppOperationView(operation: operation, cancel: manager.cancel) {
                    showBackup = false
                    restoreSource = nil
                    manager.showOperation = false
                }
                .frame(width: max(760, (NSApp.mainWindow?.contentLayoutRect.width ?? 960) - 40),
                       height: max(480, (NSApp.mainWindow?.contentLayoutRect.height ?? 690) - 40))
            } else if let source = restoreSource {
                AppRestoreView(manager: manager, backup: source)
            } else if showBackup {
                AppBackupView(manager: manager)
            }
        }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("OK", role: .cancel) { manager.error = nil }
        } message: { Text(manager.error ?? "") }
        .alert("バックアップの名前を変更", isPresented: Binding(get: { manager.renamingBackup != nil }, set: { if !$0 { manager.renamingBackup = nil } })) {
            TextField("名前", text: $backupName)
            Button("変更") { if let backup = manager.renamingBackup { manager.renameBackup(backup, to: backupName) } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("空欄にするとアプリ名に戻ります。") }
        .onChange(of: manager.renamingBackup) { backupName = manager.renamingBackup?.name ?? "" }
    }
}
