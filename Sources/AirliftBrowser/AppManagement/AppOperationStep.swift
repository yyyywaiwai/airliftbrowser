import Foundation

struct AppOperationStep: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    var state: String
    let completed: Int64
    let total: Int64?

    var fraction: Double {
        if state == "complete" || state == "skipped" { return 1 }
        guard let total, total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    var stateLabel: String {
        switch state {
        case "complete": String(localized: "完了")
        case "skipped": String(localized: "スキップ")
        case "running": String(localized: "実行中")
        case "failed": String(localized: "中断")
        default: String(localized: "待機中")
        }
    }
    var symbol: String {
        switch state {
        case "complete": "checkmark.circle.fill"
        case "skipped": "minus.circle"
        case "running": "arrow.triangle.2.circlepath"
        case "failed": "exclamationmark.circle"
        default: "circle"
        }
    }
}
