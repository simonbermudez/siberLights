import Accelerate
import AVFoundation
import Foundation

/// Captures the default audio input and exposes smoothed 24-band energies,
/// an overall level, and a beat flag — the Swift/vDSP port of the Python
/// NumPy analyzer. The engine runs only while a music effect is active.
final class AudioAnalyzer {
    static let nBands = 24
    private let blockSize = 2048
    private let log2n = vDSP_Length(11)   // 2048 = 2^11

    private let engine = AVAudioEngine()
    private var running = false

    // outputs (read under lock by the render loop)
    private let lock = NSLock()
    private var bands = [Double](repeating: 0, count: nBands)
    private var level = 0.0
    private var beat = false
    var gain = 1.0   // sensitivity multiplier

    // silence detection (TCC-denied mic delivers zeros, not an error)
    private var startedAt = Date()
    private var lastSignal = Date()

    // AGC + beat history
    private var peak = 1e-6
    private var bassHist = [Double]()

    // FFT scratch
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var accum = [Float]()
    private var bandBins: [(Int, Int)] = []   // [lo, hi) bin index per band
    private var currentRate = 44100.0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: blockSize)
        vDSP_hann_window(&window, vDSP_Length(blockSize), Int32(vDSP_HANN_DENORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    private func computeBands(rate: Double) {
        let edges = (0...AudioAnalyzer.nBands).map { i -> Double in
            50.0 * pow(8000.0 / 50.0, Double(i) / Double(AudioAnalyzer.nBands))
        }
        let binHz = rate / Double(blockSize)
        bandBins = (0..<AudioAnalyzer.nBands).map { b in
            let lo = Int((edges[b] / binHz).rounded(.down))
            let hi = max(lo + 1, Int((edges[b + 1] / binHz).rounded(.down)))
            return (min(lo, blockSize / 2 - 1), min(hi, blockSize / 2))
        }
        currentRate = rate
    }

    // MARK: - lifecycle
    func start() {
        guard !running else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        computeBands(rate: fmt.sampleRate > 0 ? fmt.sampleRate : 44100)
        accum.removeAll(keepingCapacity: true)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: UInt32(blockSize), format: fmt) { [weak self] buf, _ in
            self?.process(buf)
        }
        do {
            try engine.start()
            running = true
            startedAt = Date(); lastSignal = Date()
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        lock.lock()
        bands = [Double](repeating: 0, count: AudioAnalyzer.nBands)
        level = 0; beat = false
        lock.unlock()
    }

    // MARK: - analysis (runs on the realtime audio thread)
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        accum.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: count))
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
