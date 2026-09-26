import Foundation

struct AppResponse: Decodable, Sendable {
    var event: String?
    var ok: Bool?
    var error: String?
    var message: String?
    var completed: Int64?
    var total: Int64?
    var phase: String?
    var region: String?
    var regionIndex: Int?
    var regionCount: Int?
    var steps: [AppOperationStep]?
    var apps: [ManagedApp]?
    var backups: [AppBackup]?
    var backup: AppBackup?
    var entries: [AppFile]?
    var tree: [AppFile]?
    var sourceIdentity: String?
    var warnings: [String]?
    var confirm: String?
    var pending: [PendingAppOperation]?
    var local: String?
    var appID: String?
}
