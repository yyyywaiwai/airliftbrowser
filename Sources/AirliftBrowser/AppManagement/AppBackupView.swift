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
            Text("保存するもの").font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                target("データ", kind: "data", description: "書類・設定・キャッシュなど")
                target("共有データ", kind: "group", description: "ほかのアプリや拡張機能と共有しているデータ")
                target("アプリ本体", kind: "bundle", description: "中身の確認用（デバイスには復元できません）")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("転送後に内容を確認する", isOn: $manager.verificationEnabled)
                    .toggleStyle(.checkbox)
                Text("バックアップと復元の両方に適用されます。オフにすると速くなりますが、正しく転送できたかの確認を省きます。")
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

    private func target(_ name: LocalizedStringKey, kind: String, description: LocalizedStringKey) -> some View {
        Toggle(isOn: Binding(get: { selectedKinds.contains(kind) }, set: { enabled in
            if enabled { selectedKinds.insert(kind) } else { selectedKinds.remove(kind) }
        })) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                Text(availableKinds.contains(kind) ? description : "このアプリにはありません")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!availableKinds.contains(kind))
    }
}
