import Foundation
import CoreImage
import CoreGraphics
import AppKit

// MARK: - Display-look helpers (hand-tuned approximations)

func sCurve(_ y: Float, _ k: Float) -> Float {
    let c = clamp01(y)
    let s = c * c * (3 - 2 * c)
    return c + k * (s - c)
}

func shoulder(_ y: Float, _ knee: Float) -> Float {
    if knee >= 1 || y <= knee { return y }
    let t = (y - knee) / (1 - knee)
    return knee + (1 - knee) * tanh(t) / tanh(Float(1))
}

func saturate(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
    let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    return SIMD3(repeating: l) + (c - SIMD3(repeating: l)) * s
}

func displayLook(enc: @escaping (Float) -> Float = srgbEnc,
                 contrast: Float, knee: Float, lift: Float = 0, black: Float = 0,
                 sat: Float) -> (SIMD3<Float>) -> SIMD3<Float> {
    { x in
        let f = { (lin: Float) -> Float in
            var v = enc(lin)
            v = sCurve(v, contrast)
            v = shoulder(v, knee)
            v = max(0, (v - black) / (1 - black))
            return lift + (1 - lift) * v
        }
        let c = saturate(SIMD3(f(x.x), f(x.y), f(x.z)), sat)
        return SIMD3(srgbDec(clamp01(c.x)), srgbDec(clamp01(c.y)), srgbDec(clamp01(c.z)))
    }
}

// MARK: - Looks

struct PPLook: Identifiable {
    enum Kind {
        /// Maps display-referred linear (0...1) to linear; Core Image converts to the output space.
        case display((SIMD3<Float>) -> SIMD3<Float>)
        /// Scene-linear -> gamut matrix -> log/HLG curve; values are final and only relabelled.
        case scene(SceneSpace)
        /// Scene-linear -> gamut matrix -> log curve -> 3D LUT whose output is display-referred.
        case lut(CubeLUT, SceneSpace)
    }

    let id: Int
    let name: String
    let note: String
    let kind: Kind
    let spaceName: CFString    // colour space the 10-bit file is tagged with

