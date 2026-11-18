import AppKit
import SwiftUI

/// A real status-item menu. AppKit owns the material, corners, positioning,
/// tracking, dismissal and transitions between adjacent menu-bar items.
@MainActor
final class MenuBarPanel: NSObject, NSMenuDelegate {
    nonisolated static let cornerRadius: CGFloat = 24
    let menu = NSMenu(title: "Mac Pulse")
    var onPrepare: () -> Void = {}
    var onShow: () -> Void = {}
    var onClose: () -> Void = {}
    private(set) var isShown = false
    private var afterClose: [() -> Void] = []
    private var hostingView: NSHostingView<AnyView>
    private let content: AnyView

    init<Content: View>(rootView: Content) {
        content = AnyView(rootView)
        hostingView = NSHostingView(rootView: AnyView(rootView))
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        let content = NSMenuItem(title: "Mac Pulse", action: nil, keyEquivalent: "")
        content.view = hostingView
        menu.addItem(content)
        fitToContent()
    }

    // Used by the visual QA entry point. Normal clicks are handled entirely
    // by NSStatusItem.menu, with no competing button action or event monitor.
    func toggle(below button: NSButton) {
        if isShown { close() } else { show(below: button) }
    }

    func show(below button: NSButton) {
        guard !isShown, button.window != nil else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    func close() {
        menu.cancelTracking()
    }

    /// Closes the menu, then runs the work once AppKit has fully left menu
    /// tracking. A menu that is still tracking takes every keystroke, so
    /// anything that needs typing (like a password prompt) must wait.
    func closeThen(_ work: @escaping () -> Void) {
        guard isShown else {
            DispatchQueue.main.async(execute: work)
            return
        }
        afterClose.append(work)
        close()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        onPrepare()
        // Start from the prepared snapshot, not a previously laid-out placeholder.
        // Reusing that tree animates its old geometry into the new menu frame.
        hostingView = NSHostingView(rootView: content)
        fitToContent()
        menu.items.first?.view = hostingView
    }

    func menuWillOpen(_ menu: NSMenu) {
        isShown = true
        onShow()
    }

    func menuDidClose(_ menu: NSMenu) {
        isShown = false
        onClose()
        let pending = afterClose
        afterClose = []
        // menuDidClose arrives inside the tracking loop; run after it returns.
        for work in pending { DispatchQueue.main.async(execute: work) }
    }

    private func fitToContent() {
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        hostingView.setFrameSize(size)
    }
}
