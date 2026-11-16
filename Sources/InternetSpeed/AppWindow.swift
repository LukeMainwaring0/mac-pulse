import AppKit
import SwiftUI

/// The full Mac Pulse window. While it is open, Mac Pulse becomes a regular
/// app with a Dock icon and menu bar; closing it returns Mac Pulse to the
/// menu bar alone.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    var onVisibilityChange: () -> Void = {}
    private(set) var isOpen = false

    private let model: MacPulsePopoverModel
    private var window: NSWindow?

    init(model: MacPulsePopoverModel) {
        self.model = model
        super.init()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        Self.installMainMenu()
        window.makeKeyAndOrderFront(nil)
        // macOS may decline to activate an app the user didn't click; keep
        // the window visible above others regardless.
        window.orderFrontRegardless()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !isOpen {
            isOpen = true
            onVisibilityChange()
        }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        onVisibilityChange()
        // Return to living in the menu bar once the window is gone.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MacPulseAppView(model: model))
        if #available(macOS 14.0, *) {
            hosting.sceneBridgingOptions = [.toolbars, .title]
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Mac Pulse"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 980, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1380, height: 900))
        if !window.setFrameUsingName("MacPulseCommandCenter") {
            window.center()
        }
        window.setFrameAutosaveName("MacPulseCommandCenter")
        return window
    }

    private static var menuInstalled = false

    /// A standard menu bar for while the app is in regular mode.
    private static func installMainMenu() {
        guard !menuInstalled else { return }
        menuInstalled = true
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Mac Pulse")
        appMenu.addItem(withTitle: "About Mac Pulse",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mac Pulse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mac Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
