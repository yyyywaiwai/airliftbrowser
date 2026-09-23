import AppKit

@MainActor
final class AppIconStore {
    static let shared = AppIconStore()

    private struct Key: Hashable {
        let device: String
        let appID: String
        let version: String
    }

    private var images: [Key: NSImage] = [:]
    private var failures: [Key: Date] = [:]
    private var requests: [Key: Task<NSImage?, Never>] = [:]
    private var tail: Task<NSImage?, Never>?

    func image(for app: ManagedApp, device: String) async -> NSImage? {
        guard app.identity == "installed", !Task.isCancelled else { return nil }
        let key = Key(device: device, appID: app.id, version: app.version)
        if let image = images[key] { return image }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 60 { return nil }
        if let request = requests[key] { return await request.value }

        // Keep USB requests serial and share in-flight results between list and detail.
        let previous = tail
        let request = Task { @MainActor () -> NSImage? in
            _ = await previous?.value
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlift-icon-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                _ = try await AppService.call(AppRequest(action: "icon", device: device, appID: app.id, local: url.path))
                guard let image = NSImage(contentsOf: url) else { throw AppServiceError("アイコンを読み込めませんでした。") }
                self.images[key] = image
                self.failures[key] = nil
                return image
            } catch {
                self.failures[key] = Date()
                return nil
            }
        }
        requests[key] = request
        tail = request
        let image = await request.value
        requests[key] = nil
        if requests.isEmpty { tail = nil }
        return image
    }
}
