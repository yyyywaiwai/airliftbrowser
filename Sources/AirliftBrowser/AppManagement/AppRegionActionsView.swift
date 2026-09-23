import SwiftUI

struct AppRegionActionsView: View {
    let manager: AppManager
    let kind: String
    let title: String

    var body: some View {
        let regions = manager.regions.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            if regions.isEmpty {
                Text("取得可能な領域がありません")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(regions) { region in
                    Button {
                        manager.selectRegion(region.id)
                    } label: {
                        HStack(spacing: 10) {
                            Label(region.name, systemImage: region.symbol)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("app-browse-\(region.id)")
                }
            }
        }
    }
}
