import SwiftUI

struct AppBackupMenu: View {
    let manager: AppManager
    let backup: AppBackup
    @Binding var restoreSource: AppBackup?

    var body: some View {
        Button("名前を変更…", systemImage: "pencil") { manager.renamingBackup = backup }
        Button("Finderに表示", systemImage: "folder") { manager.revealBackup(backup) }
        Button("復元…", systemImage: "arrow.uturn.backward") { restoreSource = backup }
            .disabled(manager.deviceID == nil || !backup.canRestore)
        Menu("書き出し", systemImage: "square.and.arrow.up") {
            Button("Airlift形式…") { manager.exportBackup(backup, xcappdata: false) }
            Button("Xcode形式（.xcappdata）…") { manager.exportBackup(backup, xcappdata: true) }
                .disabled(!backup.regions.contains { $0.kind == "data" })
        }
        Divider()
        Button("ゴミ箱に入れる", systemImage: "trash", role: .destructive) { manager.deleteBackup(backup) }
    }
}
