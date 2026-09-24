import SwiftUI

struct AppRestoreView: View {
    @Bindable var manager: AppManager
    let backup: AppBackup
    @Environment(\.dismiss) private var dismiss
    @State private var targetID = ""
    @State private var mode = "replace"
    @State private var mappings: [String: String] = [:]
    @State private var choosingTarget = false

    private var target: ManagedApp? { manager.apps.first { $0.id == targetID } }
    private var targets: [ManagedApp] { manager.apps.filter { $0.regions.contains { $0.kind != "bundle" } } }
    private var sources: [AppRegion] { backup.regions.filter { $0.kind != "bundle" } }
    private var chosenMappings: [String: String] { mappings.filter { !$0.value.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("バックアップから復元").font(.title2.weight(.semibold))
            Text("\(backup.name) · \(backup.dateLabel)").foregroundStyle(.secondary)
            if !backup.issues.isEmpty {
                Text(backup.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange).lineLimit(4)
            }
            Form {
                LabeledContent("復元先のアプリ") {
                    Button { choosingTarget = true } label: {
                        HStack(spacing: 8) {
                            if let target {
                                ManagedAppIcon(app: target, deviceID: manager.deviceID, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.name)
                                    Text(target.bundleID.isEmpty ? target.id : target.bundleID)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("選んでください").foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                Picker("復元方法", selection: $mode) {
                    Text("置き換える").tag("replace")
                    Text("追加・上書きする").tag("merge")
                }.pickerStyle(.segmented)
                Text(mode == "replace" ? "バックアップした時点の状態に戻します。バックアップにない今のファイルは削除されます。" : "同じ名前のファイルは上書きし、それ以外の今のファイルは残します。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("転送後に内容を確認する", isOn: $manager.verificationEnabled)
                Text("バックアップと復元の両方に適用されます。オフにすると速くなりますが、正しく転送できたかの確認を省きます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("復元するデータと復元先").font(.headline)
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
            }.frame(minHeight: 160, maxHeight: 220)
            AppGlassActions {
                Button("アプリ一覧を更新", action: manager.loadRestoreApps)
                if manager.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button("復元") {
                    if let target { manager.restore(backup, target: target, mode: mode, mappings: chosenMappings) }
                }.modifier(AppPrimaryButtonStyle())
                    .disabled(target == nil || chosenMappings.isEmpty || Set(chosenMappings.values).count != chosenMappings.count)
            }
        }
        .padding(24).frame(width: 640).frame(minHeight: 620)
        .disabled(manager.busy)
        .sheet(isPresented: $choosingTarget) {
            RestoreTargetSelectionView(
                apps: targets,
                deviceID: manager.deviceID,
                targetID: $targetID,
                refresh: manager.loadRestoreApps
            )
        }
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

private struct RestoreTargetSelectionView: View {
    let apps: [ManagedApp]
    let deviceID: String?
    @Binding var targetID: String
    let refresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var category = "all"

    private var visibleApps: [ManagedApp] {
        apps.filter { (category == "all" || $0.category == category) &&
            (search.isEmpty || $0.name.localizedStandardContains(search) || $0.bundleID.localizedStandardContains(search)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("復元先のアプリ").font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            VStack(spacing: 10) {
                TextField("アプリを検索", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("種類", selection: $category) {
                    Text("すべて").tag("all")
                    Text("インストール済み").tag("user")
                    Text("Apple製").tag("system")
                    Text("残りデータ").tag("orphan")
                }
                .labelsHidden()
            }
            .padding(16)
            Divider()
            List(visibleApps) { app in
                Button {
                    targetID = app.id
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        ManagedAppIcon(app: app, deviceID: deviceID, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).foregroundStyle(.primary)
                            Text(app.bundleID.isEmpty ? app.id : app.bundleID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if targetID == app.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle()).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack {
                Button("アプリ一覧を更新", action: refresh)
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
        }
        .frame(width: 520, height: 520)
    }
}
