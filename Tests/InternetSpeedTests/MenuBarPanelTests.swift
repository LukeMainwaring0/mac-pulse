import AppKit
import SwiftUI
import XCTest
@testable import InternetSpeed

@MainActor
final class MenuBarPanelTests: XCTestCase {
    private func withAnchor(_ body: (NSButton) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 400, y: 700, width: 100, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = NSButton(title: "Test", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        window.contentView?.addSubview(button)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        body(button)
    }

    func testNativeMenuTracksAndPublishesVisibility() {
        withAnchor { button in
            let panel = MenuBarPanel(rootView: Text("Menu test").frame(width: 200, height: 100))
            var opened = 0
            var closed = 0
            panel.onShow = { opened += 1; XCTAssertTrue(panel.isShown) }
            panel.onClose = { closed += 1; XCTAssertFalse(panel.isShown) }
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    XCTAssertTrue(panel.isShown)
                    XCTAssertNotNil(panel.menu.items.first?.view?.window)
                    panel.close()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            defer { timer.invalidate() }
            panel.show(below: button)
            XCTAssertFalse(panel.isShown)
            XCTAssertEqual(opened, 1)
            XCTAssertEqual(closed, 1)
        }
    }

    func testSnapshotIsSizedBeforeMenuTracking() {
        withAnchor { button in
            let model = MenuSizingModel()
            let panel = MenuBarPanel(rootView: MenuSizingView(model: model))
            panel.onPrepare = { model.expanded = true }
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    XCTAssertEqual(panel.menu.items.first?.view?.frame.height, 220)
                    panel.close()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            panel.show(below: button)
            timer.invalidate()
        }
    }

    func testNativeMenuCanReopenWithoutStaleState() {
        withAnchor { button in
            let panel = MenuBarPanel(rootView: Text("Menu test").frame(width: 200, height: 100))
            for _ in 0..<3 {
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    MainActor.assumeIsolated { panel.close() }
                }
                RunLoop.main.add(timer, forMode: .eventTracking)
                panel.show(below: button)
                timer.invalidate()
                XCTAssertFalse(panel.isShown)
                XCTAssertNil(panel.menu.items.first?.view?.window)
            }
        }
    }

    /// A password prompt opened from the menu must wait until the menu has
    /// stopped tracking, or the menu keeps every keystroke.
    func testWorkRequestedFromOpenMenuRunsAfterMenuCloses() {
        withAnchor { button in
            let panel = MenuBarPanel(rootView: Text("Menu test").frame(width: 200, height: 100))
            var ranWhileShown: Bool?
            let ran = expectation(description: "work ran")
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                MainActor.assumeIsolated {
                    XCTAssertTrue(panel.isShown)
                    panel.closeThen {
                        ranWhileShown = panel.isShown
                        ran.fulfill()
                    }
                    XCTAssertNil(ranWhileShown, "work must not run inside menu tracking")
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            panel.show(below: button)
            wait(for: [ran], timeout: 2)
            XCTAssertEqual(ranWhileShown, false)
        }
    }
}


private final class MenuSizingModel: ObservableObject {
    @Published var expanded = false
}

private struct MenuSizingView: View {
    @ObservedObject var model: MenuSizingModel
    var body: some View {
        Text("Menu content").frame(width: 200, height: model.expanded ? 220 : 100)
    }
}
