import AppKit

final class AppFinderFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let fileName: String
    let isDirectory: Bool
    private let request: AppRequest
    private let notify: @Sendable (AppFinderExportEvent) -> Void

    init(file: AppFile, request: AppRequest, notify: @escaping @Sendable (AppFinderExportEvent) -> Void) {
        fileName = file.name
        isDirectory = file.isDirectory
        self.request = request
        self.notify = notify
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        finderPromiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable (Error?) -> Void) {
        var export = request
        export.local = url.path
        let request = export
        let notify = notify
        let fileName = fileName
        // Queue UI notifications without awaiting the main actor: Finder may
        // still be running its drag loop while it waits for this promise.
        notify(.started(fileName))
        Task {
            var failure: String?
            do {
                try await finderExportQueue.run {
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw AppServiceError("「\(url.lastPathComponent)」は保存先に既にあります。上書きしません。")
                    }
                    _ = try await AppService.call(request) { response in
                        notify(.progress(response))
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            completionHandler(failure.map { AppServiceError($0) })
            notify(.finished(fileName, failure: failure))
        }
    }
}
