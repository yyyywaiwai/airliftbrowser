import SwiftUI

struct AppBackupMenu: View {
    let manager: AppManager
    let backup: AppBackup
    @Binding var restoreSource: AppBackup?

    var body: some View {
        Button("Finderに表示", systemImage: "folder") { manager.revealBackup(backup) }
        Button("復元…", systemImage: "arrow.uturn.backward") { restoreSource = backup }
            .disabled(manager.deviceID == nil || !backup.canRestore)
        Menu("エクスポート", systemImage: "square.and.arrow.up") {
            Button("Airliftバックアップ…") { manager.exportBackup(backup, xcappdata: false) }
            Button("xcappdata…") { manager.exportBackup(backup, xcappdata: true) }
                .disabled(!backup.regions.contains { $0.kind == "data" })
        }
        Divider()
        Button("ゴミ箱に移動", systemImage: "trash", role: .destructive) { manager.deleteBackup(backup) }
    }
}
