import SwiftUI

struct AppDetailView: View {
    @Bindable var manager: AppManager
    @Binding var restoreSource: AppBackup?
    @Binding var showBackup: Bool
    @State private var history = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if !manager.libraryMode, let app = manager.app {
                    ManagedAppIcon(app: app, deviceID: manager.deviceID, size: 44)
                } else {
                    Image(systemName: manager.libraryMode ? "archivebox" : "app.fill")
                        .font(.largeTitle).foregroundStyle(.tint).frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.title).font(.title2.weight(.semibold))
                    Text(manager.libraryMode ? manager.backup?.bundleID ?? "" : manager.app?.bundleID ?? "")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if manager.libraryMode, let backup = manager.backup {
                        Text("\(backup.dateLabel) · \(backup.deviceName) · \(backup.statusLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !manager.libraryMode, history || manager.regionID != nil {
                    Button("操作一覧に戻る", systemImage: "chevron.backward") {
                        manager.showAppActions()
                        history = false
                    }
                    .disabled(manager.busy)
                }
            }.padding(18)
            Divider()
            if history && !manager.libraryMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("復元").font(.headline)
                    Text("復元するバックアップを選んでください。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16)
                AppHistoryView(manager: manager, restoreSource: $restoreSource)
            } else if !manager.libraryMode, manager.regionID == nil {
                AppActionsView(manager: manager, showBackup: $showBackup, showRestore: $history)
            } else {
                HStack {
                    Picker("場所", selection: $manager.regionID) {
                        ForEach(manager.regions) { region in
                            Label(region.name, systemImage: region.symbol).tag(Optional(region.id))
                        }
                    }.frame(maxWidth: 430)
                    Spacer()
                    if manager.libraryMode {
                        Text("編集すると新しいバックアップとして保存されます").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                    .disabled(manager.busy)
                    .onChange(of: manager.regionID) {
                        if !manager.busy { manager.selectRegion(manager.regionID) }
                    }
                Divider()
                AppFilesView(manager: manager)
            }
        }
    }
}
