import AppKit
import SwiftUI

// Classic AppKit menu bar app: an NSStatusItem plus an NSPopover that hosts
// the SwiftUI panel. This replaces SwiftUI's MenuBarExtra, which on macOS 26
// spontaneously re-activates the app every few seconds and steals key focus
// from the frontmost window. The popover still renders native SwiftUI
// controls (sliders, color picker) correctly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = SerialController()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lightbulb.fill",
                                   accessibilityDescription: "siberLights")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        popover.behavior = .transient
        popover.animates = false
        let hosting = NSHostingController(
            rootView: ContentView().environmentObject(controller))
        // keep the popover sized to the SwiftUI content — without this the
        // popover keeps a stale height when conditional rows appear (e.g. the
        // notification scene row) and the top of the panel gets clipped
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // activate only here, on an explicit user click, so the popover
            // can take keyboard focus — never on a timer
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