    var label: String { id == 0 ? "Base" : (id < 100 ? "PP\(id)" : name) }
    /// Safe for use in file and folder names.
    var fileName: String {
        id < 100 ? label : name.replacingOccurrences(of: " · ", with: "-").replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
    /// Display title: "Base", "Sony PP3 ITU709" (Sony's picture profiles; "PP" alone means nothing to most), or a LUT's name.
    var title: String { id == 0 ? "Base" : (id < 100 ? "Sony PP\(id) \(name)" : name) }
    var space: CGColorSpace { CGColorSpace(name: spaceName)! }
    var needsSceneLinear: Bool {
        switch kind {
        case .display: return false
        case .scene: return true
        case .lut(_, let s): return s.sceneReferred
        }
    }
}

enum Looks {
    // PP numbering is the ILCE-7C default table from Sony's Help Guide (PP1 Movie, PP2 Still, PP3/PP4 ITU709,
    // PP5 Cine1, PP6 Cine2, PP7 S-Log2, PP8 S-Log3/S-Gamut3.Cine, PP9 S-Log3/S-Gamut3, PP10 HLG2; no PP11/S-Cinetone).
    // PP1-PP6 are approximations (Sony's exact curves and colour matrices are proprietary).
    // PP7-PP10 are scene-referred: Sony's published log curves with the S-Gamut matrices, or HLG/BT.2020.
    static let builtIn: [PPLook] = [
        PPLook(id: 0, name: "Base", note: "sRGB, no look", kind: .display(displayLook(contrast: 0, knee: 1, sat: 1)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 1, name: "Movie", note: "≈ gentle contrast, soft highlights", kind: .display(displayLook(contrast: 0.10, knee: 0.80, sat: 1.0)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 2, name: "Still", note: "≈ punchy, saturated", kind: .display(displayLook(contrast: 0.25, knee: 0.90, sat: 1.08)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 3, name: "ITU709", note: "≈ Rec.709 gamma, natural tone", kind: .display(displayLook(enc: rec709Enc, contrast: 0.08, knee: 1, sat: 1.03)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 4, name: "ITU709 (709)", note: "Rec.709 OETF, faithful to the standard", kind: .display(displayLook(enc: rec709Enc, contrast: 0, knee: 1, sat: 1)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 5, name: "Cine1", note: "≈ contrasty, muted", kind: .display(displayLook(contrast: 0.35, knee: 0.70, black: 0.01, sat: 0.95)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 6, name: "Cine2", note: "≈ deep blacks, low saturation", kind: .display(displayLook(contrast: 0.50, knee: 0.75, black: 0.03, sat: 0.88)), spaceName: CGColorSpace.displayP3),
        PPLook(id: 7, name: "S-Log2", note: "S-Log2 + S-Gamut3, scene-linear", kind: .scene(Scenes.slog2SG3), spaceName: CGColorSpace.sRGB),
        PPLook(id: 8, name: "S-Log3 Cine", note: "S-Log3 + S-Gamut3.Cine, scene-linear", kind: .scene(Scenes.slog3SG3Cine), spaceName: CGColorSpace.sRGB),
        PPLook(id: 9, name: "S-Log3", note: "S-Log3 + S-Gamut3, scene-linear", kind: .scene(Scenes.slog3SG3), spaceName: CGColorSpace.sRGB),
        PPLook(id: 10, name: "HLG", note: "BT.2020 + HLG (HDR), scene-linear", kind: .scene(Scenes.hlg2020), spaceName: CGColorSpace.itur_2100_HLG),
    ]

    /// Look for a `.cube` file; `input` says which log encoding the LUT expects. `group` is its parent folder name.
    static func lutLook(index: Int, url: URL, lut: CubeLUT, input: SceneSpace, group: String? = nil) -> PPLook {
        var short = url.deletingPathExtension().lastPathComponent
        short = short.replacingOccurrences(of: "_VLog", with: "")
        if let r = short.range(of: "_to_") { short = String(short[r.upperBound...]) }
        short = short.replacingOccurrences(of: "_", with: " ")
        let name = (group?.isEmpty == false) ? "\(group!) · \(short)" : short
        return PPLook(id: 100 + index, name: name, note: "LUT · expects \(input.name) · \(url.lastPathComponent)",
                      kind: .lut(lut, input), spaceName: CGColorSpace.sRGB)
    }
}

// MARK: - Engine

/// Per-photo adjustments applied while the RAW is developed.
struct Adjust: Hashable {
    var ev: Float = 0
    var temp: Float?        // Kelvin; nil = as shot
    var tint: Float?        // nil = as shot
    /// On by default: without it, blown highlights go magenta (green clips first, white balance then lifts R and B past it).
    var highlightRecovery = true
    /// FastRawViewer-style contrast grade, -5...+5 (K / ⇧K). Applied in scene-linear light around 18 % grey,
    /// before the look, so it works the same for the PP looks, log looks and LUTs.
    var contrast: Float = 0
    /// Quarter turns clockwise on top of the camera's own orientation (0...3). Applied right after decoding, so
    /// everything downstream (looks, histogram, overlay, zoom, export) sees the photo the right way up.
    var rot = 0
}

final class Decoded {
    let url: URL
    let adj: Adjust
    let scale: Float
    private var display: CIImage?
    private var scene: CIImage?
    private let lock = NSLock()

    init(url: URL, adj: Adjust, scale: Float) { self.url = url; self.adj = adj; self.scale = scale }

    /// As-shot white balance of a RAW (Kelvin, tint).
    static func asShot(_ url: URL) -> (temp: Float, tint: Float)? {
        if BitmapPhoto.isBitmap(url) { return BitmapPhoto.asShot }
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        return (f.neutralTemperature, f.neutralTint)
    }

    private func decode(scene: Bool) -> CIImage? {
        let img = BitmapPhoto.isBitmap(url) ? BitmapPhoto.decode(url, adj: adj, scale: scale)
            : Decoded.filter(url: url, adj: adj, scale: scale, scene: scene)?.filter.outputImage
        return img.map { Orientation.rotate($0, adj.rot) }
    }

    /// The configured RAW filter plus the camera's as-shot white balance (read before any custom WB is applied).
    static func filter(url: URL, adj: Adjust, scale: Float, scene: Bool) -> (filter: CIRAWFilter, asShot: (temp: Float, tint: Float))? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        let asShot = (f.neutralTemperature, f.neutralTint)
        f.scaleFactor = scale
        f.exposure += adj.ev
        f.extendedDynamicRangeAmount = 0
        if scene {
            // Log / HLG must be encoded from genuinely linear light: no global tone curve, no gamut clip.
            f.boostAmount = 0
            f.isGamutMappingEnabled = false
        }
        if let t = adj.temp { f.neutralTemperature = t }
        if let t = adj.tint { f.neutralTint = t }
        if #available(macOS 26, *), f.isHighlightRecoverySupported { f.isHighlightRecoveryEnabled = adj.highlightRecovery }
        return (f, asShot)
    }

    /// Click-to-grey: the temperature and tint that make the clicked spot neutral. `u` and `v` are 0...1 fractions
    /// of the picture (v from the top). Core Image wants full-size output coordinates with the origin bottom-left.
    static func pickNeutral(_ url: URL, u: Double, vFromTop v: Double, rot: Int = 0) -> (temp: Float, tint: Float)? {
        let (u, v) = Orientation.unrotate(u: u, v: v, rot)        // the click is on the turned picture
        if BitmapPhoto.isBitmap(url) { return BitmapPhoto.colour(url, u: u, vFromTop: v).flatMap(BitmapPhoto.neutral) }
        guard let f = CIRAWFilter(imageURL: url), let ext = f.outputImage?.extent else { return nil }
        f.neutralLocation = CGPoint(x: u * Double(ext.width), y: (1 - v) * Double(ext.height))
        return (f.neutralTemperature, f.neutralTint)
    }

    /// The scene-linear decode (no look applied), used for metering.
    func sceneLinear() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if scene == nil { scene = decode(scene: true) }
        return scene
    }

    /// The display-referred decode (tone boost and gamut mapping on), the source of the PP display looks.
    func displayLinear() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if display == nil { display = decode(scene: false) }
        return display
    }

    func render(_ look: PPLook) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        let wantScene = look.needsSceneLinear
        if wantScene { if scene == nil { scene = decode(scene: true) } }
        else if display == nil { display = decode(scene: false) }
        guard let src = wantScene ? scene : display else { return nil }
        return Engine.apply(look, to: Engine.contrast(src, grade: adj.contrast))
    }

    /// "Auto" white balance (grey world): the temperature / tint that make the picture's average neutral.
    /// Core Image has no auto mode, so the illuminant estimate is moved by the colour cast of the average
    /// (in xy chromaticity) and Core Image is asked which Kelvin / tint that corresponds to. Two passes.
    static func autoWB(_ url: URL) -> (temp: Float, tint: Float)? {
        if BitmapPhoto.isBitmap(url) { return BitmapPhoto.averageColour(url).flatMap(BitmapPhoto.neutral) }
        guard let f0 = CIRAWFilter(imageURL: url) else { return nil }
        var n = f0.neutralChromaticity
        for _ in 0..<2 {
            guard let f = CIRAWFilter(imageURL: url) else { return nil }
            f.neutralChromaticity = n
            f.scaleFactor = 0.08
            f.boostAmount = 0
            guard let img = f.outputImage, let xy = averageChromaticity(img) else { return nil }
            n = CGPoint(x: n.x + (xy.x - 0.3127), y: n.y + (xy.y - 0.3290))
        }
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        f.neutralChromaticity = n
        return (f.neutralTemperature, f.neutralTint)
    }

    /// xy chromaticity of the mean of the mid-tone pixels (clipped and near-black pixels left out).
    static func averageChromaticity(_ img: CIImage) -> CGPoint? {
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w > 4, h > 4 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: img.extent, format: .RGBAf, colorSpace: Engine.linear)
        var r: Double = 0, g: Double = 0, b: Double = 0, n = 0
        for i in 0..<(w * h) {
            let pr = px[4 * i], pg = px[4 * i + 1], pb = px[4 * i + 2]
            let m = max(pr, pg, pb)
            guard m < 0.95, m > 0.01 else { continue }
            r += Double(pr); g += Double(pg); b += Double(pb); n += 1
        }
        guard n > 100 else { return nil }
        r /= Double(n); g /= Double(n); b /= Double(n)
        // linear sRGB (D65) -> XYZ
        let X = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let Z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        let s = X + Y + Z
        guard s > 0 else { return nil }
        return CGPoint(x: X / s, y: Y / s)
    }
}

enum Engine {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let ctx = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])

