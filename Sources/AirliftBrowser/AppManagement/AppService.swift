import Foundation

enum AppService {
    static func call(
        _ request: AppRequest,
        progress: @escaping @Sendable (AppResponse) async -> Void = { _ in }
    ) async throws -> AppResponse {
        let input = try JSONEncoder().encode(request)
        let helper = Bundle.main.resourceURL?.appendingPathComponent("AppManagement/manager.py")
        return try await Task.detached(priority: .userInitiated) {
            guard let helper else { throw AppServiceError("アプリ管理ヘルパーが見つかりません。") }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("airlift-command-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let requestURL = work.appendingPathComponent("request.json")
            try input.write(to: requestURL, options: .atomic)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-B", helper.path, "--request", requestURL.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            let logURL = work.appendingPathComponent("stderr.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            process.standardError = log
            try process.run()
            var buffer = Data()
            var result: AppResponse?
            let decoder = JSONDecoder()
            while true {
                // Deliver each flushed progress event without waiting for a
                // fixed-size buffer to fill (especially during preparation).
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let response = try? decoder.decode(AppResponse.self, from: line) {
                        if response.event == "progress" { await progress(response) }
                        if response.event == "result" { result = response }
                    }
                }
            }
            process.waitUntilExit()
            guard let result else {
                let detail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw AppServiceError("アプリ管理処理が中断されました（\(process.terminationStatus)）。\n\(detail.suffix(2000))")
            }
            guard result.ok == true, process.terminationStatus == 0 else {
                throw AppServiceError(result.error ?? "アプリ管理処理に失敗しました。")
            }
            return result
        }.value
    }
}
