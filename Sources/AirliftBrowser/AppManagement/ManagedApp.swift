import Foundation

struct ManagedApp: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bundleID: String
    let name: String
    let version: String
    let category: String
    let identity: String
    let regions: [AppRegion]

    var detailLabel: String { categoryName + (version.isEmpty ? "" : " · " + version) }

    var categoryName: String {
        switch category {
        case "system": String(localized: "Apple製")
        case "orphan": String(localized: "削除済みアプリの残りデータ")
        default: String(localized: "インストール済み")
        }
    }
}
