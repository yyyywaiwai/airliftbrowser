import SwiftUI

struct AppFinderDragMonitor: NSViewRepresentable {
    let manager: AppManager
    let files: [AppFile]

    func makeNSView(context: Context) -> FinderDragMonitorView {
        FinderDragMonitorView()
    }

    func updateNSView(_ view: FinderDragMonitorView, context: Context) {
        view.appManager = manager
        view.entries = files.map {
            Entry(id: $0.id, name: $0.name, kind: $0.isDirectory ? "S_IFDIR" : "S_IFREG",
                  size: $0.size, subtitle: nil)
        }
    }
}
