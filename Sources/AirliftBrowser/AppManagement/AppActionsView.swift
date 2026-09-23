import SwiftUI

struct AppActionsView: View {
    @Bindable var manager: AppManager
    @Binding var showBackup: Bool
    @Binding var showRestore: Bool

    var body: some View {
        Form {
            AppRegionActionsView(manager: manager, kind: "data", title: "データ")
            AppRegionActionsView(manager: manager, kind: "group", title: "共有データ")
            AppRegionActionsView(manager: manager, kind: "bundle", title: "アプリ本体")
            Section("バックアップ") {
                AppActionRow(title: String(localized: "バックアップ…"),
                             subtitle: String(localized: "保存するものを選んで、Macにバックアップを作ります。"),
                             systemImage: "archivebox") { showBackup = true }
                    .disabled(manager.regions.isEmpty)
                AppActionRow(title: String(localized: "復元…"),
                             subtitle: String(localized: "このアプリのバックアップから復元します。"),
                             systemImage: "arrow.uturn.backward") { showRestore = true }
            }
        }
        .formStyle(.grouped)
        .disabled(manager.busy)
    }
}
