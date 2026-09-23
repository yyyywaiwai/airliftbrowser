import SwiftUI

struct AppWorkspaceView: View {
    @Bindable var manager: AppManager
    let deviceID: String?
    let library: Bool
    @State private var restoreSource: AppBackup?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Text(library ? "バックアップ" : "アプリ").font(.headline)
                        Spacer()
                        Button("一覧を再取得", systemImage: "arrow.clockwise") {
                            manager.activate(device: deviceID, library: library)
                        }.labelStyle(.iconOnly).buttonStyle(.plain)
                        Text("\(library ? manager.visibleBackups.count : manager.visibleApps.count)")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.padding(14)
                    TextField(library ? "バックアップを検索" : "名前・Bundle IDを検索", text: $manager.search)
                        .accessibilityLabel(library ? "バックアップを検索" : "アプリを検索")
                        .accessibilityIdentifier("app-manager-search")
                        .textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 10)
                    if !library {
                        Picker("種類", selection: $manager.category) {
                            Text("すべて").tag("all")
                            Text("ユーザー").tag("user")
                            Text("標準").tag("system")
                            Text("残存").tag("orphan")
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
                            }
                        }
                        .onChange(of: manager.backupID) { manager.selectBackup(manager.backupID) }
                    } else {
                        List(selection: $manager.appID) {
                            ForEach(manager.visibleApps) { app in
                                ManagedAppRow(app: app).tag(app.id)
                            }
                        }
                        .onChange(of: manager.appID) { manager.selectApp(manager.appID) }
                    }
                }
                .frame(minWidth: 210, idealWidth: 265, maxWidth: 360)
                .disabled(manager.busy || manager.editor?.isDirty == true)
                if manager.canBrowse {
                    AppDetailView(manager: manager, restoreSource: $restoreSource)
                        .frame(minWidth: 420, maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        library ? "バックアップを選択" : deviceID == nil ? "USBデバイスを接続" : "アプリを選択",
                        systemImage: library ? "archivebox" : "square.grid.2x2",
                        description: Text(library ? "保存したアプリは、端末を接続せずに閲覧・編集できます。" : "アプリのデータ・App Group・本体を管理します。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if !manager.pending.isEmpty {
                HStack {
                    Label("\(manager.pending.count) 件の未完了操作", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("未完了操作を復旧", action: manager.recover).disabled(manager.busy)
                }.padding(12).background(.orange.opacity(0.1))
            }
            if !manager.warnings.isEmpty {
                DisclosureGroup("取得状況・詳細 (\(manager.warnings.count))") {
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
                if manager.busy { Button("中止", action: manager.cancel).controlSize(.small) }
                else { Text(library ? "Mac上のバックアップ" : "USB · アプリ単位").foregroundStyle(.tertiary) }
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .navigationTitle(library ? "バックアップ" : "アプリ管理")
        .toolbar {
            ToolbarItemGroup {
                Group {
                Button("更新", systemImage: "arrow.clockwise", action: manager.refresh).keyboardShortcut("r")
                Button("読み込み", systemImage: "square.and.arrow.down", action: manager.importBackup)
                Menu("転送設定", systemImage: "slider.horizontal.3") {
                    Toggle("バックアップ／リストアの内容検証", isOn: $manager.verificationEnabled)
                }
                .accessibilityLabel("転送設定")
                .help("バックアップ／リストアの内容検証を設定")
                if !library {
                    Button("アプリ全体をバックアップ", systemImage: "archivebox", action: manager.backupApp)
                        .disabled(manager.app == nil || manager.regions.isEmpty || deviceID == nil)
                } else if let backup = manager.backup {
                    Menu("書き出し", systemImage: "square.and.arrow.up") {
                        Button("Airliftバックアップ…") { manager.exportBackup(backup, xcappdata: false) }
                        Button("xcappdata…") { manager.exportBackup(backup, xcappdata: true) }
                            .disabled(!backup.regions.contains { $0.kind == "data" })
                    }
                    Button("リストア", systemImage: "arrow.uturn.backward") { restoreSource = backup }
                        .disabled(deviceID == nil || backup.regions.isEmpty || backup.status == "incomplete")
                }
                }.disabled(manager.busy || manager.editor?.isDirty == true)
            }
        }
        .task(id: "\(deviceID ?? "offline")-\(library)") { manager.activate(device: deviceID, library: library) }
        .sheet(isPresented: Binding(
            get: { restoreSource != nil || manager.operation != nil },
            set: { if !$0 && !manager.busy { restoreSource = nil; manager.operation = nil } }
        )) {
            if let operation = manager.operation {
                AppOperationView(operation: operation, cancel: manager.cancel) {
                    restoreSource = nil
                    manager.operation = nil
                }
                .frame(width: max(760, (NSApp.mainWindow?.contentLayoutRect.width ?? 960) - 40),
                       height: max(480, (NSApp.mainWindow?.contentLayoutRect.height ?? 690) - 40))
            } else if let source = restoreSource {
                AppRestoreView(manager: manager, backup: source)
            }
        }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { manager.error != nil }, set: { if !$0 { manager.error = nil } })) {
            Button("OK", role: .cancel) { manager.error = nil }
        } message: { Text(manager.error ?? "") }
    }
}
