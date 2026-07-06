import Darwin
import Foundation
import SwiftUI

let LED_COUNT = 65

/// Owns the serial port and a 30fps render loop that streams effect frames.
/// UI-facing control values are @Published; the render loop reads a
/// lock-protected snapshot so it never races with SwiftUI on the main thread.
final class SerialController: ObservableObject {

    @Published var isConnected = false
    @Published var portName: String = ""
    @Published var micSilent = false          // music effect active but no audio
    @Published var userDisconnected = false   // manual disconnect suppresses auto-reconnect

    // control values (bound to the UI, persisted to UserDefaults)
    @Published var effect: String { didSet { sync(); save() } }
    @Published var color: RGB { didSet { sync(); save() } }
    @Published var brightness: Double { didSet { sync(); save() } }   // 1...100
    @Published var speed: Double { didSet { sync(); save() } }        // 1...100
    @Published var sensitivity: Double { didSet { sync(); save() } }  // 1...100
    @Published var followScreen: Bool { didSet { applyScreenState(); save() } }  // blank while display asleep

    private let audio = AudioAnalyzer()

    private struct Snapshot {
        var effect = "Solid"
        var color = RGB(r: 255, g: 96, b: 0)
        var brightness = 1.0
        var speed = 1.0
        var blank = false   // display asleep + followScreen: hold the strip dark
    }
    private var snap = Snapshot()
    private let lock = NSLock()
    private var screenAsleep = false          // driven by NSWorkspace notifications
    private var screenObservers: [NSObjectProtocol] = []

    private let queue = DispatchQueue(label: "com.siber.siberlights.serial")
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?
    private let engine = EffectEngine()
    private var startTime = Date()

    private let defaults = UserDefaults.standard
    private var pollTimer: DispatchSourceTimer?
    private var noDeviceTicks = 0

    init() {
        effect = defaults.string(forKey: "effect") ?? "Solid"
        if let c = defaults.array(forKey: "color") as? [Int], c.count == 3 {
            color = RGB(r: UInt8(c[0]), g: UInt8(c[1]), b: UInt8(c[2]))
        } else {
            color = RGB(r: 255, g: 96, b: 0)
        }
        brightness = defaults.object(forKey: "brightness") as? Double ?? 100
        speed = defaults.object(forKey: "speed") as? Double ?? 50
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? 50
        followScreen = defaults.object(forKey: "followScreen") as? Bool ?? false
        sync()
        connect()
        startPolling()
        registerScreenObservers()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        screenObservers.forEach { nc.removeObserver($0) }
    }

