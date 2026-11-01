import Foundation
import Testing
@testable import AirliftBrowser

private actor OfflineBackupService {
    let backup: AppBackup
    var requests: [AppRequest] = []

    init(backup: AppBackup) { self.backup = backup }

    func call(_ request: AppRequest) throws -> AppResponse {
        requests.append(request)
        guard request.device == nil, request.appID == nil else {
            throw AppServiceError("Local backups must not require a device or installed app")
        }
        switch request.action {
        case "backups":
            return AppResponse(backups: [backup])
        case "list":
            guard request.backupPath == backup.path, request.regionID == backup.regions.first?.id else {
                throw AppServiceError("Missing backup context")
            }
            let files = request.relative == "Documents"
                ? [AppFile(id: "Documents/note.txt", name: "note.txt", kind: "file", size: 1, modified: 0, target: nil)]
                : [AppFile(id: "Documents", name: "Documents", kind: "directory", size: 0, modified: 0, target: nil)]
            return AppResponse(entries: files)
        default:
            throw AppServiceError("Unexpected device operation: \(request.action)")
        }
    }
}

@MainActor
struct OfflineBackupTests {
    @Test func browsesAndRefreshesBackupsWithoutADevice() async throws {
        let region = AppRegion(id: "data:app", kind: "data", identifier: "app", name: "Data", path: "/container")
        let backup = AppBackup(id: "backup", path: "/local/Test.airliftbackup", name: "Test", bundleID: "app",
                               created: "2026-11-02T00:00:00Z", totalBytes: 1, status: "complete",
                               version: "1", deviceName: "iPhone", issues: [], regions: [region])
        let service = OfflineBackupService(backup: backup)
        let manager = AppManager { request, _ in try await service.call(request) }

        manager.activate(device: nil, library: true)
        try await finish(manager)
        #expect(manager.visibleBackups == [backup])
        #expect(!manager.canBrowse)

        manager.selectBackup(backup.id)
        try await finish(manager)
        #expect(manager.canBrowse)
        #expect(manager.files.map(\.id) == ["Documents"])

        manager.navigate("Documents")
        try await finish(manager)
        #expect(manager.files.map(\.id) == ["Documents/note.txt"])

        manager.refresh()
        try await finish(manager)
        #expect(manager.files.map(\.id) == ["Documents/note.txt"])
        #expect(manager.deviceID == nil)
        #expect(await service.requests.map(\.action) == ["backups", "list", "list", "list", "backups"])
    }

    private func finish(_ manager: AppManager) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(!manager.busy)
        #expect(manager.error == nil)
        if let log = manager.operation?.logURL { try? FileManager.default.removeItem(at: log) }
    }
}
