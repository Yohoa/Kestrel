import Foundation
import CoreImage

struct HistogramData {
    static let bins = 108
    static let evMin: Float = -9, evMax: Float = 3
    static let underEV: Float = underExposureEV

    var curves: [[Float]]                // 3 channels, 0...1 (square-root scaled)
    var under: [Float]                   // % of pixels per channel
    var over: [Float]                    // % of pixels per channel at or above clipping
    var circleMasked = false             // true: black lens corners were left out (E PZ 16-50mm, full frame)

    static func make(url: URL, adj: Adjust) -> HistogramData? {
        let d = Decoded(url: url, adj: adj, scale: 0.1)
        guard let img = d.sceneLinear() else { return nil }
        return make(sceneLinear: img, url: url)
    }

    /// Same, from an already decoded scene-linear image (the shared per-photo bake, downscaled to ~0.1).
    static func make(sceneLinear img: CIImage, url: URL) -> HistogramData? {
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w > 4, h > 4 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: img.extent, format: .RGBAf, colorSpace: Engine.linear)
        return make(pixels: px, w: w, h: h, url: url)
    }

    static func make(pixels px: [Float], w: Int, h: Int, url: URL) -> HistogramData? {
        var counts = [[Float]](repeating: [Float](repeating: 0, count: bins), count: 3)
        var under = [Float](repeating: 0, count: 3), over = [Float](repeating: 0, count: 3)
        let span = evMax - evMin
        let disc = LensCircle.applies(to: url) ? LensCircle.discMask(lum: LensCircle.luminance(px, count: w * h), w: w, h: h) : nil
        var counted = 0
        for i in 0..<(w * h) {
            if let disc, !disc[i] { continue }
            counted += 1
            for c in 0..<3 {
                let v = px[4 * i + c]
                let ev = log2(max(v, 1e-6))
                let idx = min(max(Int((ev - evMin) / span * Float(bins)), 0), bins - 1)
                counts[c][idx] += 1
                if ev < underEV { under[c] += 1 }
                if v >= 0.99 { over[c] += 1 }
            }
        }
        let n = Float(max(counted, 1))
        let peak = max(counts.flatMap { $0 }.max() ?? 1, 1)
        return HistogramData(curves: counts.map { $0.map { sqrt($0 / peak) } },
                             under: under.map { $0 / n * 100 }, over: over.map { $0 / n * 100 }, circleMasked: disc != nil)
    }
}
