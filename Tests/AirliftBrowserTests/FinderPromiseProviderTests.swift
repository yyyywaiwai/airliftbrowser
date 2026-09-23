import AppKit
import Testing
import UniformTypeIdentifiers
@testable import AirliftBrowser

private final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String {
        "drag-copy.txt"
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        finderPromiseQueue
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            try Data("Finder copy regression".utf8).write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

@MainActor
struct FinderPromiseProviderTests {
    @Test func fulfillsPromiseAfterDragSourceReleasesWriter() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        weak var writer: PromiseWriter?
        let provider = autoreleasepool {
            let delegate = PromiseWriter()
            writer = delegate
            return FinderPromiseProvider(fileType: UTType.plainText.identifier, retaining: delegate)
        }
        let retainedWriter = try #require(provider.delegate)
        #expect(writer != nil)
        let result = destination.appendingPathComponent(retainedWriter.filePromiseProvider(provider, fileNameForType: provider.fileType))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            retainedWriter.filePromiseProvider(provider, writePromiseTo: result) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        #expect(result.lastPathComponent == "drag-copy.txt")
        #expect(try String(contentsOf: result, encoding: .utf8) == "Finder copy regression")
    }
}
