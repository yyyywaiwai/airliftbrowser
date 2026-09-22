import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

private let verifiedDirectoryPaths: Set<String> = [
    "/var/mobile",
    "/var/mobile/Documents",
    "/var/mobile/Library",
    "/var/mobile/Library/Preferences",
    "/var/mobile/Library/Caches",
    "/var/mobile/Library/SpringBoard",
    "/var/mobile/Library/SMS",
    "/var/mobile/Library/Safari",
    "/var/mobile/Containers",
    "/var/mobile/Containers/Data/Application",
    "/var/mobile/Containers/Shared/AppGroup",
    "/var/tmp",
]

struct Device: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let product: String
    let version: String
    let transport: String
}

struct Entry: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let size: Int64
    let subtitle: String?
    var isDirectory: Bool { kind == "S_IFDIR" }
    var isFile: Bool { kind == "S_IFREG" }
    var isVerifiedDirectory: Bool { isDirectory && verifiedDirectoryPaths.contains(id) }
    var typeName: String { isDirectory ? "フォルダ" : isFile ? "ファイル" : "リンク / その他" }
    var sizeLabel: String { isFile && size >= 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "—" }
}

enum BrowseScope: String, Sendable {
    case media
    case system
    case cards
}

struct CardAsset: Decodable, Identifiable, Sendable {
    let name: String
    let width: Int
    let height: Int
    var id: String { name }
}

struct PayCard: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    var thumbnailPath: String?
    let assets: [CardAsset]
    let sourceURL: String?
}

private struct CardEditResult: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let thumbnailPath: String?
    let walletRestarted: Bool?
    let cacheCleared: Bool?
}

private struct CardListResult: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let cards: [PayCard]?
    let snapshotPath: String?
    let restored: Bool?
    let cleanupComplete: Bool?
}

private struct Reply: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let devices: [Device]?
    let entries: [Entry]?
}

struct PoCResult: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let targetDirectory: String?
    let generatedLeaf: String?
    let payloadLength: Int?
    let payloadSHA256: String?
    let exactBytesRecovered: Bool?
    let cleanupComplete: Bool?
}

private struct WriteResult: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let bytes: Int?
    let exactBytesVerified: Bool?
    let cleanupComplete: Bool?
    let target: String?
}

private struct FileResult: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let deleted: Bool?
    let targetAbsent: Bool?
    let cleanupComplete: Bool?
    let target: String?
    let local: String?
    let bytes: Int?
    let exactBytesVerified: Bool?
    let restored: Bool?
}

private struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

let deviceDragType = "com.airliftbrowser.device-item"

enum FinderDragGate {
    nonisolated(unsafe) static var active = false
}

struct RowActivity: Equatable {
    var fraction: Double?
}

struct PendingTransfer: Identifiable, Equatable {
    let id: String
    let name: String
    var fraction: Double?
}

private struct ExportRequest: Sendable {
    let deviceID: String
    let scope: BrowseScope
    let entry: Entry
}

private struct StagedDrop: Sendable {
    let root: URL
    let files: [URL]
}

private struct MainHandoff<T>: @unchecked Sendable {
    let value: T
}

private final class URLBox: @unchecked Sendable {
    var items: [URL] = []
}

private func isProtectedDevicePath(_ path: String) -> Bool {
    if verifiedDirectoryPaths.contains(path) { return true }
    if path.split(separator: "/", omittingEmptySubsequences: true).count < 3 { return true }
    return [
        "/var/mobile/Media",
        "/private/var",
        "/private/var/mobile",
        "/private/var/mobile/Media",
        "/private/var/mobile/Library",
        "/private/var/mobile/Containers",
        "/private/var/mobile/Containers/Data",
        "/private/var/mobile/Containers/Data/Application",
        "/private/var/mobile/Containers/Shared",
        "/private/var/mobile/Containers/Shared/AppGroup",
        "/var/containers",
        "/var/containers/Bundle",
        "/var/containers/Bundle/Application",
        "/private/var/containers",
        "/private/var/containers/Bundle",
        "/private/var/containers/Bundle/Application",
    ].contains(path)
}

