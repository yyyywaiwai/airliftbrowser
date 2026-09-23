import SwiftUI

struct AppRestoreView: View {
    @Bindable var manager: AppManager
    let backup: AppBackup
    @Environment(\.dismiss) private var dismiss
    @State private var targetID = ""
    @State private var mode = "replace"
    @State private var mappings: [String: String] = [:]

    private var target: ManagedApp? { manager.apps.first { $0.id == targetID } }
    private var sources: [AppRegion] { backup.regions.filter { $0.kind != "bundle" } }
    private var chosenMappings: [String: String] { mappings.filter { !$0.value.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("バックアップをリストア").font(.title2.weight(.semibold))
            Text("\(backup.name) · \(backup.dateLabel)").foregroundStyle(.secondary)
            if !backup.issues.isEmpty {
                Text(backup.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).lineLimit(4)
            }
            Form {
                Picker("復元先アプリ", selection: $targetID) {
                    Text("選択してください").tag("")
                    ForEach(manager.apps.filter { $0.regions.contains { $0.kind != "bundle" } }) { app in
                        Text("\(app.name) · \(app.bundleID.isEmpty ? app.id : app.bundleID)").tag(app.id)
                    }
                }
                Picker("復元方法", selection: $mode) {
                    Text("完全置換").tag("replace")
                    Text("上書き・追加").tag("merge")
                }.pickerStyle(.segmented)
                Text(mode == "replace" ? "選択した領域を保存時点に揃えます。バックアップにない現在の項目は削除します。" : "同名項目を上書きし、それ以外の現在の項目は残します。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("バックアップ／リストアの内容検証", isOn: $manager.verificationEnabled)
                Text("共通設定として保存します。オフの場合、バックアップ時の保存内容の再照合、リストア前の内容照合と復元後の読み戻し照合を省略します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("復元する領域と対応先").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sources) { source in
                        Picker(source.name, selection: Binding(get: { mappings[source.id] ?? "" }, set: { mappings[source.id] = $0 })) {
                            Text("復元しない").tag("")
                            ForEach(target?.regions.filter { $0.kind == source.kind } ?? []) { region in
                                Text(region.name).tag(region.id)
                            }
                        }
                    }
                }
            }.frame(maxHeight: 220)
            AppGlassActions {
                Button("復元先を更新", action: manager.loadRestoreApps)
                if manager.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button("リストア") {
                    if let target { manager.restore(backup, target: target, mode: mode, mappings: chosenMappings) }
                }.modifier(AppPrimaryButtonStyle())
                    .disabled(target == nil || chosenMappings.isEmpty || Set(chosenMappings.values).count != chosenMappings.count)
            }
        }
        .padding(24).frame(width: 640)
        .disabled(manager.busy)
        .onChange(of: targetID) { matchRegions() }
        .onChange(of: manager.apps) { chooseDefault() }
        .onAppear {
            chooseDefault()
            if manager.apps.isEmpty { manager.loadRestoreApps() }
        }
    }

    private func chooseDefault() {
        if targetID.isEmpty { targetID = manager.apps.first { $0.bundleID == backup.bundleID }?.id ?? "" }
        matchRegions()
    }

    private func matchRegions() {
        mappings = [:]
        for source in sources {
            let targetRegion = target?.regions.first { $0.kind == source.kind && (source.kind == "data" || $0.identifier == source.identifier) }
            mappings[source.id] = targetRegion?.id ?? ""
        }
    }
}
