import Foundation

struct AppOperationLog: Identifiable {
    let id = UUID()
    let date = Date.now
    let message: String
}