    private static var cubes: [Int: Data] = [:]
    private static let cubeLock = NSLock()
    private static var tables: [String: Data] = [:]

    /// 65^3 LUT for the hand-tuned display looks (input is gamma-2.4 shaped so shadows get resolution).
    static func displayCube(for look: PPLook, map: (SIMD3<Float>) -> SIMD3<Float>) -> Data {
        cubeLock.lock(); defer { cubeLock.unlock() }
        if let d = cubes[look.id] { return d }
        let n = 65
        var d = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let v = SIMD3<Float>(Float(r), Float(g), Float(b)) / Float(n - 1)
            let o = map(SIMD3<Float>(pow(v.x, 2.4), pow(v.y, 2.4), pow(v.z, 2.4)))
            d[i] = o.x; d[i + 1] = o.y; d[i + 2] = o.z; d[i + 3] = 1
            i += 4
        }}}
        let data = d.withUnsafeBufferPointer { Data(buffer: $0) }
        cubes[look.id] = data
        return data
    }

    private static func table(for s: SceneSpace) -> Data {
        cubeLock.lock(); defer { cubeLock.unlock() }
        if let t = tables[s.name] { return t }
        let t = s.tableData
        tables[s.name] = t
        return t
    }

    private static func matrix(_ img: CIImage, _ m: [[Float]]) -> CIImage {
        func v(_ r: [Float]) -> CIVector { CIVector(x: CGFloat(r[0]), y: CGFloat(r[1]), z: CGFloat(r[2]), w: 0) }
        return img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v(m[0]), "inputGVector": v(m[1]), "inputBVector": v(m[2]),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    private static func encodeScene(_ img: CIImage, _ s: SceneSpace) -> CIImage {
        matrix(img, s.matrix).applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table(for: s),
            "inputCurvesDomain": CIVector(x: 0, y: CGFloat(SceneSpace.domainMax)),
            "inputColorSpace": linear,
        ])
    }

    /// Contrast grade around 18 % grey: y = 0.18 · (x / 0.18)^k with k = 1 + 0.12 · grade.
    static func contrast(_ img: CIImage, grade: Float) -> CIImage {
        guard grade != 0 else { return img }
        let k = CGFloat(1 + 0.12 * grade)
        let scale = CGFloat(pow(0.18, Double(1 - k)))
        return img
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 64, y: 64, z: 64, w: 1),
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": k])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: img.extent)
    }

    /// Display looks return linear light in the working space; scene/LUT looks return an image whose
    /// numbers are final encoded values, relabelled as being in `look.space` (so export writes them untouched).
    static func apply(_ look: PPLook, to img: CIImage) -> CIImage? {
        switch look.kind {
        case .display(let map):
            return img
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.4])
                .applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": 65,
                    "inputCubeData": displayCube(for: look, map: map),
                ])
                .cropped(to: img.extent)
        case .scene(let s):
            return relabel(encodeScene(img, s).cropped(to: img.extent), look)
        case .lut(let lut, let s):
            var x = encodeScene(img, s)
            if !lut.hasDefaultDomain {
                let span = lut.domainMax - lut.domainMin
                func row(_ i: Int) -> CIVector {
                    var c = [CGFloat](repeating: 0, count: 4)
                    c[i] = CGFloat(1 / span[i])
                    return CIVector(values: c, count: 4)
                }
                x = x.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": row(0), "inputGVector": row(1), "inputBVector": row(2),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: CGFloat(-lut.domainMin.x / span.x), y: CGFloat(-lut.domainMin.y / span.y),
                                                z: CGFloat(-lut.domainMin.z / span.z), w: 0),
                ])
            }
            x = x.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": lut.size,
                "inputCubeData": lut.data,
            ])
            return relabel(x.cropped(to: img.extent), look)
        }
    }

    private static func relabel(_ img: CIImage, _ look: PPLook) -> CIImage {
        img.matchedToWorkingSpace(from: look.space) ?? img
    }

    static func cgImage(_ img: CIImage, _ look: PPLook) -> CGImage? {
        ctx.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: look.space)
    }

    /// 8-bit RGB TIFF (Core Image compresses it with LZW, lossless), without an alpha channel.
    static func tiffRGB(_ img: CIImage, _ look: PPLook) -> Data? {
        ctx.tiffRepresentation(of: img, format: .RGBX8, colorSpace: look.space)
    }

    static func jpeg(_ img: CIImage, _ look: PPLook, quality: Float) -> Data? {
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ctx.jpegRepresentation(of: img, colorSpace: look.space, options: [key: quality])
    }

    static func heic10(_ img: CIImage, _ look: PPLook, quality: Float) throws -> Data {
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return try ctx.heif10Representation(of: img, colorSpace: look.space, options: [key: quality])
    }

    /// Reads one pixel (encoded values in `look.space`) from a tiny rendered image. For tests.
    static func samplePixel(_ img: CIImage, _ look: PPLook) -> SIMD3<Float> {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBAf, colorSpace: look.space)
        return SIMD3(px[0], px[1], px[2])
    }
}

