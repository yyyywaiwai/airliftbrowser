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
        case "system": "標準アプリ"
        case "orphan": "残存コンテナ"
        default: "インストール済み"
        }
    }
}
