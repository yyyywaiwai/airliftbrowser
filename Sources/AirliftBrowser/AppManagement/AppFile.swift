import Foundation

struct AppFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    let size: Int64
    let modified: Double
    let target: String?

    var isDirectory: Bool { kind == "directory" }
    var symbol: String { isDirectory ? "folder.fill" : kind == "link" ? "link" : "doc" }
    var sizeLabel: String { isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var kindLabel: String { isDirectory ? "フォルダ" : kind == "link" ? "リンク" : "ファイル" }
}