/// "UnExp": darker than this many stops below clipping (shared by the histogram stats and the U overlay).
let underExposureEV: Float = -5

// MARK: - Clipping overlay

/// Red where a channel is at or above clipping, blue where every channel is below the under-exposure threshold.
/// Same thresholds and decode as the Exposure Stats panel.
enum ClippingOverlay {
    static func make(url: URL, adj: Adjust, over: Bool, under: Bool) -> NSImage? {
        let d = Decoded(url: url, adj: adj, scale: 0.25)
        guard let img = d.sceneLinear() else { return nil }
        return make(sceneLinear: img, url: url, over: over, under: under)
    }

    /// Same, from an already decoded scene-linear image (the shared per-photo bake).
    static func make(sceneLinear img: CIImage, url: URL, over: Bool, under: Bool) -> NSImage? {
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w > 4, h > 4 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: img.extent, format: .RGBAf, colorSpace: Engine.linear)
        return make(pixels: px, w: w, h: h, url: url, over: over, under: under)
    }

    static func make(pixels px: [Float], w: Int, h: Int, url: URL, over: Bool, under: Bool) -> NSImage? {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let underLevel = pow(2, underExposureEV)
        // E PZ 16-50mm on full frame: the black corners are not "under-exposed", they are outside the image circle.
        let disc = LensCircle.applies(to: url) ? LensCircle.discMask(lum: LensCircle.luminance(px, count: w * h), w: w, h: h) : nil
        for i in 0..<(w * h) {
            if let disc, !disc[i] { continue }
            let m = max(px[4 * i], px[4 * i + 1], px[4 * i + 2])
            if over, m >= 0.99 { out[4 * i] = 220; out[4 * i + 3] = 220 }
            else if under, m < underLevel { out[4 * i + 2] = 200; out[4 * i + 3] = 200 }
        }
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// A JPG with no RAW next to it, put through the same pipeline: decoded to linear light, then exposure and white
/// balance applied as filters (a RAW gets them in the decoder). There is no camera neutral to start from, so "as
/// shot" is 6500 K / 0: the picture as it is. Highlight recovery and scene-linear decoding don't apply — both
/// renders are the same, so log LUTs see a display picture (close enough to judge a look by).
enum BitmapPhoto {
    static let asShot: (temp: Float, tint: Float) = (6500, 0)

    static func isBitmap(_ url: URL) -> Bool { bitmapExtensions.contains(url.pathExtension.lowercased()) }

    static func longSide(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(w, h)
    }

    static func decode(_ url: URL, adj: Adjust, scale: Float) -> CIImage? {
        Storage.warmWholeFile(url)
        guard let img = scale < 0.999 ? reduced(url, scale: scale)
                : CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        return adjusted(img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY)), adj)
    }

    /// A smaller decode straight from ImageIO (the JPEG is scaled while it is decoded: fast, and a huge panorama
    /// never goes through Core Image at full size), turned upright, with clean edges.
    private static func reduced(_ url: URL, scale: Float) -> CIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let side = max(1, Int((Float(max(w, h)) * scale).rounded()))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,          // never the small embedded thumbnail
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }

    static func adjusted(_ img: CIImage, _ adj: Adjust) -> CIImage {
        var out = img
        if adj.ev != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": adj.ev]) }
        let t = adj.temp ?? asShot.temp, tint = adj.tint ?? asShot.tint
        if t != asShot.temp || tint != asShot.tint { out = whiteBalance(out, t, tint) }
        return out.cropped(to: img.extent)
    }

    /// The RAW sliders' sense: the light was `temp` K, so a higher number makes the picture warmer, + tint magenta.
    static func whiteBalance(_ img: CIImage, _ temp: Float, _ tint: Float) -> CIImage {
        img.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: CGFloat(temp), y: CGFloat(tint)),
            "inputTargetNeutral": CIVector(x: CGFloat(asShot.temp), y: CGFloat(asShot.tint)),
        ])
    }

    /// The temperature / tint that turn this linear colour grey: a coarse search, then a finer one around the best.
    static func neutral(for rgb: SIMD3<Float>) -> (temp: Float, tint: Float)? {
        guard rgb.min() > 0.0001 else { return nil }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let src = CIImage(color: CIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1,
                                         colorSpace: Engine.linear)!).cropped(to: unit)
        func cast(_ t: Float, _ ti: Float) -> Float {
            var px = [Float](repeating: 0, count: 4)
            Engine.ctx.render(whiteBalance(src, t, ti), toBitmap: &px, rowBytes: 16, bounds: unit, format: .RGBAf, colorSpace: Engine.linear)
            let m = (px[0] + px[1] + px[2]) / 3
            guard m > 0 else { return .infinity }
            return abs(px[0] / m - 1) + abs(px[1] / m - 1) + abs(px[2] / m - 1)
        }
        var best: (t: Float, ti: Float, e: Float) = (asShot.temp, asShot.tint, .infinity)
        var tStep: Float = 500, tiStep: Float = 10
        var tRange = stride(from: Float(2000), through: 12000, by: tStep), tiRange = stride(from: Float(-150), through: 150, by: tiStep)
        for _ in 0..<3 {
            for t in tRange { for ti in tiRange { let e = cast(t, ti); if e < best.e { best = (t, ti, e) } } }
            tStep /= 10; tiStep /= 10
            tRange = stride(from: max(2000, best.t - tStep * 10), through: min(12000, best.t + tStep * 10), by: tStep)
            tiRange = stride(from: max(-150, best.ti - tiStep * 10), through: min(150, best.ti + tiStep * 10), by: tiStep)
        }
        return best.e.isFinite ? (best.t.rounded(), best.ti.rounded()) : nil
    }

    /// Mean linear colour of a small square around (u, v) (fractions of the picture, v from the top).
    static func colour(_ url: URL, u: Double, vFromTop v: Double) -> SIMD3<Float>? {
        guard let img = decode(url, adj: Adjust(), scale: 0.25) else { return nil }
        let e = img.extent
        let r = CGRect(x: e.minX + u * e.width - 3, y: e.minY + (1 - v) * e.height - 3, width: 7, height: 7).intersection(e)
        guard !r.isEmpty else { return nil }
        return mean(img.cropped(to: r))
    }

    /// Mean linear colour of the mid tones (clipped and near-black pixels left out), for Auto WB.
    static func averageColour(_ url: URL) -> SIMD3<Float>? {
        guard let img = decode(url, adj: Adjust(), scale: 0.08) else { return nil }
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w > 4, h > 4 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: img.extent, format: .RGBAf, colorSpace: Engine.linear)
        var s = SIMD3<Float>(0, 0, 0), n = 0
        for i in 0..<(w * h) {
            let c = SIMD3<Float>(px[4 * i], px[4 * i + 1], px[4 * i + 2])
            guard c.max() < 0.95, c.max() > 0.01 else { continue }
            s += c; n += 1
        }
        return n > 100 ? s / Float(n) : nil
    }

    private static func mean(_ img: CIImage) -> SIMD3<Float>? {
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        var px = [Float](repeating: 0, count: 4)
        Engine.ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: Engine.linear)
        return SIMD3(px[0], px[1], px[2])
    }
}

