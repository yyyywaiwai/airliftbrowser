import AppKit
import Observation

@MainActor @Observable
final class AppOperation: Identifiable {
    let id = UUID()
    let title: String
    let appName: String
    let started = Date.now
    var finished: Date?
    var message = "準備しています…"
    var phase = "prepare"
    var region: String?
    var regionIndex: Int?
    var regionCount: Int?
    var completed: Int64?
    var total: Int64?
    var chunkSize: Int64?
    var chunkIndex: Int64?
    var chunkCount: Int64?
    var bytesPerSecond: Double?
    var cancelling = false
    var failed = false
    var logs: [AppOperationLog] = []
    var steps: [AppOperationStep] = []

    var overallFraction: Double {
        guard !steps.isEmpty else { return running ? 0 : failed ? 0 : 1 }
        return steps.reduce(0) { $0 + $1.fraction } / Double(steps.count)
    }
    private(set) var logURL: URL?
    @ObservationIgnored private var logHandle: FileHandle?
    @ObservationIgnored private var lastSample: (key: String, bytes: Int64, date: Date)?
    @ObservationIgnored private var lastLogKey: String?
    @ObservationIgnored private var lastLogDate = Date.distantPast

    init(title: String, appName: String) {
        self.title = title
        self.appName = appName
        do {
            let folder = URL.applicationSupportDirectory.appending(path: "Airlift Browser/Logs", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(id.uuidString).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw AppServiceError("ログファイルを作成できません。")
            }
            logHandle = try FileHandle(forWritingTo: url)
            logURL = url
        } catch { append("ログの保存先を開けません: \(error.localizedDescription)") }
        append("\(title) — \(appName)")
    }

    var running: Bool { finished == nil }
    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    var stageName: String {
        switch phase {
        case "receive": "分割受信中"
        case "send": "分割送信中"
        case "verify-device": "端末データを照合中"
        case "verify-local": "バックアップを照合中"
        case "device-copy": "端末内でアプリ本体をコピー中"
        case "return": "コンテナを復帰中"
        case "cleanup": "一時データを片付け中"
        case "manifest": "バックアップの索引を保存中"
        case "scan": "ファイル一覧・容量を集計中"
        case "done": failed ? "処理を完了できませんでした" : "完了"
        default: steps.first(where: { $0.state == "running" })?.title ?? "準備中"
        }
    }

    func update(_ response: AppResponse) {
        guard running else { return }
        if let steps = response.steps { self.steps = steps }
        let now = Date.now
        message = response.message ?? message
        phase = response.phase ?? "prepare"
        region = response.region
        regionIndex = response.regionIndex
        regionCount = response.regionCount
        completed = response.completed
        total = response.total
        chunkSize = response.chunkSize
        chunkIndex = response.chunkIndex
        chunkCount = response.chunkCount
        let key = "\(phase):\(message)"
        if let completed {
            if let sample = lastSample, sample.key == key, completed >= sample.bytes {
                let seconds = now.timeIntervalSince(sample.date)
                if seconds > 0 { bytesPerSecond = Double(completed - sample.bytes) / seconds }
            } else { bytesPerSecond = nil }
            lastSample = (key, completed, now)
        } else { bytesPerSecond = nil; lastSample = nil }
        // Keep all stage/file changes, with one progress line per second.
        // The visible tail is bounded; the complete operation log stays on disk.
        if key != lastLogKey || now.timeIntervalSince(lastLogDate) >= 1 || completed == total && total != nil {
            var line = message
            if let completed, let total { line += " [\(Self.bytes(completed)) / \(Self.bytes(total))]" }
            append(line)
            lastLogKey = key
            lastLogDate = now
        }
    }

    func append(_ message: String) {
        let entry = AppOperationLog(message: message)
        logs.append(entry)
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        let line = "\(entry.date.formatted(.iso8601)) \(message)\n"
        if let data = line.data(using: .utf8), let handle = logHandle {
            do { try handle.write(contentsOf: data) }
            catch {
                try? handle.close()
                logHandle = nil
                logs.append(AppOperationLog(message: "ログへの書き込み失敗: \(error.localizedDescription)"))
            }
        }
    }

    func finish(_ message: String, failed: Bool = false) {
        self.message = message
        self.failed = failed
        if failed {
            for index in steps.indices where steps[index].state == "running" {
                steps[index].state = "failed"
            }
        }
        finished = .now
        phase = "done"
        bytesPerSecond = nil
        append(message)
        try? logHandle?.synchronize()
        try? logHandle?.close()
        logHandle = nil
    }

    func revealLog() {
        if let logURL { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
