import SwiftUI

struct AppBackupView: View {
    @Bindable var manager: AppManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKinds: Set<String> = []

    private var availableKinds: Set<String> { Set(manager.regions.map(\.kind)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("アプリをバックアップ").font(.title2.weight(.semibold))
            Text(manager.title).foregroundStyle(.secondary)
            Text("保存する対象").font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                target("データ", kind: "data", description: "Documents・Library・キャッシュ・tmp")
                target("App Group", kind: "group", description: "関連する共有コンテナをすべて保存")
                target("アプリ本体", kind: "bundle", description: "閲覧・エクスポート用（端末への復元対象外）")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("バックアップ／リストアの内容検証", isOn: $manager.verificationEnabled)
                    .toggleStyle(.checkbox)
                Text("共通設定として保存します。オフの場合、バックアップ時の保存内容の再読み込み照合を省略します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            AppGlassActions {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button("バックアップを作成", systemImage: "archivebox") {
                    manager.backupApp(regionKinds: selectedKinds.intersection(availableKinds))
                }
                .modifier(AppPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedKinds.intersection(availableKinds).isEmpty || manager.deviceID == nil)
            }
        }
        .padding(24).frame(width: 480)
        .disabled(manager.busy)
        .onAppear { selectedKinds = availableKinds }
    }

    private func target(_ name: String, kind: String, description: String) -> some View {
        Toggle(isOn: Binding(get: { selectedKinds.contains(kind) }, set: { enabled in
            if enabled { selectedKinds.insert(kind) } else { selectedKinds.remove(kind) }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                Text(availableKinds.contains(kind) ? description : "取得可能な領域がありません")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!availableKinds.contains(kind))
    }
}