// MARK: - Rotation

/// Quarter turns clockwise, and the EXIF / TIFF orientation codes they stand for (mirrored codes are left alone:
/// no camera writes them). The camera's own orientation is applied by the decoder; `rot` is on top of it.
enum Orientation {
    static let codes = [1, 6, 3, 8]

    static func quarter(_ code: Int) -> Int? { codes.firstIndex(of: code) }
    static func code(_ quarter: Int) -> Int { codes[((quarter % 4) + 4) % 4] }
    static func turn(_ rot: Int, by d: Int) -> Int { (((rot + d) % 4) + 4) % 4 }

    /// The file's own orientation in quarter turns (0 when it has none, or a mirrored one). Reads the header.
    static func camera(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let c = p[kCGImagePropertyOrientation] as? Int else { return 0 }
        return quarter(c) ?? 0
    }

    /// The turn a sidecar's tiff:Orientation asks for, on top of the camera's (0 for none, or a mirrored code).
    static func rot(sidecarCode: Int?, camera: Int) -> Int {
        guard let c = sidecarCode, let q = quarter(c) else { return 0 }
        return turn(q, by: -camera)
    }

    static func rotate(_ img: CIImage, _ rot: Int) -> CIImage {
        let o: CGImagePropertyOrientation
        switch turn(rot, by: 0) {
        case 1: o = .right          // 90° clockwise
        case 2: o = .down
        case 3: o = .left
        default: return img
        }
        let r = img.oriented(o)
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
    }

    static func rotate(_ cg: CGImage, _ rot: Int) -> CGImage? {
        let q = turn(rot, by: 0)
        guard q != 0 else { return cg }
        let w = q == 2 ? cg.width : cg.height, h = q == 2 ? cg.height : cg.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CG's origin is bottom-left: a clockwise turn of the picture is a negative angle here
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(q) * .pi / 2)
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
    }

    static func rotate(_ img: NSImage, _ rot: Int) -> NSImage {
        guard turn(rot, by: 0) != 0, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let r = rotate(cg, rot) else { return img }
        return NSImage(cgImage: r, size: .zero)
    }

    /// A point on the turned picture (0...1, v from the top) back on the camera's picture.
    static func unrotate(u: Double, v: Double, _ rot: Int) -> (Double, Double) {
        switch turn(rot, by: 0) {
        case 1: return (v, 1 - u)
        case 2: return (1 - u, 1 - v)
        case 3: return (1 - v, u)
        default: return (u, v)
        }
    }
}
