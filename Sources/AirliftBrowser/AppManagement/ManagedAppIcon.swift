import SwiftUI

struct ManagedAppIcon: View {
    let app: ManagedApp
    let deviceID: String?
    var size: CGFloat = 36
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: app.category == "orphan" ? "folder.badge.questionmark" : "app.fill")
                    .resizable().scaledToFit().padding(4).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
        .task(id: "\(deviceID ?? "")/\(app.id)/\(app.version)") {
            image = nil
            guard let deviceID else { return }
            let loaded = await AppIconStore.shared.image(for: app, device: deviceID)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
