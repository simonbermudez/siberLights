import AppKit
import ApplicationServices

/// Fires a callback whenever a notification banner appears, by observing
/// AXWindowCreated on the Notification Center UI process via the
/// Accessibility API. Needs the Accessibility TCC grant; `noPermission`
/// mirrors that state so the UI can surface it.
final class NotificationWatcher {

    var onNotification: (() -> Void)?
    private(set) var noPermission = false

    private var observer: AXObserver?
    private var pid: pid_t = -1
    private var active = false

    /// Begin watching. Prompts for the Accessibility grant on first use.
    func start() {
        active = true
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        refresh()
    }

    func stop() {
        active = false
        detach()
        noPermission = false
    }

    /// Re-attach when the grant arrives late or Notification Center restarts
    /// (its pid changes). Cheap when nothing changed — call it from a poll.
    func refresh() {
        guard active else { return }
        noPermission = !AXIsProcessTrusted()
        if noPermission { detach(); return }
        let current = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.notificationcenterui")
            .first?.processIdentifier ?? -1
        if current == pid, observer != nil { return }
        detach()
        guard current >= 0 else { return }

        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<NotificationWatcher>.fromOpaque(refcon)
                .takeUnretainedValue().onNotification?()
        }
        guard AXObserverCreate(current, cb, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, AXUIElementCreateApplication(current),
                                        kAXWindowCreatedNotification as CFString,
                                        refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        pid = current
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        pid = -1
    }
}
