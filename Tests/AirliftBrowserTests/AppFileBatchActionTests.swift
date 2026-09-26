import Foundation
import Testing
@testable import AirliftBrowser

private actor BatchFileService {
    var files: [AppFile]
    var deleted: [String] = []

    init(files: [AppFile]) { self.files = files }

    func call(_ request: AppRequest) throws -> AppResponse {
        switch request.action {
        case "list-tree":
            return AppResponse(tree: files)
        case "mutate":
            guard request.operation == "delete", let relative = request.relative else {
                throw AppServiceError("Unexpected mutation")
            }
            deleted.append(relative)
            files.removeAll { $0.id == relative }
            return AppResponse()
        default:
            return AppResponse()
        }
    }
}

@MainActor
struct AppFileBatchActionTests {
    @Test func deletesExactlyTheChosenFilesAndReconcilesSelection() async throws {
        let files = ["one", "two", "three"].map {
            AppFile(id: $0, name: $0, kind: "file", size: 1, modified: 0, target: nil)
        }
        let service = BatchFileService(files: files)
        let manager = AppManager { request, _ in try await service.call(request) }
        let region = AppRegion(id: "data:app", kind: "data", identifier: "app", name: "Data", path: "/container")
        manager.deviceID = "device"
        manager.apps = [ManagedApp(id: "app", bundleID: "app", name: "App", version: "1",
                                   category: "user", identity: "installed", regions: [region])]
        manager.selectApp("app")
        manager.selectRegion(region.id)
        try await waitForWork(manager)

        manager.selection = ["one", "two", "three"]
        manager.deleteFiles(Array(files.prefix(2)))
        try await waitForWork(manager)

        #expect(await service.deleted == ["one", "two"])
        #expect(manager.files.map(\.id) == ["three"])
        #expect(manager.selection == ["three"])
        #expect(manager.error == nil)
        if let log = manager.operation?.logURL { try? FileManager.default.removeItem(at: log) }
    }

    private func waitForWork(_ manager: AppManager) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(!manager.busy)
    }
}
