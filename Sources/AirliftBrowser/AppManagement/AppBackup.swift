import Foundation

struct AppBackup: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let bundleID: String
    let created: String
    let totalBytes: Int64
    let status: String
    let version: String
    let deviceName: String
    let issues: [String]
    let regions: [AppRegion]

    var canRestore: Bool { status != "incomplete" && regions.contains { $0.kind != "bundle" } }

    var dateLabel: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: created)?.formatted(date: .abbreviated, time: .shortened) ?? created
    }

    var statusLabel: String {
        switch status {
        case "complete": String(localized: "保存済み")
        case "partial": String(localized: "一部を保存できず")
        default: String(localized: "未完了")
        }
    }
}