    // MARK: - display sleep/wake
    /// When `followScreen` is on, mirror the display: blank the strip while the
    /// monitor sleeps and restore the effect on wake. The serial connection and
    /// render loop stay alive throughout — we just hold dark frames.
    private func registerScreenObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        screenObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screenAsleep = true; self?.applyScreenState() })
        screenObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screenAsleep = false; self?.applyScreenState() })
    }

    private func applyScreenState() {
        lock.lock(); snap.blank = followScreen && screenAsleep; lock.unlock()
    }

    /// Matches the Python app's lifecycle: auto-reconnect when the strip
    /// reappears, and auto-quit ~6s after it's unplugged (the LaunchAgent
    /// relaunches us on the next USB attach). Also refreshes the mic-silent
    /// indicator.
    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.poll() }
        pollTimer = t
        t.resume()
    }

    private func poll() {
        // only republish on real change — a periodic @Published write would
        // needlessly invalidate observers every 2s
        let silent = MUSIC_EFFECTS.contains(effect) && audio.isSilent()
        if silent != micSilent { micSilent = silent }
        if SerialController.findPort() != nil {
            noDeviceTicks = 0
            if !isConnected && !userDisconnected { connect() }
        } else {
            noDeviceTicks += 1
            if noDeviceTicks >= 3 {   // ~6s grace, survives brief replug blips
                shutdown()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - persistence
    private func save() {
        defaults.set(effect, forKey: "effect")
        defaults.set([Int(color.r), Int(color.g), Int(color.b)], forKey: "color")
        defaults.set(brightness, forKey: "brightness")
        defaults.set(speed, forKey: "speed")
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(followScreen, forKey: "followScreen")
    }

    /// copy control values into the lock-protected snapshot for the render loop
    private func sync() {
        lock.lock()
        snap = Snapshot(effect: effect, color: color,
                        brightness: brightness / 100.0,
                        speed: speed / 12.5,   // 1...100 -> 0.08...8
                        blank: followScreen && screenAsleep)
        lock.unlock()
        audio.gain = sensitivity / 50.0
        updateAudio()
    }

    /// open the mic only while a music effect is selected (privacy).
    private func updateAudio() {
        if MUSIC_EFFECTS.contains(effect) { audio.start() } else { audio.stop() }
    }

    // MARK: - port discovery
    static func findPort() -> String? {
        let dev = "/dev"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dev) else { return nil }
        let matches = items.filter {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial")
        }.sorted()
        return matches.first.map { "\(dev)/\($0)" }
    }

    // MARK: - connection
    func connect() {
        queue.async { [weak self] in
            guard let self, self.fd < 0 else { return }
            guard let path = SerialController.findPort() else {
                DispatchQueue.main.async { self.isConnected = false; self.portName = "" }
                return
            }
            let handle = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard handle >= 0 else {
                DispatchQueue.main.async { self.isConnected = false }
                return
            }
            _ = fcntl(handle, F_SETFL, 0)
            var tio = termios()
            if tcgetattr(handle, &tio) != 0 { close(handle); return }
            cfmakeraw(&tio)
            cfsetispeed(&tio, speed_t(B115200))
            cfsetospeed(&tio, speed_t(B115200))
            tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
            tio.c_cflag &= ~tcflag_t(PARENB | CSTOPB)
            tio.c_cflag = (tio.c_cflag & ~tcflag_t(CSIZE)) | tcflag_t(CS8)
            if tcsetattr(handle, TCSANOW, &tio) != 0 { close(handle); return }

            self.fd = handle
            self.startTime = Date()
            DispatchQueue.main.async {
                self.isConnected = true
                self.portName = (path as NSString).lastPathComponent
            }
            self.startLoop()
        }
    }

    func disconnect(blank: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel(); self.timer = nil
            if self.fd >= 0 {
                if blank {
                    let off = [UInt8]([0x41, 0x64, 0x61, 0, 0, UInt8(LED_COUNT)]
                                      + [UInt8](repeating: 0, count: 3 * LED_COUNT))
                    self.writeAll(off)
                }
                close(self.fd)
                self.fd = -1
            }
            DispatchQueue.main.async { self.isConnected = false }
        }
    }

    /// stop everything for app termination
    func shutdown() {
        audio.stop()
        disconnect()
    }

    // MARK: - render loop
    private func startLoop() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard fd >= 0 else { return }
        lock.lock(); let s = snap; lock.unlock()
        if s.blank {
            let off = [UInt8]([0x41, 0x64, 0x61, 0, 0, UInt8(LED_COUNT)]
                              + [UInt8](repeating: 0, count: 3 * LED_COUNT))
            writeAll(off)
            return
        }
        let elapsed = Date().timeIntervalSince(startTime)
        let px: [RGB]
        if MUSIC_EFFECTS.contains(s.effect) {
            let (bands, level, beat) = audio.snapshot()
            px = engine.renderMusic(effect: s.effect, n: LED_COUNT, t: elapsed, color: s.color,
                                    speed: s.speed, bands: bands, level: level, beat: beat)
        } else {
            px = engine.render(effect: s.effect, n: LED_COUNT, t: elapsed,
                               color: s.color, speed: s.speed)
        }
        var frame = [UInt8]([0x41, 0x64, 0x61, 0, 0, UInt8(LED_COUNT)])
        frame.reserveCapacity(6 + 3 * LED_COUNT)
        let bri = s.brightness
        for p in px {
            frame.append(UInt8(Double(p.r) * bri))
            frame.append(UInt8(Double(p.g) * bri))
            frame.append(UInt8(Double(p.b) * bri))
        }
        writeAll(frame)
    }

    private func writeAll(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 {
                    // port vanished (unplug): drop connection
                    close(fd); fd = -1
                    timer?.cancel(); timer = nil
                    DispatchQueue.main.async { self.isConnected = false }
                    return
                }
                off += n
            }
        }
    }

    // color bridge for SwiftUI ColorPicker
    var swiftUIColor: Color {
        get { Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255) }
        set {
            let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
            color = RGB(r: UInt8(max(0, min(255, ns.redComponent * 255))),
                        g: UInt8(max(0, min(255, ns.greenComponent * 255))),
                        b: UInt8(max(0, min(255, ns.blueComponent * 255))))
        }
    }
}
