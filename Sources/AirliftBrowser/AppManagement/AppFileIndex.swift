import Foundation

/// A complete metadata snapshot. Empty directories are distinct from missing paths.
struct AppFileIndex {
    struct Key: Hashable {
        let device: String
        let app: String
        let region: String
        let containerPath: String?
    }

    private var children: [String: [AppFile]] = ["": []]
    let sourceIdentity: String?

    init(_ files: [AppFile], sourceIdentity: String? = nil) {
        self.sourceIdentity = sourceIdentity
        for file in files {
            let parent = file.id.split(separator: "/").dropLast().joined(separator: "/")
            children[parent, default: []].append(file)
            if file.isDirectory, children[file.id] == nil { children[file.id] = [] }
        }
    }

    func entries(at path: String) -> [AppFile]? { children[path] }
}
