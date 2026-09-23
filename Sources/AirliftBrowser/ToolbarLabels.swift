import AppKit
import SwiftUI

/// Keep toolbar titles visible on macOS 14 as well as newer system toolbars.
struct ToolbarLabels: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarLabelView { ToolbarLabelView() }

    func updateNSView(_ nsView: ToolbarLabelView, context: Context) {
        nsView.configureToolbar()
    }
}

final class ToolbarLabelView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let toolbar = window?.toolbar {
            NotificationCenter.default.addObserver(self, selector: #selector(toolbarItemsChanged),
                                                   name: NSToolbar.willAddItemNotification, object: toolbar)
        }
        configureToolbar()
    }

    @objc private func toolbarItemsChanged(_ notification: Notification) {
        // SwiftUI finishes configuring newly inserted search items after the notification.
        Task { @MainActor [weak self] in self?.configureToolbar() }
    }

    func configureToolbar() {
        guard let toolbar = window?.toolbar else { return }
        toolbar.displayMode = .iconAndLabel
        for item in toolbar.items where item is NSSearchToolbarItem || containsSearchField(item.view) {
            item.label = ""
        }
    }

    private func containsSearchField(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is NSSearchField || view.subviews.contains { containsSearchField($0) }
    }
}
