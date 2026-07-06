import Foundation

struct RGB {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    static let black = RGB(r: 0, g: 0, b: 0)
}

let STATIC_EFFECTS = [
    "Solid", "Rainbow", "Breathe", "Color Wipe",
    "Theater Chase", "Comet", "Scanner", "Sparkle",
    "Confetti", "Fire", "Aurora", "Wave",
    "Strobe", "Police", "Candle", "Off",
]

let MUSIC_EFFECTS = [
    "Spectrum", "Pulse", "VU Meter", "Center Burst",
    "Rainbow Beat", "Beat Flash", "Ripples", "Bass & Treble",
    "Mirror Spectrum", "Dual VU", "Color Organ", "Fireworks",
    "Energy Comet", "Bass Pump", "Flow", "Meter Peak",
]

/// hue/sat/value in 0...1 -> RGB bytes
func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    let i = Int(floor(h * 6))
    let f = h * 6 - Double(i)
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)
    let (r, g, b): (Double, Double, Double)
    switch ((i % 6) + 6) % 6 {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return RGB(r: UInt8(max(0, min(255, r * 255))),
               g: UInt8(max(0, min(255, g * 255))),
               b: UInt8(max(0, min(255, b * 255))))
}

private func byte(_ x: Double) -> UInt8 { UInt8(max(0, min(255, x))) }

/// Renders effect frames. Holds per-effect scratch state (fire heat, sparkle
/// levels, etc.), so one instance is owned by the render loop.
final class EffectEngine {
    private var fire: [Double] = []
    private var sparkle: [Double] = []
    private var confetti: [RGB] = []
    private var candleK = 0.8
    // music-effect state
    private var rbeatPhase = 0.0
    private var rbeatPrev = false
    private var bflashV = 0.0
    private var ripples: [Double] = []
    private var ripplePrev = false
    private var btSparkle: [Double] = []
    private var fireworks: [(pos: Double, radius: Double, hue: Double)] = []
    private var fireworksPrev = false
    private var flowPhase = 0.0
    private var meterPeak = 0.0

    private func sized(_ arr: inout [Double], _ n: Int) {
        if arr.count != n { arr = [Double](repeating: 0, count: n) }
    }

    func render(effect: String, n: Int, t: Double, color: RGB, speed spd: Double) -> [RGB] {
        let r = Double(color.r), g = Double(color.g), b = Double(color.b)

        switch effect {
        case "Off":
            return [RGB](repeating: .black, count: n)

        case "Solid":
            return [RGB](repeating: color, count: n)

        case "Rainbow":
            return (0..<n).map { i in
                hsv((t * 0.1 * spd + Double(i) / Double(n)).truncatingRemainder(dividingBy: 1.0), 1, 1)
            }

        case "Breathe":
            var k = 0.5 - 0.5 * cos(t * 2 * .pi * 0.25 * spd)
            k = 0.05 + 0.95 * k
            return [RGB](repeating: RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k)), count: n)

        case "Color Wipe":
            let pos = (t * Double(n) * 0.5 * spd).truncatingRemainder(dividingBy: Double(2 * n))
            let filled = pos < Double(n) ? Int(pos) : n - Int(pos - Double(n)) - 1
            return (0..<n).map { $0 < filled ? color : .black }

        case "Theater Chase":
            let off = Int(t * 10 * spd) % 3
            return (0..<n).map { ($0 + off) % 3 == 0 ? color : .black }

