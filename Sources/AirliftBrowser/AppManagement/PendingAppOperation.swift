import Foundation

struct PendingAppOperation: Decodable, Identifiable, Sendable {
    let id: String
    let device: String
    let target: String
    let phase: String
}