private func exportRequest(_ request: ExportRequest) async throws -> URL {
    if request.scope == .system && request.entry.isDirectory && isProtectedDevicePath(request.entry.id) {
        throw BridgeError(message: "「\(request.entry.name)」はシステム階層のため抽出できません。")
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("airlift-export-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent(request.entry.name)
    switch request.scope {
    case .media:
        try await saveMedia(request.entry, to: destination, deviceID: request.deviceID)
    case .system:
        do {
            _ = try await moveOutside(request.deviceID, target: request.entry.id, local: destination)
        } catch {
            if request.entry.isDirectory { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    case .cards:
        throw BridgeError(message: "カードはこの操作の対象外です。")
    }
    return destination
}

private func saveMedia(_ entry: Entry, to destination: URL, deviceID: String) async throws {
    guard entry.isFile || entry.isDirectory else {
        throw BridgeError(message: "「\(entry.name)」は保存できない種類です。")
    }
    if entry.isFile {
        _ = try await bridge(["get", deviceID, entry.id, destination.path])
        return
    }
    do {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for child in try await bridge(["list", deviceID, entry.id]).entries ?? [] {
            try await saveMedia(child, to: destination.appendingPathComponent(child.name), deviceID: deviceID)
        }
    } catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}

@MainActor
private func stageDropped(_ providers: [NSItemProvider]) async throws -> StagedDrop {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("airlift-import-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, provider) in providers.enumerated() {
            let copied: URL = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, error in
                    guard let url = object else {
                        continuation.resume(throwing: error ?? BridgeError(message: "ドロップした項目を読み取れませんでした。"))
                        return
                    }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let leaf = url.lastPathComponent.isEmpty ? "item-\(index)" : url.lastPathComponent
                    let dest = root.appendingPathComponent(leaf)
                    do {
                        if FileManager.default.fileExists(atPath: dest.path) {
                            throw BridgeError(message: "「\(leaf)」が重複しています。")
                        }
                        try FileManager.default.copyItem(at: url, to: dest)
                        continuation.resume(returning: dest)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            files.append(copied)
        }
        return StagedDrop(root: root, files: files)
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func stageDroppedURLs(_ urls: [URL]) throws -> StagedDrop {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("airlift-import-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, url) in urls.enumerated() {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let leaf = url.lastPathComponent.isEmpty ? "item-\(index)" : url.lastPathComponent
            let dest = root.appendingPathComponent(leaf)
            if FileManager.default.fileExists(atPath: dest.path) {
                throw BridgeError(message: "「\(leaf)」が重複しています。")
            }
            try FileManager.default.copyItem(at: url, to: dest)
            files.append(dest)
        }
        return StagedDrop(root: root, files: files)
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func bridge(_ arguments: [String]) async throws -> Reply {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/browser_bridge")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Drain before waiting: directory listings can exceed pipe capacity.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw BridgeError(message: "接続処理が中断されました（終了コード \(process.terminationStatus)）。USB接続とロック状態を確認してください。")
        }
        guard process.terminationStatus == 0, reply.ok else {
            throw BridgeError(message: reply.error ?? "端末操作に失敗しました。")
        }
        return reply
    }.value
}

private func runPoCProcess(_ deviceID: String, target: String) async throws -> PoCResult {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let resource = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AirliftPoC")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [resource.appendingPathComponent("runner.py").path,
                             "--device", deviceID, "--target", target]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try? JSONDecoder().decode(PoCResult.self, from: data) else {
            throw BridgeError(message: "Airlift PoCが結果を返しませんでした（終了コード \(process.terminationStatus)）。")
        }
        guard process.terminationStatus == 0, result.ok else {
            throw BridgeError(message: result.error ?? "Airlift PoCの検証に失敗しました。")
        }
        return result
    }.value
}

private func writeOutside(_ deviceID: String, target: String, local: URL) async throws -> WriteResult {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AirliftPoC/write_file.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [script.path, "--device", deviceID, "--target", target,
                             "--local", local.path, "--name", local.lastPathComponent]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try? JSONDecoder().decode(WriteResult.self, from: data) else {
            throw BridgeError(message: "Airlift書込み処理が結果を返しませんでした。")
        }
        guard process.terminationStatus == 0, result.ok,
              result.exactBytesVerified == true, result.cleanupComplete == true else {
            throw BridgeError(message: result.error ?? "Airlift書込みの照合または後片付けに失敗しました。")
        }
        return result
    }.value
}

private func listPayCards(_ deviceID: String) async throws -> CardListResult {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AirliftPoC/list_cards.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [script.path, "--device", deviceID]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try? JSONDecoder().decode(CardListResult.self, from: data) else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = detail.map { String($0.prefix(240)) }
            throw BridgeError(message: clipped?.isEmpty == false
                ? "Apple Payカードの一覧を読み取れませんでした。\n\(clipped!)"
                : "Apple Payカードの一覧を読み取れませんでした。")
        }
        guard process.terminationStatus == 0, result.ok, result.restored == true,
              result.cleanupComplete == true else {
            throw BridgeError(message: result.error ?? "Apple Payカードの読み出しまたは端末への復元に失敗しました。")
        }
        return result
    }.value
}

private func editCard(_ deviceID: String, arguments: [String]) async throws -> CardEditResult {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AirliftPoC/edit_card.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [script.path, "--device", deviceID] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try? JSONDecoder().decode(CardEditResult.self, from: data) else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError(message: detail?.isEmpty == false
                ? "券面を書き換えられませんでした。\n\(detail!.prefix(240))"
                : "券面を書き換えられませんでした。")
        }
        guard process.terminationStatus == 0, result.ok else {
            throw BridgeError(message: result.error ?? "券面の書き換えまたは復元に失敗しました。")
        }
        return result
    }.value
}

private func moveOutside(_ deviceID: String, target: String, local: URL? = nil) async throws -> FileResult {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AirliftPoC/delete_file.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [script.path, "--device", deviceID, "--target", target]
        if let local { process.arguments! += ["--local", local.path] }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let result = try? JSONDecoder().decode(FileResult.self, from: data) else {
            throw BridgeError(message: "Airliftファイル処理が結果を返しませんでした。")
        }
        let completed = local == nil
            ? result.deleted == true && result.targetAbsent == true
            : result.exactBytesVerified == true && result.restored == true
        guard process.terminationStatus == 0, result.ok, completed,
              result.cleanupComplete == true else {
            throw BridgeError(message: result.error ?? "Airliftファイル処理または後片付けに失敗しました。")
        }
        return result
    }.value
}

