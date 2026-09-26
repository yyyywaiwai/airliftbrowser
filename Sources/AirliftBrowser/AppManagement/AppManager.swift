import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppManager {
    var deviceID: String?
    var apps: [ManagedApp] = []
    var backups: [AppBackup] = []
    var pending: [PendingAppOperation] = []
    var appID: String?
    var backupID: String?
    var renamingBackup: AppBackup?
    var regionID: String?
    var files: [AppFile] = []
    var selection: Set<String> = []
    var relativePath = ""
    var search = ""
    var fileSearch = ""
    var category = "all"
    var libraryMode = false
    var busy = false
    var status = String(localized: "アプリを選んでください")
    var fraction: Double?
    var error: String?
    var warnings: [String] = []
    var restoreMismatch: String?
    private var mismatchRestore: (backup: AppBackup, target: ManagedApp, mode: String, mappings: [String: String])?
    var fileListingError: String?
    var operation: AppOperation?
    var showOperation = false
    var verificationEnabled = UserDefaults.standard.object(forKey: "appTransferVerification") as? Bool ?? true {
        didSet { UserDefaults.standard.set(verificationEnabled, forKey: "appTransferVerification") }
    }
    private var cancellationURL: URL?
    private var progressStatus: String?
    private var nextActivation: (device: String?, library: Bool)?
    private var finderExportID: UUID?
    private var finderExportRemaining = 0
    private var finderExportFailures: [String] = []
    private var fileIndexes: [AppFileIndex.Key: AppFileIndex] = [:]
    private let service: AppService.Handler

    init(service: @escaping AppService.Handler = AppService.call) {
        self.service = service
    }

    private var fileIndexKey: AppFileIndex.Key? {
        guard !libraryMode, let deviceID, let appID, let currentRegion else { return nil }
        return AppFileIndex.Key(device: deviceID, app: appID, region: currentRegion.id,
                                containerPath: currentRegion.path)
    }

    var app: ManagedApp? { apps.first { $0.id == appID } }
    var backup: AppBackup? { backups.first { $0.id == backupID } }
    var regions: [AppRegion] { libraryMode ? backup?.regions ?? [] : app?.regions ?? [] }
    var currentRegion: AppRegion? { regions.first { $0.id == regionID } }
    var title: String {
        libraryMode ? backup?.name ?? String(localized: "バックアップ") : app?.name ?? String(localized: "アプリ")
    }
    var visibleApps: [ManagedApp] {
        apps.filter { (category == "all" || $0.category == category) &&
            (search.isEmpty || $0.name.localizedStandardContains(search) || $0.bundleID.localizedStandardContains(search)) }
    }
    var visibleBackups: [AppBackup] {
        backups.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.bundleID.localizedStandardContains(search) }
    }
    var visibleFiles: [AppFile] {
        files.filter { fileSearch.isEmpty || $0.name.localizedStandardContains(fileSearch) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var selectedFile: AppFile? { selection.count == 1 ? files.first { selection.contains($0.id) } : nil }
    var canBrowse: Bool { libraryMode ? backup != nil : app != nil && deviceID != nil }
    var canEdit: Bool { libraryMode || currentRegion?.kind != "bundle" }
    var canTransferFiles: Bool { !busy && canBrowse && currentRegion != nil }
    var canReceiveFiles: Bool { canTransferFiles && canEdit && fileListingError == nil }

    func finderPromises(for id: String) -> [AppFinderFilePromise] {
        guard canTransferFiles else { return [] }
        if !selection.contains(id) { selection = [id] }
        let files = visibleFiles.filter { selection.contains($0.id) && ($0.isDirectory || $0.kind == "file") }
        let exportID = UUID()
        let appName = title
        let cancelURL = FileManager.default.temporaryDirectory.appendingPathComponent("airlift-cancel-\(exportID.uuidString)")
        return files.map { file in
            var request = context("get", relative: file.id)
            request.file = file
            request.cancelPath = cancelURL.path
            return AppFinderFilePromise(file: file, request: request) { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    self?.updateFinderExport(event, id: exportID, count: files.count, appName: appName, cancelURL: cancelURL)
                }
            }
        }
    }

    func updateFinderExport(_ event: AppFinderExportEvent, id: UUID, count: Int, appName: String, cancelURL: URL) {
        switch event {
        case .started(let name):
            if finderExportID == nil {
                finderExportID = id
                finderExportRemaining = count
                finderExportFailures = []
                busy = true
                fraction = nil
                cancellationURL = cancelURL
                operation = AppOperation(title: String(localized: "Finderへコピー（\(count) 項目）"), appName: appName)
                showOperation = false
            }
            guard finderExportID == id else { return }
            status = String(localized: "Finderへコピー中: \(name)")
            operation?.message = status
            operation?.append(status)
        case .progress(let response):
            guard finderExportID == id else { return }
            updateProgress(response)
        case .finished(let name, let failure):
            guard finderExportID == id else { return }
            if let failure { finderExportFailures.append("\(name): \(failure)") }
            operation?.append(failure.map { String(localized: "コピーできませんでした: \(name) — \($0)") }
                ?? String(localized: "コピーしました: \(name)"))
            finderExportRemaining -= 1
            guard finderExportRemaining == 0 else {
                fraction = nil
                status = String(localized: "Finderへコピー中（残り \(finderExportRemaining) 項目）")
                return
            }
            let failed = !finderExportFailures.isEmpty
            status = failed
                ? String(localized: "Finderへのコピーを完了できませんでした")
                : String(localized: "Finderへのコピーが完了しました")
            operation?.finish(status, failed: failed)
            if failed { error = finderExportFailures.joined(separator: "\n") }
            finderExportID = nil
            finishWork()
        }
    }

    @discardableResult
    func importDroppedURLs(_ urls: [URL]) -> Bool {
        guard canReceiveFiles, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        perform(String(localized: "ファイルを追加")) {
            let staged = try stageDroppedURLs(urls)
            defer { try? FileManager.default.removeItem(at: staged.root) }
            var failures: [String] = []
            for url in staged.files {
                do {
                    // Build each request after the previous mutation: backup edits
                    // create a new revision, which becomes the next upload's target.
                    var request = self.context("mutate", relative: self.join(url.lastPathComponent))
                    request.operation = "upload"
                    request.local = url.path
                    request.overwrite = false
                    try await self.applyMutation(request)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw AppServiceError(failures.joined(separator: "\n")) }
            self.status = String(localized: "\(staged.files.count) 項目を追加しました")
        }
        return true
    }

    func activate(device: String?, library: Bool) {
        guard !busy else {
            nextActivation = (device, library)
            return
        }
        let changed = deviceID != device || libraryMode != library
        deviceID = device
        libraryMode = library
        if changed { fileIndexes = [:]; resetFiles(); warnings = [] }
        if device == nil { apps = []; pending = [] }
        perform(library ? String(localized: "バックアップを読み込み") : String(localized: "アプリを読み込み")) {
            try await self.loadBackups()
            if !library, let device {
                let response = try await self.call(AppRequest(action: "catalog", device: device))
                self.apps = response.apps ?? []
                self.pending = response.pending ?? []
                self.warnings = response.warnings ?? []
            }
            if self.libraryMode, self.canBrowse {
                self.regionID = self.regions.first?.id
                try await self.loadFiles()
            } else if !self.libraryMode {
                self.resetFiles()
                self.status = self.app == nil ? String(localized: "アプリを選んでください") : String(localized: "操作を選んでください")
            }
        }
    }

    func selectApp(_ id: String?) {
        guard !busy else { return }
        appID = id
        resetFiles()
        status = app == nil ? String(localized: "アプリを選んでください") : String(localized: "操作を選んでください")
    }

    func showAppActions() {
        guard !busy else { return }
        resetFiles()
        status = String(localized: "操作を選んでください")
    }

    func selectBackup(_ id: String?) {
        guard !busy else { return }
        backupID = id
        resetFiles()
        regionID = backup?.regions.first?.id
        if backup != nil { perform(String(localized: "バックアップを開く")) { try await self.loadFiles() } }
    }

    func selectRegion(_ id: String?) {
        guard !busy else { return }
        resetFiles()
        regionID = id
        if id != nil, !showCachedFiles() { perform(String(localized: "データを開く")) { try await self.loadFiles() } }
    }

    func navigate(_ path: String) {
        guard !busy else { return }
        relativePath = path
        selection = []
        fileSearch = ""
        if !showCachedFiles() { perform(String(localized: "フォルダを開く")) { try await self.loadFiles() } }
    }

    func refresh() {
        guard !busy else { return }
        if let key = fileIndexKey { fileIndexes.removeValue(forKey: key) }
        if canBrowse, currentRegion != nil { perform(String(localized: "一覧を更新")) { try await self.loadFiles(); try await self.loadBackups() } }
        else { activate(device: deviceID, library: libraryMode) }
    }

    func backupApp(regionKinds: Set<String>) {
        guard let deviceID, let appID, !regionKinds.isEmpty else { return }
        perform(String(localized: "アプリをバックアップ"), showSheet: true) {
            let result = try await self.call(AppRequest(action: "backup", device: deviceID, appID: appID,
                                                        regionKinds: regionKinds.sorted()))
            if let saved = result.backup {
                // The helper already returned the committed snapshot. Update
                // history directly rather than launching another locked helper
                // and reporting a completed backup as failed on refresh errors.
                self.backups.removeAll { $0.id == saved.id }
                self.backups.insert(saved, at: 0)
                self.status = "\(saved.statusLabel): \(saved.dateLabel)"
                self.operation?.append(String(localized: "保存先: \(saved.path)"))
                self.operation?.failed = saved.status != "complete"
                if !saved.issues.isEmpty { self.warnings = saved.issues }
                for issue in saved.issues { self.operation?.append(String(localized: "保存できなかった項目: \(issue)")) }
            }
        }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "バックアップを読み込み")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(String(localized: "バックアップを読み込み"), showSheet: true) {
            let result = try await self.call(AppRequest(action: "import", source: url.path))
            try await self.loadBackups()
            if self.libraryMode, let saved = result.backup {
                self.backupID = saved.id
                self.resetFiles()
                self.regionID = saved.regions.first?.id
                try await self.loadFiles()
            }
            self.status = String(localized: "バックアップを読み込みました")
        }
    }

    func exportBackup(_ backup: AppBackup, xcappdata: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = backup.name + (xcappdata ? ".xcappdata" : ".airliftbackup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(String(localized: "バックアップを書き出し"), showSheet: true, appName: backup.name) {
            _ = try await self.call(AppRequest(action: "export", backupPath: backup.path, destination: url.path, xcappdata: xcappdata))
            self.status = String(localized: "バックアップを書き出しました")
        }
    }

    func renameBackup(_ backup: AppBackup, to label: String) {
        perform(String(localized: "バックアップの名前を変更")) {
            let result = try await self.call(AppRequest(action: "rename", backupPath: backup.path, label: label))
            if let saved = result.backup, let index = self.backups.firstIndex(where: { $0.id == saved.id }) {
                self.backups[index] = saved
            }
            self.status = String(localized: "名前を変更しました")
        }
    }

    func revealBackup(_ backup: AppBackup) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.path)])
    }

    func deleteBackup(_ backup: AppBackup) {
        guard !busy else { return }
        perform(String(localized: "バックアップをゴミ箱に入れる")) {
            let path = backup.path
            try await Task.detached {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }.value
            self.backups.removeAll { $0.id == backup.id }
            if self.backupID == backup.id {
                self.backupID = nil
                if self.libraryMode { self.resetFiles() }
            }
            self.status = String(localized: "「\(backup.name)」をゴミ箱に入れました")
        }
    }

    func restore(_ backup: AppBackup, target: ManagedApp, mode: String, mappings: [String: String], acceptMismatch: Bool = false) {
        guard let deviceID else { return }
        perform(String(localized: "「\(target.name)」に復元"), showSheet: true, appName: target.name) {
            var request = AppRequest(action: "restore", device: deviceID, appID: target.id,
                                     backupPath: backup.path, mode: mode, mappings: mappings)
            request.acceptMismatch = acceptMismatch ? true : nil
            let result = try await self.call(request)
            if result.confirm == "mismatch" {
                self.mismatchRestore = (backup, target, mode, mappings)
                self.restoreMismatch = result.warnings?.joined(separator: "、") ?? ""
                self.status = String(localized: "バックアップの内容が記録と一致しません")
                return
            }
            self.mismatchRestore = nil
            if !self.libraryMode, self.appID == target.id { try await self.loadFiles() }
            if let warnings = result.warnings, !warnings.isEmpty {
                self.warnings = warnings.map { String(localized: "「\($0)」は記録と違う内容で復元しました") }
                self.status = self.warnings.joined(separator: "\n")
            } else {
                self.status = String(localized: "復元が完了しました")
            }
        }
    }

    func confirmMismatchRestore() {
        guard let pending = mismatchRestore else { return }
        restoreMismatch = nil
        restore(pending.backup, target: pending.target, mode: pending.mode, mappings: pending.mappings, acceptMismatch: true)
    }

    func cancelMismatchRestore() {
        restoreMismatch = nil
        mismatchRestore = nil
    }

    func loadRestoreApps() {
        guard let deviceID else { return }
        perform(String(localized: "復元先のアプリを読み込み")) {
            let result = try await self.call(AppRequest(action: "catalog", device: deviceID))
            self.apps = result.apps ?? []
            self.pending = result.pending ?? []
        }
    }

    func recover() {
        guard let deviceID else { return }
        perform(String(localized: "中断した処理を復旧"), showSheet: true) {
            let response = try await self.call(AppRequest(action: "recover", device: deviceID))
            self.pending = response.pending ?? []
            self.status = String(localized: "中断した処理を復旧しました")
        }
    }

    func exportFile(_ file: AppFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(String(localized: "Macに保存")) {
            var request = self.context("get", relative: file.id)
            request.file = file
            request.local = url.path
            _ = try await self.call(request)
        }
    }

    func exportFiles(_ files: [AppFile]) {
        guard !files.isEmpty else { return }
        if files.count == 1 {
            exportFile(files[0])
            return
        }
        let panel = NSOpenPanel()
        panel.prompt = String(localized: "保存先を選択")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        perform(String(localized: "Macに保存")) {
            var failures: [String] = []
            for file in files {
                do {
                    let url = directory.appendingPathComponent(file.name)
                    guard !FileManager.default.fileExists(atPath: url.path),
                          (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                        throw AppServiceError(String(localized: "保存先に同じ名前の項目があります。"))
                    }
                    var request = self.context("get", relative: file.id)
                    request.file = file
                    request.local = url.path
                    _ = try await self.call(request)
                } catch {
                    failures.append("\(file.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw AppServiceError(failures.joined(separator: "\n")) }
        }
    }

    func upload(overwrite: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(String(localized: "ファイルを追加")) {
            var request = self.context("mutate", relative: self.join(url.lastPathComponent))
            request.operation = "upload"
            request.local = url.path
            request.overwrite = overwrite
            try await self.applyMutation(request)
        }
    }

    func replaceFile(_ file: AppFile) {
        guard file.kind == "file", canReceiveFiles, files.contains(file) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = String(localized: "「\(file.name)」を置き換え")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(String(localized: "ファイルを置き換え")) {
            var request = self.context("mutate", relative: file.id)
            request.operation = "upload"
            request.local = url.path
            request.overwrite = true
            try await self.applyMutation(request)
        }
    }

    func mutate(operation: String, file: AppFile? = nil, name: String? = nil) {
        if let name, name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            error = String(localized: "この名前は使えません。")
            return
        }
        perform(String(localized: "ファイルを変更")) {
            var request = self.context("mutate", relative: file?.id ?? self.join(name ?? ""))
            request.operation = operation
            if let name { request.destination = self.join(name) }
            try await self.applyMutation(request)
        }
    }

    func deleteFiles(_ files: [AppFile]) {
        guard canEdit, !files.isEmpty else { return }
        perform(String(localized: "ファイルを削除")) {
            var failures: [String] = []
            for file in files {
                do {
                    var request = self.context("mutate", relative: file.id)
                    request.operation = "delete"
                    try await self.applyMutation(request)
                } catch {
                    failures.append("\(file.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { throw AppServiceError(failures.joined(separator: "\n")) }
        }
    }

    func cancel() {
        guard let cancellationURL else { return }
        do {
            try Data().write(to: cancellationURL)
            status = String(localized: "中止しています。データを元の場所に戻すまでお待ちください…")
            operation?.cancelling = true
            operation?.append(status)
        }
        catch { self.error = error.localizedDescription }
    }

    private func applyMutation(_ request: AppRequest) async throws {
        let result = try await call(request)
        if let saved = result.backup {
            try await loadBackups()
            backupID = saved.id
        }
        try await loadFiles()
    }

    @discardableResult
    private func showCachedFiles() -> Bool {
        guard let key = fileIndexKey, let index = fileIndexes[key] else { return false }
        if let entries = index.entries(at: relativePath) {
            files = entries
            fileListingError = nil
            status = String(localized: "\(files.count) 項目")
        } else {
            files = []
            fileListingError = String(localized: "このフォルダは見つかりませんでした。上のフォルダに戻るか、一覧を更新してください。")
            status = String(localized: "フォルダが見つかりません")
        }
        selection = selection.intersection(Set(files.map(\.id)))
        return true
    }

    private func loadFiles() async throws {
        guard regionID != nil else { files = []; return }
        if showCachedFiles() { return }
        fileListingError = nil
        do {
            if let key = fileIndexKey {
                let result = try await call(context("list-tree", relative: ""))
                guard let tree = result.tree else { throw AppServiceError(String(localized: "ファイルの一覧を読み込めませんでした。")) }
                fileIndexes[key] = AppFileIndex(tree, sourceIdentity: result.sourceIdentity)
                showCachedFiles()
            } else {
                let result = try await call(context("list", relative: relativePath))
                files = result.entries ?? []
            }
        } catch {
            files = []
            fileListingError = error.localizedDescription
            throw error
        }
        selection = selection.intersection(Set(files.map(\.id)))
    }

    private func loadBackups() async throws {
        let result = try await call(AppRequest(action: "backups"))
        backups = result.backups ?? []
        if let issues = result.warnings, !issues.isEmpty { warnings = issues }
    }

    private func context(_ action: String, relative: String) -> AppRequest {
        AppRequest(action: action, device: libraryMode ? nil : deviceID, appID: libraryMode ? nil : appID,
                   regionID: regionID, backupPath: libraryMode ? backup?.path : nil, relative: relative,
                   containerPath: libraryMode ? nil : currentRegion?.path,
                   sourceIdentity: fileIndexKey.flatMap { fileIndexes[$0]?.sourceIdentity })
    }

    private func join(_ leaf: String) -> String { relativePath.isEmpty ? leaf : relativePath + "/" + leaf }

    private func resetFiles() {
        files = []; selection = []; relativePath = ""; regionID = nil; fileSearch = ""; fileListingError = nil
    }

    private func call(_ request: AppRequest) async throws -> AppResponse {
        var request = request
        // Invalidate before attempting writes, including failures/partial restores.
        // Shared App Groups may also be cached under a different owning app.
        if ["mutate", "restore", "recover", "catalog"].contains(request.action), let device = request.device {
            fileIndexes = fileIndexes.filter { $0.key.device != device }
        }
        if request.action == "backup" || request.action == "restore" {
            request.verify = verificationEnabled
            operation?.append(verificationEnabled ? String(localized: "内容の確認: オン") : String(localized: "内容の確認: オフ"))
        }
        request.cancelPath = cancellationURL?.path
        return try await service(request) { [weak self] response in
            await self?.updateProgress(response)
        }
    }

    private func updateProgress(_ response: AppResponse) {
        operation?.update(response)
        if let stage = operation?.stageName {
            status = stage
            progressStatus = stage
        }
        if let completed = response.completed, let total = response.total, total > 0 {
            fraction = Double(completed) / Double(total)
        } else { fraction = nil }
    }

    private func perform(_ message: String, showSheet: Bool = false, appName: String? = nil,
                         operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        fraction = nil
        status = message
        self.operation = AppOperation(title: message, appName: appName ?? title)
        showOperation = showSheet
        cancellationURL = FileManager.default.temporaryDirectory.appendingPathComponent("airlift-cancel-\(UUID().uuidString)")
        Task {
            defer { finishWork() }
            do {
                try await operation()
                if status == message || status == progressStatus {
                    status = String(localized: "完了")
                }
                self.operation?.finish(self.status, failed: self.operation?.failed ?? false)
            } catch {
                self.operation?.finish(error.localizedDescription, failed: true)
                if !showOperation { self.error = error.localizedDescription }
                status = String(localized: "処理を完了できませんでした")
                if let deviceID,
                   let result = try? await service(AppRequest(action: "pending", device: deviceID), { _ in }) {
                    pending = result.pending ?? []
                }
            }
        }
    }

    private func finishWork() {
        busy = false
        fraction = nil
        if let cancellationURL { try? FileManager.default.removeItem(at: cancellationURL) }
        cancellationURL = nil
        if let next = nextActivation {
            nextActivation = nil
            activate(device: next.device, library: next.library)
        }
    }
}
