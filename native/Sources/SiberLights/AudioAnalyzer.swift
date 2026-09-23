import Accelerate
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Taps the system audio *output* via ScreenCaptureKit — no microphone — and
/// exposes smoothed 24-band energies, an overall level, and a beat flag, the
/// Swift/vDSP port of the Python NumPy analyzer. The tap runs only while a
/// music effect is active and shares the Screen Recording permission that the
/// Screen Sync effect already uses, so no extra TCC grant is needed.
final class AudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let nBands = 24
    private let blockSize = 2048
    private let log2n = vDSP_Length(11)   // 2048 = 2^11
    private let sampleRate = 48000.0

    private(set) var noPermission = false // Screen Recording TCC not granted

    // main-thread state
    private var stream: SCStream?
    private var running = false
    private var restartPending = false
    private var didPrompt = false   // ask for the TCC grant at most once per launch
    private let sampleQueue = DispatchQueue(label: "com.siber.siberlights.audiotap")

    // outputs (read under lock by the render loop)
    private let lock = NSLock()
    private var bands = [Double](repeating: 0, count: nBands)
    private var level = 0.0
    private var beat = false
    var gain = 1.0   // sensitivity multiplier

    // silence detection (nothing playing, or the tap quietly broken)
    private var startedAt = Date()
    private var lastSignal = Date()

    // FFT scratch + AGC + beat history (sample queue only)
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var accum = [Float]()
    private var bandBins: [(Int, Int)] = []   // [lo, hi) bin index per band
    private var peak = 1e-6
    private var bassHist = [Double]()

    override init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: blockSize)
        vDSP_hann_window(&window, vDSP_Length(blockSize), Int32(vDSP_HANN_DENORM))
        // band edges: 50 Hz .. 8 kHz, log-spaced (rate is fixed by the stream
        // config, so the bins can be computed once)
        let edges = (0...AudioAnalyzer.nBands).map { i -> Double in
            50.0 * pow(8000.0 / 50.0, Double(i) / Double(AudioAnalyzer.nBands))
        }
        let block = blockSize
        let binHz = sampleRate / Double(block)
        bandBins = (0..<AudioAnalyzer.nBands).map { b in
            let lo = Int((edges[b] / binHz).rounded(.down))
            let hi = max(lo + 1, Int((edges[b + 1] / binHz).rounded(.down)))
            return (min(lo, block / 2 - 1), min(hi, block / 2))
        }
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - lifecycle (main thread)
    func start() {
        guard !running else { return }
        running = true
        startedAt = Date(); lastSignal = Date()
        sampleQueue.async { [weak self] in self?.accum.removeAll(keepingCapacity: true) }
        attemptSetup()
    }

    func stop() {
        guard running else { return }
        running = false
        teardown()
        lock.lock()
        bands = [Double](repeating: 0, count: AudioAnalyzer.nBands)
        level = 0; beat = false
        lock.unlock()
    }

    private func teardown() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    /// the tap is anchored to a display filter, so a display change can
    /// invalidate the stream without an error callback
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
    /// Same TCC gate as ScreenSampler: system-audio capture sits behind the
    /// Screen Recording grant, and an SCK content fetch without it re-triggers
    /// the system dialog every time — so preflight silently, prompt at most
    /// once per launch, and poll quietly until granted.
    private func attemptSetup() {
        guard running, stream == nil else { return }
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
        guard running, stream == nil else { return }
        guard let content, let display = content.displays.first else {
            // fetch failed even though preflight passed — retry via the gate
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.attemptSetup()
            }
            return
        }

        // audio-only stream: SCK insists on a display filter, so keep the
        // video side as small and slow as it allows and never attach a
        // .screen output for it
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(sampleRate)
        cfg.channelCount = 1
        cfg.width = 64
        cfg.height = 64
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch { return }
        stream = s
        startedAt = Date(); lastSignal = Date()
        s.startCapture { _ in }  // failures surface via didStopWithError
    }

    // MARK: - analysis (sample queue)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let buf = abl.first, let data = buf.mData else { return }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            accum.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
        while accum.count >= blockSize {
            var block = Array(accum[0..<blockSize])
            accum.removeFirst(blockSize)
            analyze(&block)
        }
    }

    private func analyze(_ samples: inout [Float]) {
        let half = blockSize / 2

        var windowed = [Float](repeating: 0, count: blockSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(blockSize))

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cptr in
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        var raw = [Double](repeating: 0, count: AudioAnalyzer.nBands)
        var rawMax = 0.0
        for (b, (lo, hi)) in bandBins.enumerated() {
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            let v = Double(sum) / Double(max(1, hi - lo))
            raw[b] = v
            rawMax = max(rawMax, v)
        }
        if rawMax > 1e-3 { lastSignal = Date() }

        peak = max(rawMax, peak * 0.995, 1e-6)
        let norm = raw.map { min(1.0, max(0.0, $0 / peak * gain)) }
        let bass = (norm[0] + norm[1] + norm[2] + norm[3]) / 4
        bassHist.append(bass)
        if bassHist.count > 22 { bassHist.removeFirst() }
        let avg = bassHist.reduce(0, +) / Double(bassHist.count)
        let meanNorm = norm.reduce(0, +) / Double(norm.count)

        lock.lock()
        for i in 0..<AudioAnalyzer.nBands { bands[i] = max(norm[i], bands[i] * 0.72) }
        level = max(meanNorm * 1.8, level * 0.85)
        beat = bass > max(0.12, avg * 1.45)
        lock.unlock()
    }

    // MARK: - readout
    func snapshot() -> (bands: [Double], level: Double, beat: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (bands, min(1.0, level), beat)
    }

    func isSilent() -> Bool {
        running
            && Date().timeIntervalSince(startedAt) > 3
            && Date().timeIntervalSince(lastSignal) > 3
    }
}
