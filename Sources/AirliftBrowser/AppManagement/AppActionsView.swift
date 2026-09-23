import SwiftUI

struct AppActionsView: View {
    @Bindable var manager: AppManager
    @Binding var showBackup: Bool
    @Binding var showRestore: Bool

    var body: some View {
        Form {
            AppRegionActionsView(manager: manager, kind: "data", title: "データ")
            AppRegionActionsView(manager: manager, kind: "group", title: "App Group")
            AppRegionActionsView(manager: manager, kind: "bundle", title: "アプリ本体")
            Section("バックアップ") {
                AppActionRow(title: "バックアップ…", subtitle: "保存する領域を選び、Macにバックアップを作成します。",
                             systemImage: "archivebox") { showBackup = true }
                    .disabled(manager.regions.isEmpty)
                AppActionRow(title: "リストア…", subtitle: "このアプリのバックアップ履歴から復元します。",
                             systemImage: "arrow.uturn.backward") { showRestore = true }
            }
        }
        .formStyle(.grouped)
        .disabled(manager.busy)
    }
}