private let airliftHierarchy: [String: [String]] = [
    "/": ["var"],
    "/var": ["mobile", "tmp"],
    "/var/tmp": [],
    "/var/mobile": ["Documents", "Library", "Containers", "Media"],
    "/var/mobile/Documents": [],
    "/var/mobile/Media": [],
    "/var/mobile/Library": ["Preferences", "Caches", "SpringBoard", "SMS", "Safari"],
    "/var/mobile/Library/Preferences": [],
    "/var/mobile/Library/Caches": [],
    "/var/mobile/Library/SpringBoard": [],
    "/var/mobile/Library/SMS": [],
    "/var/mobile/Library/Safari": [],
    "/var/mobile/Containers": ["Data", "Shared"],
    "/var/mobile/Containers/Data": ["Application"],
    "/var/mobile/Containers/Data/Application": [],
    "/var/mobile/Containers/Shared": ["AppGroup"],
    "/var/mobile/Containers/Shared/AppGroup": [],
]

private func normalizeDevicePath(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
        text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
        text = url.path
    }
    guard text.hasPrefix("/") else { return nil }
    let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") && $0.utf8.count <= 255 }) else {
        return nil
    }
    return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
}

private func airliftChildren(of path: String) -> [Entry] {
    (airliftHierarchy[path] ?? []).map { name in
        let child = path == "/" ? "/\(name)" : "\(path)/\(name)"
        return Entry(id: child, name: name, kind: "S_IFDIR", size: -1, subtitle: nil)
    }
}

private let containerRoots = [
    "/var/mobile/Containers/Data/Application",
    "/var/mobile/Containers/Shared/AppGroup",
]

private let bundleRoot = "/var/containers/Bundle/Application"

private func hasBundleLabels(_ path: String) -> Bool {
    path == bundleRoot || (path as NSString).deletingLastPathComponent == bundleRoot
}

private func isContainerPath(_ path: String) -> Bool {
    containerRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
}

private func listContainerFiles(_ deviceID: String, path: String) async throws -> [Entry] {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/DeviceFiles/container_files.py")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [script.path, "--device", deviceID, "--path", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw BridgeError(message: "実機のコンテナ一覧を取得できませんでした。")
        }
        guard process.terminationStatus == 0, reply.ok else {
            throw BridgeError(message: reply.error ?? "コンテナ一覧の取得に失敗しました。")
        }
        return reply.entries ?? []
    }.value
}

private func listDVTFiles(_ deviceID: String, path: String) async throws -> [Entry] {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/DeviceFiles/dvt_files.py")
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let python = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw BridgeError(message: "pymobiledevice3 を実行できる Python が見つかりません。")
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        process.arguments = [script.path, "--device", deviceID, "--path", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw BridgeError(message: "実機DVTの一覧を取得できませんでした。")
        }
        guard process.terminationStatus == 0, reply.ok else {
            throw BridgeError(message: reply.error ?? "実機DVTの一覧取得に失敗しました。")
        }
        return reply.entries ?? []
    }.value
}

