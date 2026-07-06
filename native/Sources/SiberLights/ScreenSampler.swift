import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures a thin strip along the bottom edge of the middle row of displays
/// (the monitors the LED strip sits under) via ScreenCaptureKit and exposes
/// one smoothed RGB per LED. One SCStream per display: each stream captures
/// only its slice of the strip, downscaled, and writes into a shared buffer.
/// Runs only while the Screen Sync effect is active.
final class ScreenSampler: NSObject, SCStreamOutput, SCStreamDelegate {
    /// fraction of each screen's height sampled along the bottom edge
    private let stripFraction = 0.12
    /// per-frame exponential smoothing (higher = snappier, lower = calmer)
    private let alpha = 0.45
    /// saturation boost on the averaged color; averaging pulls toward gray
    private let saturation = 1.6
    /// screen pixels are sRGB-encoded but the LEDs are linear; without this
    /// the strip lifts every midtone and looks washed out
    private let gamma = 2.2
    /// drive each LED's strongest channel toward 255 so the strip runs at
    /// full brightness while keeping the hue: 0 = off, 1 = always full
    private let boost = 1.0
    /// cap on the boost gain so near-black stays black instead of dark
    /// noise flaring up to full brightness
    private let maxBoostGain = 4.0

    var reversed = false                  // flip if the strip runs right-to-left
    private(set) var noPermission = false // Screen Recording TCC not granted

    // shared with the sample-handler queue
    private let lock = NSLock()
    private var colors = [RGB](repeating: .black, count: LED_COUNT)
    private var smooth = [Double](repeating: 0, count: LED_COUNT * 3)
    private var slices: [ObjectIdentifier: Range<Int>] = [:]  // stream -> LED range

    // main-thread state
    private var streams: [SCStream] = []
    private var running = false
    private var restartPending = false
    private var didPrompt = false   // ask for the TCC grant at most once per launch
    private let sampleQueue = DispatchQueue(label: "com.siber.siberlights.screen")

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - lifecycle (main thread)
    func start() {
        guard !running else { return }
        running = true
        attemptSetup()
    }

    func stop() {
        guard running else { return }
        running = false
        teardown()
        lock.lock()
        colors = [RGB](repeating: .black, count: LED_COUNT)
        smooth = [Double](repeating: 0, count: LED_COUNT * 3)
        lock.unlock()
    }

    private func teardown() {
        for s in streams { s.stopCapture { _ in } }
        streams.removeAll()
        lock.lock(); slices.removeAll(); lock.unlock()
    }

