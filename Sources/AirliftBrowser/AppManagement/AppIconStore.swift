import AppKit
import CryptoKit

@MainActor
final class AppIconStore {
    static let shared = AppIconStore()

    private struct Key: Hashable, Sendable {
        let device: String
        let appID: String
        let version: String

        var cacheURL: URL {
            let data = Data([device, appID, version].map { "\($0.utf8.count):\($0)" }.joined().utf8)
            let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return URL.cachesDirectory.appendingPathComponent("local.airlift.browser/AppIcons")
                .appendingPathComponent(name + ".png")
        }
    }

    private var images: [Key: NSImage] = [:]
    private var failures: [Key: Date] = [:]
    private var requests: [Key: Task<NSImage?, Never>] = [:]
    private var pending: [Key] = []
    private var waiters: [Key: CheckedContinuation<NSImage?, Never>] = [:]
    private var worker: Task<Void, Never>?

    func image(for app: ManagedApp, device: String) async -> NSImage? {
        guard app.identity == "installed", !Task.isCancelled else { return nil }
        let key = Key(device: device, appID: app.id, version: app.version)
        if let image = images[key] { return image }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 60 { return nil }
        if let request = requests[key] { return await request.value }

        let request = Task { @MainActor () -> NSImage? in
            let data = await Task.detached { try? Data(contentsOf: key.cacheURL) }.value
            if let data, let image = NSImage(data: data) {
                images[key] = image
                return image
            }
            return await withCheckedContinuation { continuation in
                waiters[key] = continuation
                pending.append(key)
                if worker == nil {
                    worker = Task { await drain() }
                }
            }
        }
        requests[key] = request
        let image = await request.value
        requests[key] = nil
        return image
    }

    private func drain() async {
        // Coalesce row requests into one helper launch and one SpringBoard connection.
        try? await Task.sleep(for: .milliseconds(25))
        while let first = pending.first {
            // Different versions of the same app must not collide in the wire dictionary.
            var appIDs = Set<String>()
            let batch = pending.filter {
                $0.device == first.device && appIDs.insert($0.appID).inserted
            }
            let keys = Set(batch)
            pending.removeAll { keys.contains($0) }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlift-icons-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let paths = Dictionary(uniqueKeysWithValues: batch.enumerated().map {
                    ($0.element.appID, directory.appendingPathComponent("\($0.offset).png").path)
                })
                _ = try await AppService.call(AppRequest(action: "icons", device: first.device, icons: paths)) { response in
                    guard let key = batch.first(where: { $0.appID == response.appID }) else { return }
                    if response.error != nil {
                        await self.complete(key, data: nil)
                        return
                    }
                    guard let path = response.local, path == paths[key.appID] else { return }
                    let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                    if let data {
                        try? FileManager.default.createDirectory(at: key.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? data.write(to: key.cacheURL, options: .atomic)
                    }
                    await self.complete(key, data: data)
                }
            } catch {
                // Completed icons remain available even if the device disconnects mid-batch.
            }
            for key in batch where waiters[key] != nil { complete(key, data: nil) }
            try? FileManager.default.removeItem(at: directory)
        }
        worker = nil
    }

    private func complete(_ key: Key, data: Data?) {
        let image = data.flatMap { NSImage(data: $0) }
        if let image {
            images[key] = image
            failures[key] = nil
        } else {
            failures[key] = Date()
        }
        waiters.removeValue(forKey: key)?.resume(returning: image)
    }
}
