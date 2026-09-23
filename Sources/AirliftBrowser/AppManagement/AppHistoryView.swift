import SwiftUI

struct AppHistoryView: View {
    @Bindable var manager: AppManager
    @Binding var restoreSource: AppBackup?

    var body: some View {
        let backups = manager.backups.filter { $0.bundleID == manager.app?.bundleID && !$0.bundleID.isEmpty }
        List {
            ForEach(backups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(backup.dateLabel).font(.headline)
                        Text("\(backup.deviceName) · \(backup.version) · \(backup.statusLabel)")
                            .foregroundStyle(.secondary).font(.caption)
                        if !backup.issues.isEmpty {
                            Text(backup.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: backup.totalBytes, countStyle: .file))
                    Menu("書き出し") {
                        Button("Airliftバックアップ…") { manager.exportBackup(backup, xcappdata: false) }
                        Button("xcappdata…") { manager.exportBackup(backup, xcappdata: true) }
                            .disabled(!backup.regions.contains { $0.kind == "data" })
                    }
                    Button("リストア") { restoreSource = backup }
                        .disabled(manager.deviceID == nil || !backup.canRestore)
                    Button("削除", systemImage: "trash", role: .destructive) { manager.deleteBackup(backup) }
                        .labelStyle(.iconOnly).help("バックアップをゴミ箱に移動")
                }.padding(.vertical, 8)
                    .contextMenu {
                        AppBackupMenu(manager: manager, backup: backup, restoreSource: $restoreSource)
                    }
            }
        }
        .disabled(manager.busy)
        .overlay {
            if backups.isEmpty {
                ContentUnavailableView("バックアップはありません", systemImage: "archivebox",
                                       description: Text("ツールバーから対象を選んでバックアップできます。"))
            }
        }
    }
}