    /// display add/remove/rearrange invalidates streams and LED mapping
    @objc private func displaysChanged() { scheduleRestart() }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.scheduleRestart() }
    }

    private func scheduleRestart() {
        guard running, !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.running else { return }
            self.teardown()
            self.attemptSetup()
        }
    }

    // MARK: - stream setup
    /// Gate every ScreenCaptureKit call behind a silent TCC preflight: an SCK
    /// content fetch without the grant re-triggers the system permission
    /// dialog each time, so prompt at most once per launch and otherwise just
    /// poll the permission state quietly until it's granted.
    private func attemptSetup() {
        guard running, streams.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            noPermission = true
            if !didPrompt {
                didPrompt = true
                CGRequestScreenCaptureAccess()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.attemptSetup()
            }
            return
        }
        noPermission = false
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            [weak self] content, _ in
            DispatchQueue.main.async { self?.configure(content) }
        }
    }

    private func configure(_ content: SCShareableContent?) {
        guard running, streams.isEmpty else { return }
        guard let content else {
            // fetch failed even though preflight passed — retry via the gate
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.attemptSetup()
            }
            return
        }

        let row = ScreenSampler.middleRow(content.displays)
        guard !row.isEmpty else { return }

        // split the LEDs across the row proportionally to each display's share
        // of the total span; bezel gaps are absorbed at the midpoints
        let minX = row.first!.frame.minX
        let span = row.last!.frame.maxX - minX
        var cuts: [CGFloat] = [minX]
        for i in 0..<(row.count - 1) {
            cuts.append((row[i].frame.maxX + row[i + 1].frame.minX) / 2)
        }
        cuts.append(minX + span)
        let bounds = cuts.map { Int((($0 - minX) / span * CGFloat(LED_COUNT)).rounded()) }

        for (i, display) in row.enumerated() {
            let range = bounds[i]..<bounds[i + 1]
            guard !range.isEmpty else { continue }
            let w = CGFloat(display.width), h = CGFloat(display.height)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: 0, y: h * (1 - stripFraction),
                                    width: w, height: h * stripFraction)
            cfg.width = max(64, range.count * 12)
            cfg.height = 12
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.queueDepth = 3
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            } catch { continue }
            lock.lock(); slices[ObjectIdentifier(stream)] = range; lock.unlock()
            streams.append(stream)
            stream.startCapture { _ in }  // failures surface via didStopWithError
        }
    }

    /// Displays grouped into horizontal rows by vertical overlap; returns the
    /// row with the most displays (ties: widest), sorted left to right.
    static func middleRow(_ displays: [SCDisplay]) -> [SCDisplay] {
        var rows: [[SCDisplay]] = []
        var rowMaxY = -CGFloat.greatestFiniteMagnitude
        for d in displays.sorted(by: { $0.frame.minY < $1.frame.minY }) {
            if !rows.isEmpty && d.frame.minY < rowMaxY {
                rows[rows.count - 1].append(d)
                rowMaxY = max(rowMaxY, d.frame.maxY)
            } else {
                rows.append([d])
                rowMaxY = d.frame.maxY
            }
        }
        let best = rows.max { a, b in
            (a.count, a.reduce(0) { $0 + $1.frame.width })
                < (b.count, b.reduce(0) { $0 + $1.frame.width })
        }
        return (best ?? []).sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: - frame handling (sample queue)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = atts.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock(); let slice = slices[ObjectIdentifier(stream)]; lock.unlock()
        guard let slice, !slice.isEmpty else { return }
        let n = slice.count

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { return }
        let px = base.assumingMemoryBound(to: UInt8.self)

        var avg = [Double](repeating: 0, count: n * 3)  // r,g,b per LED
        for led in 0..<n {
            let x0 = led * w / n
            let x1 = max(x0 + 1, (led + 1) * w / n)
            var r = 0.0, g = 0.0, b = 0.0
            for y in 0..<h {
                var p = px + y * rowBytes + x0 * 4
                for _ in x0..<x1 {  // BGRA
                    b += Double(p[0]); g += Double(p[1]); r += Double(p[2])
                    p += 4
                }
            }
            let cnt = Double((x1 - x0) * h)
            avg[led * 3] = r / cnt
            avg[led * 3 + 1] = g / cnt
            avg[led * 3 + 2] = b / cnt
        }

        lock.lock()
        for led in 0..<n {
            let gi = slice.lowerBound + led
            for c in 0..<3 {
                smooth[gi * 3 + c] += (avg[led * 3 + c] - smooth[gi * 3 + c]) * alpha
            }
            colors[gi] = corrected(r: smooth[gi * 3], g: smooth[gi * 3 + 1],
                                   b: smooth[gi * 3 + 2])
        }
        lock.unlock()
    }

    /// Re-saturate around luma (grays stay gray, mixed colors get their hue
    /// back), gamma-encode for the linear LEDs, then push the strongest
    /// channel toward 255 so the strip runs at full brightness.
    private func corrected(r: Double, g: Double, b: Double) -> RGB {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        func encode(_ v: Double) -> Double {
            let sat = max(0, min(255, luma + (v - luma) * saturation))
            return pow(sat / 255, gamma) * 255
        }
        var er = encode(r), eg = encode(g), eb = encode(b)
        let peak = max(er, eg, eb)
        if peak > 0 {
            let gain = 1 + (min(255 / peak, maxBoostGain) - 1) * boost
            er *= gain; eg *= gain; eb *= gain
        }
        return RGB(r: UInt8(min(255, er) + 0.5),
                   g: UInt8(min(255, eg) + 0.5),
                   b: UInt8(min(255, eb) + 0.5))
    }

    // MARK: - readout (render loop)
    func snapshot() -> [RGB] {
        lock.lock(); defer { lock.unlock() }
        return reversed ? colors.reversed() : colors
    }
}