@MainActor @Observable
final class Browser {
    var devices: [Device] = []
    var deviceID: String?
    var entries: [Entry] = []
    var path = "/"
    var locationToken = 0
    var scope: BrowseScope = .media
    var backStack: [(BrowseScope, String)] = []
    var forwardStack: [(BrowseScope, String)] = []
    var selection: Set<String> = []
    var cards: [PayCard] = []
    var cardsLoaded = false
    private var cardSnapshot: String?
    var busy = false
    var exportsInFlight = 0
    var rowActivity: [String: RowActivity] = [:]
    var pending: [PendingTransfer] = []
    var batchDone = 0
    var batchTotal = 0
    private var transferTail: Task<Void, Never>?
    var error: String?
    var status = "USBでiPad / iPhoneを接続してください"
    var notice: String?
    var pocResult: PoCResult?
    var device: Device? { devices.first { $0.id == deviceID } }
    var selectedEntries: [Entry] { entries.filter { selection.contains($0.id) } }
    var selected: Entry? { selectedEntries.count == 1 ? selectedEntries[0] : nil }
    var blocksNewWork: Bool { busy || exportsInFlight > 0 }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != "/" }
    var canModify: Bool { scope == .media }

    func canDelete(_ entry: Entry) -> Bool {
        guard entry.isFile || entry.isDirectory else { return false }
        return scope == .media || !isProtectedDevicePath(entry.id)
    }

    func canExport(_ entry: Entry) -> Bool {
        if entry.isFile { return true }
        return entry.isDirectory && (scope == .media || !isProtectedDevicePath(entry.id))
    }

    func perform(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard !blocksNewWork else { return }
        busy = true
        status = label
        Task {
            defer { busy = false }
            do {
                try await action()
                if status == label { status = "\(label) — 完了" }
            } catch {
                self.error = error.localizedDescription
                status = "操作が完了しませんでした"
            }
        }
    }

    func scan() {
        perform("USB端末を検索") {
            let found = try await bridge(["devices"]).devices ?? []
            self.devices = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !found.contains(where: { $0.id == self.deviceID }) {
                self.discardCards()
                self.deviceID = found.first(where: { $0.product.hasPrefix("iPad") })?.id ?? self.devices.first?.id
                self.path = "/"
                self.scope = .media
            }
            self.entries = []
            self.selection = []
            if self.deviceID != nil { try await self.load(self.path) }
        }
    }

    func connect(_ id: String?) {
        guard id != deviceID, !busy else { return }
        discardCards()
        deviceID = id
        entries = []
        selection = []
        path = "/"
        scope = .media
        backStack.removeAll()
        forwardStack.removeAll()
        if id != nil { reload() }
    }

    private struct Listing {
        var entries: [Entry]
        var notice: String?
    }

    private func fetchListing(_ target: String) async throws -> Listing {
        guard let id = deviceID else { throw BridgeError(message: "USB端末が選択されていません。") }
        let loaded: [Entry]
        let listingNotice: String?
        if scope == .media {
            loaded = try await bridge(["list", id, target]).entries ?? []
            listingNotice = nil
        } else {
            do {
                var dvtEntries = try await listDVTFiles(id, path: target)
                if target == containerRoots[0] || hasBundleLabels(target),
                   let labeled = try? await listContainerFiles(id, path: target) {
                    let labels = Dictionary(uniqueKeysWithValues: labeled.map { ($0.id, $0.subtitle) })
                    dvtEntries = dvtEntries.map {
                        Entry(id: $0.id, name: $0.name, kind: $0.kind, size: $0.size,
                              subtitle: labels[$0.id] ?? nil)
                    }
                }
                loaded = dvtEntries
                listingNotice = nil
            } catch {
                if isContainerPath(target) {
                    loaded = try await listContainerFiles(id, path: target)
                    listingNotice = nil
                } else {
                    loaded = airliftChildren(of: target)
                    listingNotice = loaded.isEmpty
                        ? "子項目名の列挙は実機DVTの公開対象外です。既知パスのファイル内容はAirliftで読書きできます。"
                        : nil
                }
            }
        }
        return Listing(entries: loaded.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, notice: listingNotice)
    }

    private func apply(_ listing: Listing, path target: String, selection: Set<String> = []) {
        entries = listing.entries
        notice = listing.notice
        path = target
        self.selection = selection
        locationToken += 1
    }

    private func isBrowsable(_ target: String, _ listing: Listing) -> Bool {
        listing.notice == nil || airliftHierarchy[target] != nil
    }

    private func load(_ target: String) async throws {
        if scope == .cards {
            path = "/"
            if !cardsLoaded { try await loadCards() }
            return
        }
        apply(try await fetchListing(target), path: target)
    }

    private func discardCards() {
        if let cardSnapshot {
            try? FileManager.default.removeItem(atPath: cardSnapshot)
        }
        cardSnapshot = nil
        cards = []
        cardsLoaded = false
    }

    private func loadCards() async throws {
        guard let id = deviceID else { throw BridgeError(message: "USB端末が選択されていません。") }
        let result = try await listPayCards(id)
        if let cardSnapshot, cardSnapshot != result.snapshotPath {
            try? FileManager.default.removeItem(atPath: cardSnapshot)
        }
        cardSnapshot = result.snapshotPath
        cards = result.cards ?? []
        cardsLoaded = true
        path = "/"
        entries = []
        selection = []
        status = cards.isEmpty
            ? "支払いカードはありません。端末側のCardsは元の場所へ戻しました。"
            : "Apple Payカード \(cards.count) 枚。端末側のCardsは元の場所へ戻しました。"
    }

    func openPastedPath(_ raw: String) {
        guard let target = normalizeDevicePath(raw) else {
            error = "「/」で始まる絶対パスを貼り付けてください。"
            return
        }
        let previous = (scope, path)
        perform("パスを開く") {
            self.scope = .system
            do {
                let opened = try await self.reveal(target)
                if previous != (.system, opened) {
                    self.backStack.append(previous)
                    self.forwardStack.removeAll()
                }
            } catch {
                self.scope = previous.0
                throw error
            }
        }
    }

    private func reveal(_ target: String) async throws -> String {
        if let listing = try? await fetchListing(target), isBrowsable(target, listing) {
            apply(listing, path: target)
            return target
        }
        let parent = (target as NSString).deletingLastPathComponent
        let leaf = (target as NSString).lastPathComponent
        guard parent != target else { throw BridgeError(message: "「\(target)」を開けません。") }
        let parentListing = try await fetchListing(parent)
        guard isBrowsable(parent, parentListing),
              let match = parentListing.entries.first(where: { $0.name == leaf }) else {
            throw BridgeError(message: "「\(target)」は見つかりません。")
        }
        if match.isDirectory {
            let child = try await fetchListing(match.id)
            guard isBrowsable(match.id, child) else {
                throw BridgeError(message: "「\(target)」を開けません。")
            }
            apply(child, path: match.id)
            return match.id
        }
        apply(parentListing, path: parent, selection: [match.id])
        return parent
    }

    func navigate(_ target: String, remember: Bool = true) {
        guard target != path else { return }
        let previous = (scope, path)
        perform(scope == .media ? "フォルダを読み込み" : "実機階層を読み込み") {
            try await self.load(target)
            if remember {
                self.backStack.append(previous)
                self.forwardStack.removeAll()
            }
        }
    }

    func reload() {
        if scope == .cards {
            perform("Apple Payカードを読み込み") { try await self.loadCards() }
            return
        }
        perform(scope == .media ? "フォルダを読み込み" : "実機階層を読み込み") {
            try await self.load(self.path)
        }
    }

    func showCards() {
        guard scope != .cards else { return }
        let previous = (scope, path)
        if cardsLoaded {
            scope = .cards
            path = "/"
            entries = []
            selection = []
            backStack.append(previous)
            forwardStack.removeAll()
            locationToken += 1
            return
        }
        scope = .cards
        path = "/"
        perform("Apple Payカードを読み込み") {
            do {
                try await self.loadCards()
                self.backStack.append(previous)
                self.forwardStack.removeAll()
            } catch {
                self.scope = previous.0
                self.path = previous.1
                throw error
            }
        }
    }

    func replaceCard(_ card: PayCard, with url: URL) {
        guard let deviceID, !card.assets.isEmpty else { return }
        perform("券面を差し替えています") {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            let result = try await editCard(deviceID, arguments: self.assetArguments(card) + ["--image", copy.path])
            self.applyCardPreview(card.id, result)
            self.status = result.walletRestarted == true
                ? "券面を差し替え、Walletを再起動しました。"
                : "券面を差し替えました。Walletを開き直すと反映されます。"
        }
    }

    func restoreCard(_ card: PayCard) {
        guard let deviceID, !card.assets.isEmpty else { return }
        perform("元の券面を戻しています") {
            let result = try await editCard(deviceID, arguments: self.assetArguments(card) + ["--restore"])
            self.applyCardPreview(card.id, result)
            self.status = result.walletRestarted == true
                ? "元の券面を戻し、Walletを再起動しました。"
                : "元の券面を戻しました。Walletを開き直すと反映されます。"
        }
    }

    private func applyCardPreview(_ cardID: String, _ result: CardEditResult) {
        guard let thumb = result.thumbnailPath,
              let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        var updated = cards[index]
        updated.thumbnailPath = thumb
        cards[index] = updated
    }

    private func assetArguments(_ card: PayCard) -> [String] {
        card.assets.flatMap { ["--asset", "\($0.name):\($0.width):\($0.height)"] } + ["--card-id=\(card.id)"]
    }

    func showMedia() { switchLocation(.media, path: "/") }
    func showSystem(_ path: String = "/") { switchLocation(.system, path: path) }

    private func switchLocation(_ newScope: BrowseScope, path target: String) {
        guard newScope != scope || target != path else { return }
        let previous = (scope, path)
        scope = newScope
        perform(newScope == .media ? "Mediaを読み込み" : "実機階層を読み込み") {
            do {
                try await self.load(target)
                self.backStack.append(previous)
                self.forwardStack.removeAll()
            } catch {
                self.scope = previous.0
                throw error
            }
        }
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        let current = (scope, path)
        let oldScope = scope
        scope = target.0
        perform(target.0 == .media ? "フォルダを読み込み" : "実機階層を読み込み") {
            do {
                try await self.load(target.1)
                self.forwardStack.append(current)
            } catch {
                self.scope = oldScope
                self.backStack.append(target)
                throw error
            }
        }
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        let current = (scope, path)
        let oldScope = scope
        scope = target.0
        perform(target.0 == .media ? "フォルダを読み込み" : "実機階層を読み込み") {
            do {
                try await self.load(target.1)
                self.backStack.append(current)
            } catch {
                self.scope = oldScope
                self.forwardStack.append(target)
                throw error
            }
        }
    }

    func goUp() {
        guard canGoUp else { return }
        navigate((path as NSString).deletingLastPathComponent)
    }

    func openSelected() {
        if let entry = selected, entry.isDirectory { navigate(entry.id) }
    }

    private func child(_ name: String, in directory: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else {
            throw BridgeError(message: "名前は1〜255バイトで指定してください。「/」「.」「..」は使用できません。")
        }
        return directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    private func child(_ name: String) throws -> String {
        try child(name, in: path)
    }

    private func withTransfer<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = transferTail
        let task = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await body()
        }
        transferTail = Task { @MainActor in
            _ = try? await task.value
        }
        return try await task.value
    }

    private func performBatch(
        _ label: String,
        entries: [Entry],
        refresh: Bool = true,
        operation: @escaping @MainActor (Entry) async throws -> Void,
        then: (@MainActor () -> Void)? = nil
    ) {
        guard !blocksNewWork, !entries.isEmpty else { return }
        busy = true
        status = label
        batchDone = 0
        batchTotal = entries.count
        for entry in entries { rowActivity[entry.id] = RowActivity(fraction: 0) }
        Task {
            var failures: [String] = []
            for entry in entries {
                status = "\(label)（\(self.batchDone + 1)/\(self.batchTotal)）\(entry.name)"
                do {
                    try await self.withTransfer {
                        self.rowActivity[entry.id] = RowActivity(fraction: nil)
                        try await operation(entry)
                    }
                    self.rowActivity[entry.id] = RowActivity(fraction: 1)
                } catch {
                    failures.append("\(entry.name): \(error.localizedDescription)")
                    self.rowActivity[entry.id] = nil
                }
                self.batchDone += 1
            }
            if refresh {
                do { try await self.load(self.path) }
                catch { failures.append(error.localizedDescription) }
            }
            self.rowActivity = [:]
            self.batchDone = 0
            self.batchTotal = 0
            self.busy = false
            if failures.isEmpty {
                self.status = "\(label) — 完了"
            } else {
                self.error = failures.joined(separator: "\n")
                self.status = failures.count == entries.count
                    ? "操作が完了しませんでした" : "一部の操作が完了しませんでした"
            }
            then?()
        }
    }

    fileprivate func finishFinderExport(_ id: String, error: String?) {
        rowActivity[id] = nil
        if let error {
            self.error = error
            status = "Finderへのコピーが完了しませんでした"
        } else if self.error == nil {
            status = "Finderへコピー — 完了"
        }
    }

    fileprivate func dragRequests(for entry: Entry) -> [ExportRequest] {
        guard !blocksNewWork, let deviceID, canExport(entry) else { return [] }
        let chosen = selection.contains(entry.id)
            ? selectedEntries.filter(canExport)
            : [entry]
        return chosen.map { ExportRequest(deviceID: deviceID, scope: scope, entry: $0) }
    }

    func importDroppedURLs(_ urls: [URL]) {
        guard !blocksNewWork, let deviceID, scope != .cards, !urls.isEmpty else { return }
        let directory = path
        let scope = scope
        perform("ファイルを受信") {
            let staged = try stageDroppedURLs(urls)
            defer { try? FileManager.default.removeItem(at: staged.root) }
            try await self.transmit(staged.files, to: directory, deviceID: deviceID, scope: scope)
            self.status = "ファイルを受信"
        }
    }

    func importProviders(_ providers: [NSItemProvider]) {
        guard !blocksNewWork, let deviceID, scope != .cards, !providers.isEmpty else { return }
        guard !providers.contains(where: { $0.registeredTypeIdentifiers.contains(deviceDragType) }) else { return }
        let directory = path
        let scope = scope
        perform("ファイルを受信") {
            let staged = try await stageDropped(providers)
            defer { try? FileManager.default.removeItem(at: staged.root) }
            try await self.transmit(staged.files, to: directory, deviceID: deviceID, scope: scope)
            self.status = "ファイルを受信"
        }
    }

    private func transmit(_ urls: [URL], to directory: String, deviceID: String, scope: BrowseScope) async throws {
        pending = urls.map { PendingTransfer(id: $0.path, name: $0.lastPathComponent, fraction: 0) }
        batchDone = 0
        batchTotal = urls.count
        defer {
            pending = []
            batchDone = 0
            batchTotal = 0
        }
        var failures: [String] = []
        for url in urls {
            if let index = pending.firstIndex(where: { $0.id == url.path }) {
                pending[index].fraction = nil
            }
            status = "送信 \(url.lastPathComponent)"
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try await withTransfer {
                    try await self.sendLocal(url, to: directory, deviceID: deviceID, scope: scope)
                }
                if let index = pending.firstIndex(where: { $0.id == url.path }) {
                    pending[index].fraction = 1
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            batchDone += 1
        }
        do { try await load(path) }
        catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty {
            throw BridgeError(message: failures.joined(separator: "\n"))
        }
    }

    private func sendLocal(_ url: URL, to directory: String, deviceID: String, scope: BrowseScope) async throws {
        var directoryItem = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directoryItem) else {
            throw BridgeError(message: "「\(url.lastPathComponent)」が見つかりません。")
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw BridgeError(message: "「\(url.lastPathComponent)」はシンボリックリンクです。")
        }
        if directoryItem.boolValue {
            guard scope == .media else {
                throw BridgeError(message: "「\(url.lastPathComponent)」はフォルダです。端末ファイルへはファイルだけ送れます。")
            }
            let remote = try child(url.lastPathComponent, in: directory)
            _ = try await bridge(["mkdir", deviceID, remote])
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ".DS_Store" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for childURL in children {
                try await sendLocal(childURL, to: remote, deviceID: deviceID, scope: scope)
            }
            return
        }
        if scope == .media {
            _ = try await bridge(["put", deviceID, try child(url.lastPathComponent, in: directory), url.path])
        } else {
            _ = try await writeOutside(deviceID, target: directory, local: url)
        }
    }

    private func save(_ entry: Entry, to destination: URL, deviceID: String, scope: BrowseScope) async throws {
        if scope == .system && entry.isDirectory && isProtectedDevicePath(entry.id) {
            throw BridgeError(message: "「\(entry.name)」はシステム階層のため抽出できません。")
        }
        switch scope {
        case .media:
            try await saveMedia(entry, to: destination, deviceID: deviceID)
        case .system:
            do {
                _ = try await moveOutside(deviceID, target: entry.id, local: destination)
            } catch {
                if entry.isDirectory { try? FileManager.default.removeItem(at: destination) }
                throw error
            }
        case .cards:
            throw BridgeError(message: "カードはこの操作の対象外です。")
        }
    }

    func mkdir(_ name: String) {
        guard canModify, let id = deviceID else { return }
        perform("フォルダを作成") {
            _ = try await bridge(["mkdir", id, self.child(name)])
            try await self.load(self.path)
        }
    }

    func rename(_ entry: Entry, to name: String) {
        guard canModify, let id = deviceID else { return }
        perform("名前を変更") {
            _ = try await bridge(["rename", id, entry.id, self.child(name)])
            try await self.load(self.path)
        }
    }

    func remove(_ entries: [Entry]) {
        let targets = entries.filter(canDelete)
        guard let id = deviceID, !targets.isEmpty else { return }
        performBatch("項目を削除", entries: targets) { entry in
            if self.scope == .media {
                _ = try await bridge(["remove", id, entry.id])
            } else {
                _ = try await moveOutside(id, target: entry.id)
            }
        }
    }

    func upload() {
        guard let id = deviceID, scope != .cards, !blocksNewWork else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = scope == .media
        panel.allowsMultipleSelection = true
        panel.message = scope == .media
            ? "現在のフォルダへ送ります。フォルダも含められます。同名は上書きしません。"
            : "現在のフォルダへファイルを書込み、全バイトを照合します。同名は上書きしません。"
        let directory = path
        let scope = scope
        perform("ファイルを送信") {
            guard await panel.begin() == .OK, !panel.urls.isEmpty else {
                self.status = "送信をキャンセルしました"
                return
            }
            try await self.transmit(panel.urls, to: directory, deviceID: id, scope: scope)
            self.status = "ファイルを送信"
        }
    }

    func download() {
        let targets = selectedEntries.filter(canExport)
        guard let id = deviceID, !targets.isEmpty, !blocksNewWork else { return }
        if targets.count == 1, let only = targets.first, only.isFile {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = only.name
            panel.message = "既存ファイルとは別の名前で保存してください（上書きなし）。"
            perform("Macに保存") {
                guard await panel.begin() == .OK, let url = panel.url else {
                    self.status = "保存をキャンセルしました"
                    return
                }
                self.rowActivity[only.id] = RowActivity(fraction: nil)
                defer { self.rowActivity[only.id] = nil }
                try await self.withTransfer {
                    try await self.save(only, to: url, deviceID: id, scope: self.scope)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "保存"
        panel.message = "選択した項目を、このフォルダの中へ同じ名前で保存します。"
        Task {
            guard await panel.begin() == .OK, let folder = panel.url else { return }
            guard !self.blocksNewWork else {
                self.error = "別の処理が終わるまで待ってください。"
                return
            }
            let saved = URLBox()
            self.performBatch("Macに保存", entries: targets, refresh: false) { entry in
                let destination = folder.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    throw BridgeError(message: "「\(entry.name)」は保存先に既にあります。上書きしません。")
                }
                try await self.save(entry, to: destination, deviceID: id, scope: self.scope)
                saved.items.append(destination)
            } then: {
                if !saved.items.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved.items) }
            }
        }
    }

    func runPoC(target: String) {
        guard let id = deviceID else { return }
        perform("AirTrafficサンドボックス境界を検証") {
            self.pocResult = try await runPoCProcess(id, target: target)
        }
    }
}

