import AppKit

final class FinderPromiseProvider: NSFilePromiseProvider {
    convenience init(fileType: String, retaining delegate: NSFilePromiseProviderDelegate) {
        self.init(fileType: fileType, delegate: delegate)
        // NSFilePromiseProvider.delegate is weak. Finder can request the file
        // after draggingSession(_:endedAt:operation:) has released the source's
        // drag state, so the pasteboard provider must own its writer as well.
        userInfo = delegate
    }
}
