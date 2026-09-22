import AppKit
import Observation

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
    var selection: String?
    var cards: [PayCard] = []
    var cardsLoaded = false
    private var cardSnapshot: String?
    var busy = false
    var error: String?
    var status = "USBでiPad / iPhoneを接続してください"
    var notice: String?
    var pocResult: PoCResult?
    var device: Device? { devices.first { $0.id == deviceID } }
    var selected: Entry? { entries.first { $0.id == selection } }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != "/" }
    var canModify: Bool { scope == .media }

    func canDelete(_ entry: Entry) -> Bool {
        scope == .media ? entry.isFile || entry.isDirectory : entry.isFile
    }

    func perform(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
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
            self.selection = nil
            if self.deviceID != nil { try await self.load(self.path) }
        }
    }

    func connect(_ id: String?) {
        guard id != deviceID, !busy else { return }
        discardCards()
        deviceID = id
        entries = []
        selection = nil
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

    private func apply(_ listing: Listing, path target: String, selection: String? = nil) {
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
        selection = nil
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
        apply(parentListing, path: parent, selection: match.id)
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
            selection = nil
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

    private func child(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else {
            throw BridgeError(message: "名前は1〜255バイトで指定してください。「/」「.」「..」は使用できません。")
        }
        return path == "/" ? "/\(name)" : "\(path)/\(name)"
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

    func remove(_ entry: Entry) {
        guard canDelete(entry), let id = deviceID else { return }
        perform("項目を削除") {
            if self.scope == .media {
                _ = try await bridge(["remove", id, entry.id])
            } else {
                let result = try await moveOutside(id, target: entry.id)
                self.status = "Airlift削除・対象不在・復元完了: \(result.target ?? entry.id)"
            }
            try await self.load(self.path)
        }
    }

    func upload() {
        guard let id = deviceID else { return }
        perform("ファイルを送信") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = self.scope == .media
                ? "128 MiB以下のファイルを送信します。同名ファイルは上書きしません。"
                : "入力元のファイル名を保持してAirlift書込みし、全バイトを照合します。同名項目は上書きしません。"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            if self.scope == .media {
                _ = try await bridge(["put", id, self.child(url.lastPathComponent), url.path])
                try await self.load(self.path)
            } else {
                try await self.load(self.path)
                guard self.notice == nil else {
                    throw BridgeError(message: "同名項目の有無を取得できるディレクトリだけ、元のファイル名で書込めます。")
                }
                guard !self.entries.contains(where: { $0.name == url.lastPathComponent }) else {
                    throw BridgeError(message: "同名の項目があります。上書きせず、入力元の名前を変更してください。")
                }
                let result = try await writeOutside(id, target: self.path, local: url)
                self.status = "書込み・完全一致・復元完了: \(result.target ?? self.path)"
                try await self.load(self.path)
            }
        }
    }

    func download() {
        guard let id = deviceID, let entry = selected, entry.isFile else { return }
        perform("Macに保存") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            panel.message = "既存ファイルとは別の名前で保存してください（上書きなし）。"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            if self.scope == .media {
                _ = try await bridge(["get", id, entry.id, url.path])
            } else {
                let result = try await moveOutside(id, target: entry.id, local: url)
                self.status = "抽出・完全一致・元位置へ復元完了: \(result.target ?? entry.id)"
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func runPoC(target: String) {
        guard let id = deviceID else { return }
        perform("AirTrafficサンドボックス境界を検証") {
            self.pocResult = try await runPoCProcess(id, target: target)
        }
    }
}