struct FinderDragMonitor: NSViewRepresentable {
    let browser: Browser
    let entries: [Entry]

    func makeNSView(context: Context) -> FinderDragMonitorView {
        FinderDragMonitorView()
    }

    func updateNSView(_ view: FinderDragMonitorView, context: Context) {
        view.browser = browser
        view.entries = entries
    }
}

final class FinderDragMonitorView: NSView, NSDraggingSource {
    var browser: Browser?
    var entries: [Entry] = []
    private var passingThrough = false
    private var anchorRow: Int?
    private var kept: [FinderFilePromise] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        passingThrough ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let origin = event.locationInWindow
        guard let row = row(at: origin) else {
            pass(event)
            return
        }
        if event.clickCount >= 2 {
            MainActor.assumeIsolated {
                guard let browser, entries.indices.contains(row) else { return }
                let entry = entries[row]
                browser.selection = [entry.id]
                if entry.isDirectory { browser.navigate(entry.id) }
            }
            return
        }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                MainActor.assumeIsolated { applyClick(row: row, flags: event.modifierFlags) }
                return
            }
            let moved = hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y)
            if moved >= 4 {
                startDrag(row: row, event: next)
                return
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        passingThrough = true
        window?.contentView?.hitTest(event.locationInWindow)?.rightMouseDown(with: event)
        passingThrough = false
    }

    override func scrollWheel(with event: NSEvent) {
        passingThrough = true
        window?.contentView?.hitTest(event.locationInWindow)?.scrollWheel(with: event)
        passingThrough = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FinderDragGate.active ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if FinderDragGate.active { return false }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        MainActor.assumeIsolated { browser?.importDroppedURLs(urls) }
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let finished = kept
        kept = []
        DispatchQueue.main.async { _ = finished }
    }

    private func pass(_ event: NSEvent) {
        passingThrough = true
        window?.contentView?.hitTest(event.locationInWindow)?.mouseDown(with: event)
        passingThrough = false
    }

    private func applyClick(row: Int, flags: NSEvent.ModifierFlags) {
        guard let browser, entries.indices.contains(row) else { return }
        let id = entries[row].id
        if flags.contains(.shift), let anchorRow, entries.indices.contains(anchorRow) {
            let bounds = min(anchorRow, row)...max(anchorRow, row)
            browser.selection = Set(bounds.map { entries[$0].id })
        } else if flags.contains(.command) {
            if browser.selection.contains(id) { browser.selection.remove(id) }
            else { browser.selection.insert(id) }
            anchorRow = row
        } else {
            browser.selection = [id]
            anchorRow = row
        }
    }

    private func startDrag(row: Int, event: NSEvent) {
        MainActor.assumeIsolated {
            guard let browser, entries.indices.contains(row) else { return }
            let entry = entries[row]
            if !browser.selection.contains(entry.id) { browser.selection = [entry.id] }
            let requests = browser.dragRequests(for: entry)
            guard !requests.isEmpty else { return }
            let handoff = MainHandoff(value: browser)
            let anchor = convert(event.locationInWindow, from: nil)
            var items: [NSDraggingItem] = []
            var promises: [FinderFilePromise] = []
            for (index, request) in requests.enumerated() {
                let promise = FinderFilePromise(request: request, handoff: handoff)
                let type = request.entry.isDirectory ? UTType.folder.identifier : UTType.data.identifier
                let provider = NSFilePromiseProvider(fileType: type, delegate: promise)
                let item = NSDraggingItem(pasteboardWriter: provider)
                let frame = NSRect(
                    x: anchor.x + CGFloat(index) * 8 - 16,
                    y: anchor.y - CGFloat(index) * 4 - 16,
                    width: 32, height: 32)
                let symbol = request.entry.isDirectory ? "folder.fill" : "doc"
                item.setDraggingFrame(frame, contents: NSImage(systemSymbolName: symbol, accessibilityDescription: request.entry.name))
                items.append(item)
                promises.append(promise)
            }
            kept = promises
            FinderDragGate.active = true
            defer { FinderDragGate.active = false }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .pile
        }
    }

    private func row(at windowPoint: NSPoint) -> Int? {
        guard let table = fileTable() else { return nil }
        let local = table.convert(windowPoint, from: nil)
        guard table.bounds.contains(local) else { return nil }
        let index = table.row(at: local)
        guard entries.indices.contains(index) else { return nil }
        return index
    }

    private func fileTable() -> NSTableView? {
        var view: NSView? = superview
        while let current = view {
            if let table = FinderDragMonitorView.firstTable(in: current, skipping: self) { return table }
            view = current.superview
        }
        return nil
    }

    private static func firstTable(in view: NSView, skipping skipped: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews where child !== skipped && !child.isDescendant(of: skipped) {
            if let found = firstTable(in: child, skipping: skipped) { return found }
        }
        return nil
    }
}

