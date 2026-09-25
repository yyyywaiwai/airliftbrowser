import Foundation

struct AppRequest: Encodable, Sendable {
    var action: String
    var device: String?
    var appID: String?
    var regionID: String?
    var backupPath: String?
    var relative: String?
    var file: AppFile?
    var containerPath: String?
    var sourceIdentity: String?
    var local: String?
    var destination: String?
    var label: String?
    var source: String?
    var operation: String?
    var overwrite: Bool?
    var xcappdata: Bool?
    var mode: String?
    var mappings: [String: String]?
    var cancelPath: String?
    var verify: Bool?
    var regionKinds: [String]?
    var icons: [String: String]?
}
