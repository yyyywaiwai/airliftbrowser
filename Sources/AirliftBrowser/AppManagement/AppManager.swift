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
    var regionID: String?
    var files: [AppFile] = []
    var selection: Set<String> = []
    var relativePath = ""
    var search = ""
    var fileSearch = ""
    var category = "all"
    var libraryMode = false
    var busy = false
    var status = "アプリを選択してください"
    var fraction: Double?
    var error: String?
    var warnings: [String] = []
    var editor: AppEditorDocument?
    var iconURL: URL?
    var fileListingError: String?
    var operation: AppOperation?
    var verificationEnabled = UserDefaults.standard.object(forKey: "appTransferVerification") as? Bool ?? true {
        didSet { UserDefaults.standard.set(verificationEnabled, forKey: "appTransferVerification") }
    }
    private var cancellationURL: URL?
    private var workspaces: [URL] = []
    private var nextActivation: (device: String?, library: Bool)?

    var app: ManagedApp? { apps.first { $0.id == appID } }
    var backup: AppBackup? { backups.first { $0.id == backupID } }
    var regions: [AppRegion] { libraryMode ? backup?.regions ?? [] : app?.regions ?? [] }
    var currentRegion: AppRegion? { regions.first { $0.id == regionID } }
    var title: String { libraryMode ? backup?.name ?? "バックアップ" : app?.name ?? "アプリ" }
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

    func activate(device: String?, library: Bool) {
        guard !busy else {
            nextActivation = (device, library)
            return
        }
        let changed = deviceID != device || libraryMode != library
        deviceID = device
        libraryMode = library
        if changed { resetFiles(); warnings = [] }
        if device == nil { apps = []; pending = [] }
        perform(library ? "バックアップを取得" : "アプリを取得") {
            try await self.loadBackups()
            if !library, let device {
                let response = try await self.call(AppRequest(action: "catalog", device: device))
                self.apps = response.apps ?? []
                self.pending = response.pending ?? []
                self.warnings = response.warnings ?? []
            }
            if self.canBrowse {
                self.regionID = self.regions.first?.id
                try await self.loadFiles()
            }
        }
    }

    func selectApp(_ id: String?) {
        guard !busy else { return }
        appID = id
        resetFiles()
        regionID = app?.regions.first?.id
        guard app != nil else { return }
        perform("コンテナを開く") {
            try await self.loadFiles()
            if let device = self.deviceID, let app = self.app, app.identity == "installed" {
                let url = try self.workspace().appendingPathComponent("icon.png")
                if let result = try? await self.call(AppRequest(action: "icon", device: device, appID: app.id, local: url.path)), result.local != nil {
                    self.iconURL = url
                }
            }
        }
    }

    func selectBackup(_ id: String?) {
        guard !busy else { return }
        backupID = id
        resetFiles()
        regionID = backup?.regions.first?.id
        if backup != nil { perform("バックアップを開く") { try await self.loadFiles() } }
    }

    func selectRegion(_ id: String?) {
        guard !busy else { return }
        resetFiles()
        regionID = id
        if id != nil { perform("領域を開く") { try await self.loadFiles() } }
    }

    func navigate(_ path: String) {
        guard !busy else { return }
        closeEditor()
        relativePath = path
        selection = []
        fileSearch = ""
        perform("フォルダを開く") { try await self.loadFiles() }
    }

    func refresh() {
        guard !busy else { return }
        if canBrowse { perform("一覧を更新") { try await self.loadFiles(); try await self.loadBackups() } }
        else { activate(device: deviceID, library: libraryMode) }
    }

    func backupApp(regionKinds: Set<String>) {
        guard let deviceID, let appID, !regionKinds.isEmpty else { return }
        perform("アプリをバックアップ", showSheet: true) {
            let result = try await self.call(AppRequest(action: "backup", device: deviceID, appID: appID,
                                                        regionKinds: regionKinds.sorted()))
            if let saved = result.backup {
                // The helper already returned the committed snapshot. Update
                // history directly rather than launching another locked helper
                // and reporting a completed backup as failed on refresh errors.
                self.backups.removeAll { $0.id == saved.id }
                self.backups.insert(saved, at: 0)
                self.status = "\(saved.statusLabel): \(saved.dateLabel)"
                self.operation?.append("保存先: " + saved.path)
                self.operation?.failed = saved.status != "complete"
                if !saved.issues.isEmpty { self.warnings = saved.issues }
                for issue in saved.issues { self.operation?.append("未取得: " + issue) }
            }
        }
    }

    func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "バックアップ／xcappdataを読み込み"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("バックアップを読み込み", showSheet: true) {
            let result = try await self.call(AppRequest(action: "import", source: url.path))
            try await self.loadBackups()
            if self.libraryMode, let saved = result.backup {
                self.backupID = saved.id
                self.resetFiles()
                self.regionID = saved.regions.first?.id
                try await self.loadFiles()
            }
            self.status = "バックアップの読み込みが完了しました"
        }
    }

    func exportBackup(_ backup: AppBackup, xcappdata: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = backup.name + (xcappdata ? ".xcappdata" : ".airliftbackup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("バックアップを書き出し", showSheet: true, appName: backup.name) {
            _ = try await self.call(AppRequest(action: "export", backupPath: backup.path, destination: url.path, xcappdata: xcappdata))
            self.status = "バックアップの書き出しが完了しました"
        }
    }

    func revealBackup(_ backup: AppBackup) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.path)])
    }

    func deleteBackup(_ backup: AppBackup) {
        guard !busy, editor?.isDirty != true else { return }
        perform("バックアップをゴミ箱に移動") {
            let path = backup.path
            try await Task.detached {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }.value
            self.backups.removeAll { $0.id == backup.id }
            if self.backupID == backup.id {
                self.backupID = nil
                if self.libraryMode { self.resetFiles() }
            }
            self.status = "「\(backup.name)」をゴミ箱に移動しました"
        }
    }

    func restore(_ backup: AppBackup, target: ManagedApp, mode: String, mappings: [String: String]) {
        guard let deviceID else { return }
        perform("\(target.name)へ復元", showSheet: true, appName: target.name) {
            let result = try await self.call(AppRequest(action: "restore", device: deviceID, appID: target.id,
                                                       backupPath: backup.path, mode: mode, mappings: mappings))
            if !self.libraryMode, self.appID == target.id { try await self.loadFiles() }
            self.status = result.message ?? "復元が完了しました"
        }
    }

    func loadRestoreApps() {
        guard let deviceID else { return }
        perform("復元先を取得") {
            let result = try await self.call(AppRequest(action: "catalog", device: deviceID))
            self.apps = result.apps ?? []
            self.pending = result.pending ?? []
        }
    }

    func recover() {
        guard let deviceID else { return }
        perform("未完了操作を復旧", showSheet: true) {
            let response = try await self.call(AppRequest(action: "recover", device: deviceID))
            self.pending = response.pending ?? []
            self.status = "未完了操作の復旧が完了しました"
        }
    }

    func exportFile(_ file: AppFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Macに保存") {
            var request = self.context("get", relative: file.id)
            request.local = url.path
            _ = try await self.call(request)
        }
    }

    func upload(overwrite: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("ファイルを送信") {
            var request = self.context("mutate", relative: self.join(url.lastPathComponent))
            request.operation = "upload"
            request.local = url.path
            request.overwrite = overwrite
            try await self.applyMutation(request)
        }
    }

    func mutate(operation: String, file: AppFile? = nil, name: String? = nil) {
        if let name, name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            error = "ファイル名が不正です。"
            return
        }
        perform("ファイルを変更") {
            var request = self.context("mutate", relative: file?.id ?? self.join(name ?? ""))
            request.operation = operation
            if let name { request.destination = self.join(name) }
            try await self.applyMutation(request)
        }
    }

    func openFile(_ file: AppFile) {
        if file.isDirectory { navigate(file.id); return }
        guard file.kind == "file", !busy else { return }
        perform("ファイルを開く") {
            self.closeEditor()
            let local = try self.workspace().appendingPathComponent(file.name)
            var request = self.context("get", relative: file.id)
            request.local = local.path
            let result = try await self.call(request)
            var document = AppEditorDocument(file: file, localURL: local, originalHash: result.hash)
            let ext = local.pathExtension.lowercased()
            document.mode = ext == "plist" ? "plist" : ["png", "jpg", "jpeg", "heic", "gif", "pdf"].contains(ext) ? "preview" : "text"
            self.editor = document
            do { try await self.readEditor() }
            catch {
                self.editor?.mode = "hex"
                try await self.readEditor()
            }
        }
    }

    func changeEditorMode(_ mode: String) {
        guard !busy, editor?.isDirty != true else { return }
        editor?.mode = mode
        editor?.offset = 0
        perform("内容を表示") { try await self.readEditor() }
    }

    func editorPage(_ delta: Int64) {
        guard let editor, !editor.isDirty, !busy else { return }
        self.editor?.offset = max(0, min(max(0, editor.size - 1) / 4096 * 4096, editor.offset + delta * 4096))
        perform("内容を表示") { try await self.readEditor() }
    }

    func saveEditor() {
        guard let document = editor, document.isDirty else { return }
        perform("編集内容を保存") {
            var write = AppRequest(action: "editor-write", local: document.localURL.path)
            write.encoding = document.encoding
            write.text = document.text
            write.offset = document.offset
            write.pageBytes = document.pageBytes
            _ = try await self.call(write)
            var request = self.context("mutate", relative: document.file.id)
            request.operation = "upload"
            request.local = document.localURL.path
            request.overwrite = true
            request.expectedHash = document.originalHash
            let result = try await self.applyMutation(request)
            var updated = document
            updated.originalHash = result.hash
            updated.savedText = document.text
            self.editor = updated
            try await self.readEditor()
        }
    }

    func closeEditor() {
        if let url = editor?.localURL.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
            workspaces.removeAll { $0 == url }
        }
        editor = nil
    }

    func cancel() {
        guard let cancellationURL else { return }
        do {
            try Data().write(to: cancellationURL)
            status = "中止しています。コンテナの復帰を待っています…"
            operation?.cancelling = true
            operation?.append(status)
        }
        catch { self.error = error.localizedDescription }
    }

    private func readEditor() async throws {
        guard let document = editor, document.mode != "preview" else { return }
        let result = try await call(AppRequest(action: "editor-read", local: document.localURL.path,
                                              mode: document.mode, offset: document.offset))
        editor?.text = result.text ?? ""
        editor?.savedText = result.text ?? ""
        editor?.encoding = result.encoding ?? "utf-8"
        editor?.size = result.size ?? 0
        editor?.pageBytes = result.pageBytes ?? 0
    }

    @discardableResult
    private func applyMutation(_ request: AppRequest) async throws -> AppResponse {
        let result = try await call(request)
        if let saved = result.backup {
            try await loadBackups()
            backupID = saved.id
        }
        try await loadFiles()
        return result
    }

    private func loadFiles() async throws {
        guard regionID != nil else { files = []; return }
        fileListingError = nil
        do {
            let result = try await call(context("list", relative: relativePath))
            files = result.entries ?? []
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
                   regionID: regionID, backupPath: libraryMode ? backup?.path : nil, relative: relative)
    }

    private func join(_ leaf: String) -> String { relativePath.isEmpty ? leaf : relativePath + "/" + leaf }

    private func resetFiles() {
        files = []; selection = []; relativePath = ""; regionID = nil; fileSearch = ""; iconURL = nil; fileListingError = nil
        closeEditor()
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airlift-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        workspaces.append(url)
        return url
    }

    private func call(_ request: AppRequest) async throws -> AppResponse {
        var request = request
        if request.action == "backup" || request.action == "restore" {
            request.verify = verificationEnabled
            operation?.append("内容検証: " + (verificationEnabled ? "有効" : "無効（スキップ）"))
        }
        request.cancelPath = cancellationURL?.path
        return try await AppService.call(request) { [weak self] response in
            await self?.updateProgress(response)
        }
    }

    private func updateProgress(_ response: AppResponse) {
        operation?.update(response)
        status = response.message ?? status
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
        if showSheet { self.operation = AppOperation(title: message, appName: appName ?? title) }
        cancellationURL = FileManager.default.temporaryDirectory.appendingPathComponent("airlift-cancel-\(UUID().uuidString)")
        Task {
            defer {
                busy = false
                fraction = nil
                if let cancellationURL { try? FileManager.default.removeItem(at: cancellationURL) }
                cancellationURL = nil
                if let next = nextActivation {
                    nextActivation = nil
                    activate(device: next.device, library: next.library)
                }
            }
            do {
                try await operation()
                if status == message || status.hasPrefix("コンテナ") || status.hasPrefix("取得:") || status.hasPrefix("照合:") {
                    status = "完了"
                }
                if showSheet { self.operation?.finish(self.status, failed: self.operation?.failed ?? false) }
            } catch {
                if showSheet { self.operation?.finish(error.localizedDescription, failed: true) }
                else { self.error = error.localizedDescription }
                status = "処理を完了できませんでした"
                if let deviceID,
                   let result = try? await AppService.call(AppRequest(action: "pending", device: deviceID)) {
                    pending = result.pending ?? []
                }
            }
        }
    }
}