private func writeFinderExport(_ request: ExportRequest, to destination: URL) async throws {
    if request.scope == .system && request.entry.isDirectory && isProtectedDevicePath(request.entry.id) {
        throw BridgeError(message: "「\(request.entry.name)」はシステム階層のため抽出できません。")
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        throw BridgeError(message: "「\(request.entry.name)」は保存先に既にあります。上書きしません。")
    }
    switch request.scope {
    case .media:
        try await saveMedia(request.entry, to: destination, deviceID: request.deviceID)
    case .system:
        do {
            _ = try await moveOutside(request.deviceID, target: request.entry.id, local: destination)
        } catch {
            if request.entry.isDirectory { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    case .cards:
        throw BridgeError(message: "カードはこの操作の対象外です。")
    }
}

private actor FinderExportQueue {
    private var last: Task<Void, Never>?

    func run(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = last
        let current = Task { () throws -> Void in
            await previous?.value
            try await body()
        }
        last = Task { _ = try? await current.value }
        try await current.value
    }
}

private let finderExportQueue = FinderExportQueue()

private let finderPromiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "AirliftFinderPromise"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    return queue
}()

private final class FinderFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let fileName: String
    private let request: ExportRequest
    private let handoff: MainHandoff<Browser>

    init(request: ExportRequest, handoff: MainHandoff<Browser>) {
        fileName = request.entry.name
        self.request = request
        self.handoff = handoff
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        finderPromiseQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        let request = request
        let handoff = handoff
        // Finder waits on this callback while the main thread is inside the drag loop.
        // The file has to be written without hopping to the main actor, or the drag never ends.
        Task {
            var failure: String?
            do {
                try await finderExportQueue.run {
                    try await writeFinderExport(request, to: url)
                }
            } catch {
                failure = error.localizedDescription
            }
            completionHandler(failure.map { BridgeError(message: $0) })
            await handoff.value.finishFinderExport(request.entry.id, error: failure)
        }
    }
}
