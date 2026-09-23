import SwiftUI

struct AppActionsView: View {
    @Bindable var manager: AppManager
    @Binding var showBackup: Bool
    @Binding var showRestore: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("操作を選択").font(.title3.weight(.semibold))
                    Text("閲覧する領域、またはバックアップ・リストアを選択してください。")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("ファイルを閲覧").font(.headline)
                    AppRegionActionsView(manager: manager, kind: "data", title: "データ")
                    AppRegionActionsView(manager: manager, kind: "group", title: "App Group")
                    AppRegionActionsView(manager: manager, kind: "bundle", title: "アプリ本体")
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Button("バックアップ…", systemImage: "archivebox") { showBackup = true }
                        .disabled(manager.regions.isEmpty)
                    Text("保存する領域を選び、Macにバックアップを作成します。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("リストア…", systemImage: "arrow.uturn.backward") { showRestore = true }
                    Text("このアプリのバックアップ履歴から復元します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .disabled(manager.busy)
    }
}
