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
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(controller))
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
