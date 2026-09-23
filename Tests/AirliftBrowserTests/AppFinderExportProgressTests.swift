import Foundation
import Testing
@testable import AirliftBrowser

@MainActor
struct AppFinderExportProgressTests {
    @Test func tracksProgressUntilEveryFileFinishes() throws {
        let manager = AppManager()
        let id = UUID()
        let cancelURL = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        defer {
            try? FileManager.default.removeItem(at: cancelURL)
            if let log = manager.operation?.logURL { try? FileManager.default.removeItem(at: log) }
        }
        func send(_ event: AppFinderExportEvent) {
            manager.updateFinderExport(event, id: id, count: 2, appName: "Test", cancelURL: cancelURL)
        }
        send(.started("first.txt"))
        #expect(manager.busy)
        #expect(manager.operation?.running == true)
        #expect(!manager.showOperation)
        let operationID = manager.operation?.id
        send(.progress(AppResponse(message: "取得: first.txt", completed: 50, total: 100, phase: "receive")))
        #expect(manager.status == "取得: first.txt")
        #expect(manager.fraction == 0.5)
        #expect(manager.operation?.completed == 50)
        #expect(manager.operation?.logs.contains { $0.message.contains("取得: first.txt") } == true)
        send(.finished("first.txt", failure: "テストエラー"))
        #expect(manager.busy)
        #expect(manager.operation?.running == true)
        send(.started("second.txt"))
        #expect(manager.operation?.id == operationID)
        manager.cancel()
        #expect(FileManager.default.fileExists(atPath: cancelURL.path))
        send(.finished("second.txt", failure: nil))
        #expect(!manager.busy)
        #expect(manager.fraction == nil)
        #expect(manager.operation?.running == false)
        #expect(manager.operation?.failed == true)
        #expect(manager.error == "first.txt: テストエラー")
        #expect(!FileManager.default.fileExists(atPath: cancelURL.path))
        let log = try #require(manager.operation?.logURL)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("コピー完了: second.txt"))
    }

    @Test func completesSuccessfulExportAndIgnoresLateProgress() {
        let manager = AppManager()
        let id = UUID()
        let cancelURL = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString)
        defer { if let log = manager.operation?.logURL { try? FileManager.default.removeItem(at: log) } }
        manager.updateFinderExport(.started("file.txt"), id: id, count: 1, appName: "Test", cancelURL: cancelURL)
        manager.updateFinderExport(.finished("file.txt", failure: nil), id: id, count: 1, appName: "Test", cancelURL: cancelURL)
        manager.updateFinderExport(.progress(AppResponse(message: "late")), id: id, count: 1, appName: "Test", cancelURL: cancelURL)
        #expect(manager.status == "Finderへのコピーが完了しました")
        #expect(!manager.busy)
        #expect(manager.operation?.failed == false)
        #expect(manager.operation?.running == false)
    }
}
