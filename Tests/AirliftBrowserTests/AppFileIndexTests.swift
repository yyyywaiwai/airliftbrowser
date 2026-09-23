import Foundation
import Testing
@testable import AirliftBrowser

private actor ListingService {
    var requests: [AppRequest] = []
    var tree: [AppFile]
    var failNextListing = false
    var failMutation = false

    init(tree: [AppFile]) { self.tree = tree }

    func failListing() { failNextListing = true }
    func rejectMutation() { failMutation = true }
    func call(_ request: AppRequest) throws -> AppResponse {
        requests.append(request)
        if request.action == "list-tree" {
            if failNextListing {
                failNextListing = false
                throw AppServiceError("Listing failed")
            }
            return AppResponse(tree: tree)
        }
        if request.action == "mutate", failMutation { throw AppServiceError("Mutation failed") }
        return AppResponse(backups: [], pending: [])
    }

    var listingCount: Int { requests.filter { $0.action == "list-tree" }.count }
    var requestCount: Int { requests.count }
}

@MainActor
struct AppFileIndexTests {
    private let region = AppRegion(id: "data:app", kind: "data", identifier: "app", name: "Data", path: "/container")
    private var tree: [AppFile] {
        [("Library", "directory"), ("Library/空", "directory"), ("Library/data", "file"),
         ("Library2", "directory"), ("Library2/other", "file"), ("link", "link")].map {
            AppFile(id: $0.0, name: $0.0.split(separator: "/").last.map(String.init)!,
                    kind: $0.1, size: 5_368_709_121, modified: 1, target: $0.1 == "link" ? "Library" : nil)
        }
    }

    private func manager(_ service: ListingService) -> AppManager {
        let manager = AppManager { request, _ in try await service.call(request) }
        manager.deviceID = "device"
        manager.apps = [ManagedApp(id: "app", bundleID: "app", name: "Test", version: "1",
                                   category: "user", identity: "installed", regions: [region])]
        manager.selectApp("app")
        return manager
    }

    private func finish(_ manager: AppManager) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(!manager.busy)
        if let log = manager.operation?.logURL { try? FileManager.default.removeItem(at: log) }
    }

    @Test func childParentEmptyAndRegionRevisitNeverCallHelper() async throws {
        let service = ListingService(tree: tree)
        let manager = manager(service)
        manager.selectRegion(region.id)
        try await finish(manager)
        #expect(Set(manager.files.map(\.id)) == ["Library", "Library2", "link"])
        manager.navigate("Library")
        #expect(!manager.busy)
        #expect(Set(manager.files.map(\.id)) == ["Library/空", "Library/data"])
        manager.navigate("Library/空")
        #expect(manager.files.isEmpty && manager.fileListingError == nil)
        manager.navigate("missing")
        #expect(manager.fileListingError != nil)
        manager.navigate("link")
        #expect(manager.fileListingError != nil)
        manager.navigate("")
        manager.showAppActions()
        manager.selectRegion(region.id)
        #expect(!manager.busy)
        #expect(await service.requestCount == 1)
    }

    @Test func refreshAndFailedWriteInvalidateSnapshot() async throws {
        let service = ListingService(tree: tree)
        let manager = manager(service)
        manager.selectRegion(region.id)
        try await finish(manager)
        manager.refresh()
        try await finish(manager)
        #expect(await service.listingCount == 2)
        await service.rejectMutation()
        manager.mutate(operation: "mkdir", name: "new")
        try await finish(manager)
        manager.navigate("Library")
        try await finish(manager)
        #expect(await service.listingCount == 3)
    }

    @Test func failedRefreshDoesNotReuseOldSnapshot() async throws {
        let service = ListingService(tree: tree)
        let manager = manager(service)
        manager.selectRegion(region.id)
        try await finish(manager)
        await service.failListing()
        manager.refresh()
        try await finish(manager)
        #expect(manager.files.isEmpty)
        #expect(manager.fileListingError != nil)
        manager.navigate("Library")
        try await finish(manager)
        #expect(await service.listingCount == 3)
        #expect(manager.fileListingError == nil)
    }

    @Test func sharedGroupWriteAndRecoveryInvalidateOtherOwners() async throws {
        let service = ListingService(tree: tree)
        let manager = manager(service)
        let group = AppRegion(id: "group:shared", kind: "group", identifier: "shared", name: "Shared", path: "/group")
        manager.apps = ["app", "other"].map {
            ManagedApp(id: $0, bundleID: $0, name: $0, version: "1", category: "user",
                       identity: "installed", regions: [group])
        }
        for owner in ["app", "other"] {
            manager.selectApp(owner)
            manager.selectRegion(group.id)
            try await finish(manager)
        }
        #expect(await service.listingCount == 2)
        manager.mutate(operation: "mkdir", name: "new")
        try await finish(manager)
        #expect(await service.listingCount == 3)
        manager.selectApp("app")
        manager.selectRegion(group.id)
        try await finish(manager)
        #expect(await service.listingCount == 4)
        manager.recover()
        try await finish(manager)
        manager.navigate("Library")
        try await finish(manager)
        #expect(await service.listingCount == 5)
    }

    @Test func deviceAndContainerIdentityDoNotShareSnapshots() async throws {
        let service = ListingService(tree: tree)
        let manager = manager(service)
        manager.selectRegion(region.id)
        try await finish(manager)
        manager.deviceID = "other-device"
        manager.navigate("")
        try await finish(manager)
        #expect(await service.listingCount == 2)
        var moved = region
        moved.path = "/reinstalled-container"
        manager.apps = [ManagedApp(id: "app", bundleID: "app", name: "Test", version: "2",
                                   category: "user", identity: "installed", regions: [moved])]
        manager.navigate("")
        try await finish(manager)
        #expect(await service.listingCount == 3)
    }

    @Test func liveDeviceMetadataNavigatesWithoutHelper() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIRLIFT_LISTING_FIXTURE"] else { return }
        let response = try JSONDecoder().decode(AppResponse.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let tree = try #require(response.tree)
        let service = ListingService(tree: tree)
        let manager = manager(service)
        manager.selectRegion(region.id)
        try await finish(manager)
        let directories = [""] + tree.filter(\.isDirectory).map(\.id)
        let expected = Dictionary(grouping: tree) { $0.id.split(separator: "/").dropLast().joined(separator: "/") }
        let start = ContinuousClock.now
        for path in directories {
            manager.navigate(path)
            #expect(!manager.busy)
            #expect(manager.fileListingError == nil)
            #expect(Set(manager.files) == Set(expected[path] ?? []))
        }
        let elapsed = start.duration(to: .now)
        #expect(await service.requestCount == 1)
        print("Live metadata: \(tree.count) entries, \(directories.count) directories in \(elapsed); navigation helper calls: 0")
    }
}
