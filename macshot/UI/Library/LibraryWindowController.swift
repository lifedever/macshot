import AppKit
import SwiftUI

/// The library window. One at a time; it brings the app forward while open
/// and hands focus back through `returnFocusIfNeeded()` when it closes, like
/// the editors.
@MainActor
final class LibraryWindowController: NSWindowController, NSWindowDelegate {

    private static var current: LibraryWindowController?
    private let model = LibraryModel()

    static func show() {
        if let current, let window = current.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = LibraryWindowController()
        current = controller
        NSApp.setActivationPolicy(.regular)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L("Library")
        window.minSize = NSSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)

        let hosting = NSHostingController(rootView: LibraryView(model: model))
        if #available(macOS 14.0, *) {
            // The SwiftUI toolbar and title become the window's own.
            hosting.sceneBridgingOptions = [.toolbars, .title]
        }
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("macshot.library")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
