import Foundation

struct AppRegion: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: String
    let identifier: String
    let name: String
    var path: String?
    var folder: String?

    var symbol: String {
        switch kind {
        case "group": "folder.badge.person.crop"
        case "bundle": "app.dashed"
        default: "folder"
        }
    }
}
