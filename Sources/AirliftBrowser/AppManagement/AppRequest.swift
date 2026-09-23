import Foundation

struct AppRequest: Encodable, Sendable {
    var action: String
    var device: String?
    var appID: String?
    var regionID: String?
    var backupPath: String?
    var relative: String?
    var local: String?
    var destination: String?
    var source: String?
    var operation: String?
    var overwrite: Bool?
    var expectedHash: String?
    var xcappdata: Bool?
    var mode: String?
    var mappings: [String: String]?
    var offset: Int64?
    var pageBytes: Int?
    var text: String?
    var encoding: String?
    var cancelPath: String?
    var verify: Bool?
}
