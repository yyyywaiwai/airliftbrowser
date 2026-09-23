import AppKit
import Testing
@testable import AirliftBrowser

@MainActor
struct FinderDragMonitorTests {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    @Test func resolvesFileRowsBesideSidebar() {
        _ = NSApplication.shared
        let rows = Rows()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let window = NSWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = root
        let sidebar = makeTable(x: 0, rows: rows)
        let files = makeTable(x: 250, rows: rows)
        root.addSubview(sidebar)
        root.addSubview(files)
        let monitor = FinderDragMonitorView(frame: files.frame)
        monitor.entries = (0..<3).map {
            Entry(id: "\($0)", name: "file\($0)", kind: "S_IFREG", size: 0, subtitle: nil)
        }
        root.addSubview(monitor)
        window.layoutIfNeeded()

        // Both SwiftUI Lists and Tables are NSTableViews. The file table must
        // be found even when a sibling sidebar appears first in the hierarchy.
        for index in 0..<3 {
            let rect = files.rect(ofRow: index)
            let point = files.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            #expect(monitor.row(at: point) == index)
        }
        #expect(monitor.row(at: NSPoint(x: 600, y: 150)) == nil)
        files.isHidden = true
        #expect(monitor.row(at: files.convert(NSPoint(x: 20, y: 10), to: nil)) == nil)
    }

    private func makeTable(x: CGFloat, rows: Rows) -> NSTableView {
        let table = NSTableView(frame: NSRect(x: x, y: 0, width: 200, height: 300))
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.rowHeight = 24
        table.dataSource = rows
        table.reloadData()
        return table
    }
}