        case "Comet":
            let head = (t * Double(n) * 0.6 * spd).truncatingRemainder(dividingBy: Double(n))
            return (0..<n).map { i in
                let d = (head - Double(i)).truncatingRemainder(dividingBy: Double(n))
                let dd = d < 0 ? d + Double(n) : d
                var k = max(0.0, 1.0 - dd / (Double(n) * 0.35))
                k = k * k
                return RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k))
            }

        case "Scanner":
            let phase = (t * 0.6 * spd).truncatingRemainder(dividingBy: 2.0)
            let pos = phase < 1 ? phase * Double(n - 1) : (2 - phase) * Double(n - 1)
            return (0..<n).map { i in
                var k = max(0.0, 1.0 - abs(Double(i) - pos) / (Double(n) * 0.12 + 1))
                k = k * k
                return RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k))
            }

        case "Sparkle":
            sized(&sparkle, n)
            for i in 0..<n { sparkle[i] *= 0.85 }
            if Double.random(in: 0..<1) < 0.3 + 0.6 * min(spd, 1.5) {
                sparkle[Int.random(in: 0..<n)] = 1.0
            }
            let (br, bg, bb) = (r * 0.25, g * 0.25, b * 0.25)
            return (0..<n).map { i in
                RGB(r: byte(br + (255 - br) * sparkle[i]),
                    g: byte(bg + (255 - bg) * sparkle[i]),
                    b: byte(bb + (255 - bb) * sparkle[i]))
            }

        case "Confetti":
            if confetti.count != n { confetti = [RGB](repeating: .black, count: n) }
            for i in 0..<n {
                confetti[i] = RGB(r: UInt8(Double(confetti[i].r) * 0.92),
                                  g: UInt8(Double(confetti[i].g) * 0.92),
                                  b: UInt8(Double(confetti[i].b) * 0.92))
            }
            for _ in 0..<max(1, Int(spd)) where Double.random(in: 0..<1) < 0.7 {
                confetti[Int.random(in: 0..<n)] = hsv(Double.random(in: 0..<1), 1, 1)
            }
            return confetti

        case "Fire":
            sized(&fire, n)
            for i in 0..<n {
                fire[i] = max(0.0, fire[i] - Double.random(in: 0..<0.15))
                if Double.random(in: 0..<1) < 0.35 {
                    fire[i] = min(1.0, fire[i] + Double.random(in: 0..<0.45))
                }
            }
            return fire.map { h in
                RGB(r: byte(255 * min(1, h * 1.8)),
                    g: byte(255 * min(1, max(0, h * 1.4 - 0.35))),
                    b: byte(255 * min(1, max(0, h * 2.2 - 1.5))))
            }

        case "Aurora":
            return (0..<n).map { i in
                let x = Double(i) / Double(n)
                let v = (sin(x * 5 + t * 0.7 * spd) + sin(x * 11 - t * 0.4 * spd)) / 4 + 0.5
                let h = 0.33 + v * 0.45
                let k = 0.35 + 0.65 * (0.5 + 0.5 * sin(x * 7 + t * spd))
                return hsv(h.truncatingRemainder(dividingBy: 1.0), 0.9, k)
            }

        case "Wave":
            return (0..<n).map { i in
                let k = 0.15 + 0.85 * (0.5 + 0.5 * sin(Double(i) / Double(n) * 4 * .pi - t * 3 * spd))
                return RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k))
            }

        case "Strobe":
            let on = (t * 8 * spd).truncatingRemainder(dividingBy: 1.0) < 0.25
            return [RGB](repeating: on ? color : .black, count: n)

        case "Police":
            let half = n / 2
            let swap = Int(t * 4 * spd) % 2
            let red = RGB(r: 255, g: 0, b: 0), blue = RGB(r: 0, g: 0, b: 255)
            let (a, c) = swap == 1 ? (red, blue) : (blue, red)
            return (0..<n).map { $0 < half ? a : c }

        case "Candle":
            candleK += Double.random(in: -0.12...0.12) * min(spd, 2)
            candleK = max(0.35, min(1.0, candleK))
            let k = candleK
            return [RGB](repeating: RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k)), count: n)

        default:
            return [RGB](repeating: .black, count: n)
        }
    }

    /// Music-reactive effects. `bands` are 24 smoothed energies (0...1),
    /// `level` an overall loudness (0...1), `beat` a kick-drum flag.
    func renderMusic(effect: String, n: Int, t: Double, color: RGB, speed spd: Double,
                     bands: [Double], level: Double, beat: Bool) -> [RGB] {
        let r = Double(color.r), g = Double(color.g), b = Double(color.b)
        let nb = bands.count

        switch effect {
        case "Spectrum":
            return (0..<n).map { i in
                let v = pow(bands[min(nb - 1, i * nb / n)], 1.5)
                return hsv(0.66 * (1 - Double(i) / Double(n)), 1, v)
            }

        case "Pulse":
            let k = 0.04 + 0.96 * pow(level, 1.3)
            if beat {
                return [RGB](repeating: RGB(r: byte(r * k + (255 - r * k) * 0.5),
                                            g: byte(g * k + (255 - g * k) * 0.5),
                                            b: byte(b * k + (255 - b * k) * 0.5)), count: n)
            }
            return [RGB](repeating: RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k)), count: n)

        case "VU Meter":
            let lit = Int(level * Double(n))
            return (0..<n).map { i in
                guard i < lit else { return .black }
                let frac = Double(i) / Double(max(1, n - 1))
                return hsv(0.33 * max(0.0, 1 - frac * 1.3), 1, 1)
            }

        case "Center Burst":
            let half = max(1.0, Double(n - 1) / 2)
            let c = Double(n - 1) / 2
            let ext = pow(level, 1.2) * (half + 1)
            return (0..<n).map { i in
                let d = abs(Double(i) - c)
                if beat && d < half * 0.15 { return RGB(r: 255, g: 255, b: 255) }
                let k = max(0.0, min(1.0, ext - d))
                return RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k))
            }

        case "Rainbow Beat":
            if beat && !rbeatPrev { rbeatPhase += 0.13 }
            rbeatPrev = beat
            let bri = 0.1 + 0.9 * level
            return (0..<n).map { i in
                hsv((rbeatPhase + Double(i) / Double(n) * 0.5).truncatingRemainder(dividingBy: 1.0), 1, bri)
            }

        case "Beat Flash":
            bflashV = beat ? 1.0 : bflashV * 0.80
            let k = bflashV
            return [RGB](repeating: RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k)), count: n)

        case "Ripples":
            if beat && !ripplePrev { ripples.append(0.0) }
            ripplePrev = beat
            let step = Double(n) * 0.02 * max(0.3, spd)
            ripples = ripples.map { $0 + step }.filter { $0 < Double(n) }
            let c = Double(n - 1) / 2
            let half = max(1.0, Double(n - 1) / 2)
            return (0..<n).map { i in
                let d = abs(Double(i) - c)
                var k = 0.0
                for rad in ripples {
                    let ring = max(0.0, 1.0 - abs(d - rad) / (Double(n) * 0.06 + 1))
                    let fade = max(0.0, 1.0 - rad / (half * 1.1))
                    k = max(k, ring * fade)
                }
                return RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k))
            }

        case "Bass & Treble":
            let bass = (bands[0] + bands[1] + bands[2] + bands[3] + bands[4]) / 5
            let trebStart = nb * 2 / 3
            var treb = 0.0
            for i in trebStart..<nb { treb += bands[i] }
            treb /= Double(max(1, nb - trebStart))
            if btSparkle.count != n { btSparkle = [Double](repeating: 0, count: n) }
            for i in 0..<n { btSparkle[i] *= 0.80 }
            if Double.random(in: 0..<1) < min(0.9, treb * 1.5) {
                btSparkle[Int.random(in: 0..<n)] = 1.0
            }
            let k = pow(bass, 1.2)
            return (0..<n).map { i in
                RGB(r: byte(r * k + (255 - r * k) * btSparkle[i]),
                    g: byte(g * k + (255 - g * k) * btSparkle[i]),
                    b: byte(b * k + (255 - b * k) * btSparkle[i]))
            }

        case "Mirror Spectrum":
            // bass at the center, treble toward both ends
            let c = Double(n - 1) / 2
            let halfN = max(1.0, Double(n) / 2)
            return (0..<n).map { i in
                let d = abs(Double(i) - c) / halfN
                let v = pow(bands[min(nb - 1, Int(d * Double(nb)))], 1.5)
                return hsv(0.66 * d, 1, v)
            }

        case "Dual VU":
            // level bars grow inward from both ends
            let lit = Int(level * Double(n) / 2)
            let halfN = max(1.0, Double(n) / 2)
            return (0..<n).map { i in
                let dist = min(i, n - 1 - i)
                guard dist < lit else { return .black }
                let frac = Double(dist) / halfN
                return hsv(0.33 * max(0.0, 1 - frac * 1.3), 1, 1)
            }

        case "Color Organ":
            // three fixed zones driven by low / mid / high frequency energy
            let third = max(1, nb / 3)
            func bandMean(_ lo: Int, _ hi: Int) -> Double {
                var s = 0.0
                for k in lo..<hi { s += bands[k] }
                return s / Double(max(1, hi - lo))
            }
            let low = bandMean(0, third)
            let mid = bandMean(third, 2 * third)
            let high = bandMean(2 * third, nb)
            let seg = max(1, n / 3)
            return (0..<n).map { i in
                if i < seg { return RGB(r: byte(255 * low), g: 0, b: 0) }
                else if i < 2 * seg { return RGB(r: 0, g: byte(255 * mid), b: 0) }
                else { return RGB(r: 0, g: 0, b: byte(255 * high)) }
            }

        case "Fireworks":
            // each beat launches a colored burst at a random spot
            if beat && !fireworksPrev {
                fireworks.append((pos: Double.random(in: 0..<Double(n)),
                                  radius: 0, hue: Double.random(in: 0..<1)))
            }
            fireworksPrev = beat
            let grow = Double(n) * 0.03 * max(0.3, spd)
            fireworks = fireworks.map { (pos: $0.pos, radius: $0.radius + grow, hue: $0.hue) }
                                 .filter { $0.radius < Double(n) * 0.5 }
            return (0..<n).map { i in
                var rr = 0.0, gg = 0.0, bb = 0.0
                for fw in fireworks {
                    let ring = max(0.0, 1.0 - abs(abs(Double(i) - fw.pos) - fw.radius) / (Double(n) * 0.05 + 1))
                    let fade = max(0.0, 1.0 - fw.radius / (Double(n) * 0.5))
                    let k = ring * fade
                    if k > 0 {
                        let col = hsv(fw.hue, 1, 1)
                        rr += Double(col.r) * k; gg += Double(col.g) * k; bb += Double(col.b) * k
                    }
                }
                return RGB(r: byte(rr), g: byte(gg), b: byte(bb))
            }

        case "Energy Comet":
            // a comet whose tail length and brightness track the loudness
            let head = (t * Double(n) * 0.5 * spd).truncatingRemainder(dividingBy: Double(n))
            let tailLen = 0.1 + 0.5 * level
            let bright = 0.2 + 0.8 * level
            return (0..<n).map { i in
                var d = (head - Double(i)).truncatingRemainder(dividingBy: Double(n))
                if d < 0 { d += Double(n) }
                var k = max(0.0, 1.0 - d / (Double(n) * tailLen))
                k = k * k * bright
                return RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k))
            }

        case "Bass Pump":
            // whole strip punches with the kick / bass energy only
            let bass = (bands[0] + bands[1] + bands[2] + bands[3]) / 4
            let k = pow(bass, 1.5)
            return [RGB](repeating: RGB(r: byte(r * k), g: byte(g * k), b: byte(b * k)), count: n)

        case "Flow":
            // a hue gradient that scrolls faster and brighter with the music
            flowPhase += (0.005 + level * 0.06) * spd
            let bright = 0.3 + 0.7 * level
            return (0..<n).map { i in
                var h = (flowPhase + Double(i) / Double(n)).truncatingRemainder(dividingBy: 1.0)
                if h < 0 { h += 1 }
                return hsv(h, 1, bright)
            }

        case "Meter Peak":
            // VU meter with a slowly falling peak-hold dot
            let lit = Int(level * Double(n))
            meterPeak = max(Double(lit), meterPeak - Double(n) * 0.01)
            let peakIdx = Int(meterPeak)
            return (0..<n).map { i in
                if i == peakIdx && peakIdx < n { return RGB(r: 255, g: 255, b: 255) }
                guard i < lit else { return .black }
                let frac = Double(i) / Double(max(1, n - 1))
                return hsv(0.33 * max(0.0, 1 - frac * 1.3), 1, 1)
            }

        default:
            return [RGB](repeating: .black, count: n)
        }
    }
}
