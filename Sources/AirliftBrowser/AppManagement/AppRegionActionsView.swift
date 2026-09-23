import SwiftUI

struct AppRegionActionsView: View {
    let manager: AppManager
    let kind: String
    let title: LocalizedStringKey

    var body: some View {
        let regions = manager.regions.filter { $0.kind == kind }
        Section(title) {
            if regions.isEmpty {
                Text("このアプリにはありません").foregroundStyle(.secondary)
            } else {
                ForEach(regions) { region in
                    AppActionRow(title: region.name, systemImage: region.symbol) {
                        manager.selectRegion(region.id)
                    }
                    .accessibilityIdentifier("app-browse-\(region.id)")
                }
            }
        }
    }
}

struct AppActionRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
