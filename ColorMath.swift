import Foundation

// Transfer functions and gamut matrices.
// Numbers come from Sony's published S-Log2/S-Log3 specs, ITU-R BT.2100 (HLG) and the Sony
// primaries as tabulated in colour-science (BSD-3-Clause).

@inline(__always) func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }

func srgbEnc(_ x: Float) -> Float { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
func srgbDec(_ y: Float) -> Float { y <= 0.04045 ? y / 12.92 : pow((y + 0.055) / 1.055, 2.4) }
func rec709Enc(_ x: Float) -> Float { x < 0.018 ? 4.5 * x : 1.099 * pow(x, 0.45) - 0.099 }

/// S-Log2 from scene reflection (0.18 = mid grey) to legal-range code value / 1023 (spec: 18 % grey -> 347).
func slog2(_ x: Float) -> Float {
    let xp = x / 0.9 * 155 / 219
    let y: Float = xp >= 0 ? 0.432699 * log10(xp + 0.037584) + 0.616596 + 0.03 : xp * 5 + 0.030001
    return (y * 876 + 64) / 1023
}

/// S-Log3 from scene reflection to code value / 1023 (spec: 18 % grey -> 420).
func slog3(_ x: Float) -> Float {
    x >= 0.01125 ? (420 + log10((x + 0.01) / 0.19) * 261.5) / 1023
                 : (x * (171.2102946929 - 95) / 0.01125 + 95) / 1023
}

/// HLG OETF, input in scene light normalised to 1.
func hlgOETF(_ e: Float) -> Float {
    e <= 1 / 12 ? sqrt(3 * e) : 0.17883277 * log(12 * e - 0.28466892) + 0.55991073
}

/// Fujifilm F-Log (reflection input, 18 % grey -> 0.4593). Constants from Fujifilm's F-Log data sheet via colour-science.
func flog(_ x: Float) -> Float {
    x < 0.00089 ? 8.735631 * x + 0.092864 : 0.344676 * log10(0.555556 * x + 0.009468) + 0.790453
}

/// Fujifilm F-Log2 (18 % grey -> 0.3910).
func flog2(_ x: Float) -> Float {
    x < 0.000889 ? 8.799461 * x + 0.092864 : 0.245281 * log10(5.555556 * x + 0.064829) + 0.384316
}

/// Panasonic V-Log (reflection input, 18 % grey -> 0.4233). Constants from Panasonic's V-Log spec via colour-science.
func vlog(_ x: Float) -> Float {
    x < 0.01 ? 5.6 * x + 0.125 : 0.241514 * log10(x + 0.00873) + 0.598206
}

/// A named scene-referred target: a 3x3 from linear Rec.709 plus a transfer curve.
struct SceneSpace {
    let name: String
    let matrix: [[Float]]          // rows; output = matrix * (r,g,b)
    let curve: (Float) -> Float    // linear -> encoded, 0...1
    /// false: the LUT expects a ready-made display picture (tone-mapped decode, e.g. Fujifilm film-simulation LUTs).
    var sceneReferred = true

    static let domainMax: Float = 16
    static let tableSize = 16384   // CIColorCurves returns zeros above this

    /// 1-D table (RGB triplets) over [0, domainMax] for CIColorCurves.
    var tableData: Data {
        var t = [Float](repeating: 0, count: Self.tableSize * 3)
        for i in 0..<Self.tableSize {
            let x = Self.domainMax * Float(i) / Float(Self.tableSize - 1)
            let y = clamp01(curve(x))
            t[3 * i] = y; t[3 * i + 1] = y; t[3 * i + 2] = y
        }
        return t.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

enum Scenes {
    // Linear Rec.709 -> S-Gamut3 / S-Gamut3.Cine / BT.2020 (D65), derived from the primaries; rows sum to 1.
    static let toSGamut3: [[Float]] = [[0.566049, 0.342763, 0.091188],
                                       [0.076961, 0.799055, 0.123984],
                                       [0.022351, 0.108612, 0.869037]]
    static let toSGamut3Cine: [[Float]] = [[0.645679, 0.259115, 0.095206],
                                           [0.087530, 0.759700, 0.152770],
                                           [0.036957, 0.129281, 0.833762]]
    static let toBT2020: [[Float]] = [[0.627404, 0.329283, 0.043313],
                                      [0.069097, 0.919540, 0.011362],
                                      [0.016391, 0.088013, 0.895595]]
    /// V-Gamut primaries R(0.730,0.280) G(0.165,0.840) B(0.100,-0.030), D65.
    static let toVGamut: [[Float]] = [[0.585196, 0.322642, 0.092162],
                                      [0.078589, 0.819627, 0.101784],
                                      [0.022794, 0.114217, 0.862989]]
    /// F-Gamut = BT.2020 primaries; F-Gamut C primaries R(0.7347,0.2653) G(0.0263,0.9737) B(0.1173,-0.0224), D65.
    static let toFGamutC: [[Float]] = [[0.517069, 0.412935, 0.069996],
                                       [0.088617, 0.809263, 0.102120],
                                       [0.017750, 0.109448, 0.872802]]

    /// HLG scene scale: 100 % reflectance -> 75 % signal, 18 % grey -> ~38 % (BT.2408).
    static let hlgScale: Float = 0.265

    static let slog2SG3 = SceneSpace(name: "S-Log2 / S-Gamut3", matrix: toSGamut3, curve: slog2)
    static let slog3SG3Cine = SceneSpace(name: "S-Log3 / S-Gamut3.Cine", matrix: toSGamut3Cine, curve: slog3)
    static let slog3SG3 = SceneSpace(name: "S-Log3 / S-Gamut3", matrix: toSGamut3, curve: slog3)
    static let hlg2020 = SceneSpace(name: "HLG / BT.2020", matrix: toBT2020, curve: { hlgOETF($0 * hlgScale) })

    static let vlogVGamut = SceneSpace(name: "V-Log / V-Gamut", matrix: toVGamut, curve: vlog)
    static let flogFGamut = SceneSpace(name: "F-Log / F-Gamut", matrix: toBT2020, curve: flog)
    static let flog2FGamut = SceneSpace(name: "F-Log2 / F-Gamut", matrix: toBT2020, curve: flog2)
    static let flog2CFGamutC = SceneSpace(name: "F-Log2C / F-Gamut C", matrix: toFGamutC, curve: flog2)
    static let flogCFGamutC = SceneSpace(name: "F-LogC / F-Gamut C", matrix: toFGamutC, curve: flog)
    static let srgbDisplay = SceneSpace(name: "sRGB display (tone-mapped)", matrix: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
                                        curve: srgbEnc, sceneReferred: false)

    /// Best guess at a LUT's expected input from its file name (nil = no idea).
    static func guessInput(fromFileName name: String) -> SceneSpace? {
        let n = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if n.contains("vlog") { return vlogVGamut }   // before F-Log: "FLog2C_to_PROVIA_VLog" is a V-Log-input LUT
        if n.contains("flog2c") { return flog2CFGamutC }
        if n.contains("flog2") { return flog2FGamut }
        if n.contains("flogc") { return flogCFGamutC }
        if n.contains("flog") { return flogFGamut }
        if n.contains("slog2") { return slog2SG3 }
        if n.contains("slog3") { return n.contains("cine") ? slog3SG3Cine : slog3SG3 }
        let filmSims = ["provia", "velvia", "astia", "classicchrome", "classicneg", "proneg", "acros", "eterna",
                        "nostalgicneg", "reala", "sepia", "monochrome"]
        if filmSims.contains(where: n.contains) { return srgbDisplay }
        return nil
    }

    /// Choices offered for a loaded .cube LUT's expected input.
    static let lutInputs: [SceneSpace] = [slog3SG3Cine, slog3SG3, slog2SG3, vlogVGamut,
                                          flogFGamut, flog2FGamut, flog2CFGamutC, flogCFGamutC, srgbDisplay]
}

enum ColorMathTests {
    /// Returns a list of failures (empty = all good).
    static func run() -> [String] {
        var bad: [String] = []
        func near(_ a: Float, _ b: Float, _ tol: Float, _ what: String) {
            if abs(a - b) > tol { bad.append("\(what): got \(a), expected \(b)") }
        }
        for (n, m) in [("SG3", Scenes.toSGamut3), ("SG3C", Scenes.toSGamut3Cine), ("2020", Scenes.toBT2020)] {
            for (i, r) in m.enumerated() { near(r.reduce(0, +), 1, 1e-4, "\(n) row \(i) sum") }
        }
        near(slog3(0.18) * 1023, 420, 0.5, "S-Log3 18% grey CV")
        near(slog2(0.18) * 1023, 347, 0.5, "S-Log2 18% grey CV")
        near(vlog(0.18), 0.4233, 0.0005, "V-Log 18% grey")
        for (i, r) in Scenes.toVGamut.enumerated() { near(r.reduce(0, +), 1, 1e-4, "VGamut row \(i) sum") }
        near(flog(0.18), 0.4593, 0.0005, "F-Log 18% grey")
        near(flog2(0.18), 0.3910, 0.0005, "F-Log2 18% grey")
        for (n, m) in [("FGamutC", Scenes.toFGamutC)] {
            for (i, r) in m.enumerated() { near(r.reduce(0, +), 1, 1e-4, "\(n) row \(i) sum") }
        }
        near(hlgOETF(0.18 * Scenes.hlgScale), 0.38, 0.01, "HLG 18% grey")
        near(hlgOETF(1 * Scenes.hlgScale), 0.75, 0.005, "HLG 100% reflectance")
        return bad
    }
}
