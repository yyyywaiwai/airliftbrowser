import Foundation

struct AppEditorDocument: Identifiable {
    let id = UUID()
    let file: AppFile
    let localURL: URL
    var originalHash: String?
    var mode = "text"
    var encoding = "utf-8"
    var text = ""
    var savedText = ""
    var size: Int64 = 0
    var offset: Int64 = 0
    var pageBytes = 0
    var isDirty: Bool { text != savedText }
}
