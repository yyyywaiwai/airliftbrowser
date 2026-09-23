import SwiftUI

struct ManagedAppRow: View {
    let app: ManagedApp

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: app.category == "orphan" ? "folder.badge.questionmark" : "app")
                .font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).lineLimit(2)
                Text(app.bundleID.isEmpty ? "所属未識別" : app.bundleID)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(app.detailLabel).font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 4)
    }
}
