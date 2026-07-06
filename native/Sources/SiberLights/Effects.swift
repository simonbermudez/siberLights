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
}
