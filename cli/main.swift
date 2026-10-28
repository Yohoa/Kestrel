import Foundation
import CoreImage
import ImageIO

// Usage:
//   cli --selftest                         colour-math and pipeline self-tests
//   cli file.ARW <pp> out.heic [--ev N] [--temp K] [--tint T] [--no-hl] [--auto-ev [--metering matrix|hybrid|average|center-weighted|highlight-safe]] [--lut file.cube] [--stats]
//   <pp> is 0-10 (built-in) or ignored when --lut is given.

func synthetic(_ v: SIMD3<Float>) -> CIImage {
    CIImage(color: CIColor(red: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z),
                           colorSpace: Engine.linear)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
}

func selfTest() -> Bool {
    var ok = true
    func check(_ what: String, _ got: Float, _ want: Float, _ tol: Float) {
        let pass = abs(got - want) <= tol
        if !pass { ok = false }
        print(pass ? "ok  " : "FAIL", what, "got", got, "want", want)
    }
    for f in ColorMathTests.run() { ok = false; print("FAIL", f) }

    // Mid grey through the scene looks must hit Sony's code values exactly (matrices keep neutrals).
    let grey = synthetic(SIMD3(repeating: 0.18))
    let slog2Look = Looks.builtIn[7], slog3Look = Looks.builtIn[9], cineLook = Looks.builtIn[8], hlg = Looks.builtIn[10]
    check("PP9 S-Log3 18% grey CV", Engine.samplePixel(Engine.apply(slog3Look, to: grey)!, slog3Look).y * 1023, 420, 0.6)
    check("PP7 S-Log2 18% grey CV", Engine.samplePixel(Engine.apply(slog2Look, to: grey)!, slog2Look).y * 1023, 347, 0.6)
    let c = Engine.samplePixel(Engine.apply(cineLook, to: grey)!, cineLook)
    check("PP8 neutral R=G", c.x, c.y, 0.001); check("PP8 neutral G=B", c.y, c.z, 0.001)
    check("PP10 HLG 18% grey", Engine.samplePixel(Engine.apply(hlg, to: grey)!, hlg).y, 0.38, 0.01)

    // Saturated colour: hand-computed S-Gamut3.Cine + S-Log3.
    let sat = SIMD3<Float>(0.5, 0.05, 0.05)
    let m = Scenes.toSGamut3Cine
    let exp = (0..<3).map { i in slog3(m[i][0] * sat.x + m[i][1] * sat.y + m[i][2] * sat.z) }
    let got = Engine.samplePixel(Engine.apply(cineLook, to: synthetic(sat))!, cineLook)
    check("PP8 saturated R", got.x, exp[0], 1.5e-3); check("PP8 saturated G", got.y, exp[1], 1.5e-3); check("PP8 saturated B", got.z, exp[2], 1.5e-3)

    // An identity 33^3 LUT must reproduce the plain S-Log3 look.
    let idLook = Looks.lutLook(index: 0, url: URL(fileURLWithPath: "/identity.cube"), lut: CubeLUT.identity(size: 33), input: Scenes.slog3SG3)
    for v: Float in [0.02, 0.18, 0.6] {
        let a = Engine.samplePixel(Engine.apply(idLook, to: synthetic(SIMD3(repeating: v)))!, idLook)
        check("identity LUT @\(v)", a.y, slog3(v), 3e-3)   // CIColorCube quantises slightly (~2 of 1023)
    }

    // Parser round-trip.
    let text = "TITLE \"t\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
    if let p = try? CubeLUT.parse(text), p.size == 2 { print("ok   .cube parse") } else { ok = false; print("FAIL .cube parse") }
    if (try? CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0\n")) == nil { print("ok   1D LUT rejected") } else { ok = false; print("FAIL 1D accepted") }
    print(ok ? "ALL PASSED" : "SOME FAILED")
    return ok
}

func stats(_ img: CIImage, _ look: PPLook) {
    func avg(_ f: String) -> SIMD3<Float> {
        let out = img.applyingFilter(f, parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        return Engine.samplePixel(out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY)), look)
    }
    print("mean", avg("CIAreaAverage"), "max", avg("CIAreaMaximum"), "min", avg("CIAreaMinimum"))
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--selftest" { exit(selfTest() ? 0 : 1) }
if args.first == "--hist", args.count >= 2 {
    // cli --hist file.ARW : UnExp / OvExp per channel (the lens-circle mask applies automatically)
    guard let h = HistogramData.make(url: URL(fileURLWithPath: args[1]), adj: Adjust()) else { print("failed"); exit(2) }
    print("circleMasked:", h.circleMasked, "under%:", h.under.map { String(format: "%.1f", $0) }, "over%:", h.over.map { String(format: "%.3f", $0) })
    exit(0)
}
if args.first == "--xmp-selftest" { exit(XMPTests.run() ? 0 : 1) }

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func has(_ flag: String) -> Bool { if let i = args.firstIndex(of: flag) { args.remove(at: i); return true }; return false }

var adj = Adjust()
adj.ev = Float(take("--ev") ?? "") ?? 0
let meterName = take("--metering") ?? "hybrid"
if has("--auto-ev") {
    let mode = MeteringMode(rawValue: meterName) ?? .hybrid
    let r = Metering.autoEVResult(url: URL(fileURLWithPath: args.first ?? ""), baseEV: adj.ev, mode: mode, maskLensCircle: !has("--no-lens-mask"))
    let ev = r?.ev ?? 0
    print("auto EV (\(mode.rawValue)):", ev, r?.circleMasked == true ? "(lens corners ignored)" : "")
    adj.ev += ev
}
adj.temp = Float(take("--temp") ?? "")
adj.tint = Float(take("--tint") ?? "")
adj.highlightRecovery = !has("--no-hl")
let lutPath = take("--lut")
let wantStats = has("--stats")
guard args.count >= 3, let ppID = Int(args[1]), ppID < Looks.builtIn.count else {
    print("usage: cli file.ARW pp out.heic [--ev N] [--temp K] [--tint T] [--no-hl] [--auto-ev [--metering matrix|hybrid|average|center-weighted|highlight-safe]] [--lut f.cube] [--stats] | cli --selftest"); exit(1)
}
var look = Looks.builtIn[ppID]
if let lutPath {
    do {
        let u = URL(fileURLWithPath: lutPath)
        look = Looks.lutLook(index: 0, url: u, lut: try CubeLUT.load(u), input: Scenes.guessInput(fromFileName: u.lastPathComponent) ?? Scenes.slog3SG3Cine)
    } catch { print("LUT error:", error); exit(4) }
}
let t0 = Date()
let d = Decoded(url: URL(fileURLWithPath: args[0]), adj: adj, scale: 1)
guard let img = d.render(look) else { print("render failed"); exit(2) }
if wantStats { stats(img, look) }
do {
    let data = try Engine.heic10(img, look, quality: 0.85)
    try data.write(to: URL(fileURLWithPath: args[2]))
    print("wrote \(data.count) bytes in \(Date().timeIntervalSince(t0))s")
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil)!
    let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    print("depth:", p[kCGImagePropertyDepth] ?? "?", "size:", p[kCGImagePropertyPixelWidth] ?? "?", "x", p[kCGImagePropertyPixelHeight] ?? "?",
          "profile:", p[kCGImagePropertyProfileName] ?? "?")
} catch { print("error:", error); exit(3) }
