import SwiftUI

struct AppDetailView: View {
    @Bindable var manager: AppManager
    @Binding var restoreSource: AppBackup?
    @State private var history = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let url = manager.iconURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                if !manager.libraryMode {
                    Picker("表示", selection: $history) {
                        Text("ファイル").tag(false)
                        Text("バックアップ履歴").tag(true)
                    }.pickerStyle(.segmented).frame(width: 210)
                        .disabled(manager.editor?.isDirty == true)
                }
            }.padding(18)
            Divider()
            if history && !manager.libraryMode {
                AppHistoryView(manager: manager, restoreSource: $restoreSource)
            } else {
                HStack {
                    Picker("領域", selection: $manager.regionID) {
                        ForEach(manager.regions) { region in
                            Label(region.name, systemImage: region.symbol).tag(Optional(region.id))
                        }
                    }.frame(maxWidth: 430)
                    Spacer()
                    if manager.libraryMode {
                        Text("編集すると新しい履歴として保存").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                    .disabled(manager.busy || manager.editor?.isDirty == true)
                    .onChange(of: manager.regionID) {
                        if !manager.busy { manager.selectRegion(manager.regionID) }
                    }
                Divider()
                AppFilesView(manager: manager)
            }
        }
    }
}
