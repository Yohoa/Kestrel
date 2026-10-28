import Foundation
import CoreImage

// Auto exposure: suggests how many stops to add to a RAW so it opens at a sensible brightness.
// Everything here is a pure function of the pixels it is given, so it can run on any thread.

/// How Auto EV reads the frame. The raw values are stored in UserDefaults and taken by the CLI (`--metering`).
enum MeteringMode: String, CaseIterable, Identifiable {
    case matrix
    case hybrid
    case average
    case centerWeighted = "center-weighted"
    case highlightSafe = "highlight-safe"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matrix: return "Matrix (zones, subject first)"
        case .hybrid: return "Hybrid (average, spares highlights)"
        case .average: return "Average (whole frame)"
        case .centerWeighted: return "Center-weighted"
        case .highlightSafe: return "Highlight-safe (ETTR)"
        }
    }
}

enum Metering {
    struct Result {
        let ev: Float            // stops to add on top of baseEV
        let circleMasked: Bool   // true: the black corners outside the lens circle were left out
    }

    /// The Exposure slider's range and step (ContentView+Center).
    private static let evRange: ClosedRange<Float> = -4...7
    private static let evStep: Float = 0.1
    /// Scene-linear 18 % grey: where the typical tones of the scene should land.
    private static let midGrey: Float = 0.18
    /// ~600 px wide for a 24 MP RAW: plenty for metering, and fast in batch runs.
    private static let decodeScale: Float = 0.1
    /// Below this the brightest tones are at sensor noise (lens cap, failed decode): nothing to meter.
    private static let blackFrameLevel: Float = 1.0 / 2048

    static func autoEV(url: URL, baseEV: Float, mode: MeteringMode, maskLensCircle: Bool = true) -> Float? {
        autoEVResult(url: url, baseEV: baseEV, mode: mode, maskLensCircle: maskLensCircle)?.ev
    }

    /// Meters the scene-linear decode (developed at `baseEV`) and returns the stops to add on top of it.
    static func autoEVResult(url: URL, baseEV: Float, mode: MeteringMode, maskLensCircle: Bool = true) -> Result? {
        let d = Decoded(url: url, adj: Adjust(ev: baseEV, temp: nil, tint: nil, highlightRecovery: true), scale: decodeScale)
        guard let img = d.sceneLinear() else { return nil }
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard w >= 32, h >= 32 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        Engine.ctx.render(img, toBitmap: &px, rowBytes: w * 16, bounds: img.extent, format: .RGBAf, colorSpace: Engine.linear)
        return meter(pixels: px, w: w, h: h, mode: mode, lensCircle: maskLensCircle && LensCircle.applies(to: url))
    }

    // MARK: - Measurement

    /// The metered pixels: luminance and brightest channel per pixel, plus which ones count.
    private struct Frame {
        let w: Int, h: Int
        let lum: [Float]
        let peak: [Float]          // max(R, G, B): what clips first
        let valid: [Bool]          // inside the lens disc (all true without one)
        let validCount: Int

        /// Normalised position of pixel i: (0, 0) is the centre, ±1 the frame edges. Row 0 is the top.
        func position(_ i: Int) -> (x: Float, y: Float) {
            let x = Float(i % w) + 0.5, y = Float(i / w) + 0.5
            return (2 * x / Float(w) - 1, 2 * y / Float(h) - 1)
        }

        /// Values of `a` over the valid pixels, sorted ascending (for percentiles).
        func sortedValid(_ a: [Float]) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(validCount)
            for i in 0..<a.count where valid[i] { out.append(a[i]) }
            out.sort()
            return out
        }
    }

    private static func meter(pixels px: [Float], w: Int, h: Int, mode: MeteringMode, lensCircle: Bool) -> Result? {
        let n = w * h
        let lum = LensCircle.luminance(px, count: n)
        var peak = [Float](repeating: 0, count: n)
        for i in 0..<n { peak[i] = max(px[4 * i], px[4 * i + 1], px[4 * i + 2], 0) }

        // Lens circle: meter only what is safely inside the lit disc, otherwise the black corners
        // read as dark scene and Auto EV over-exposes. Too small a disc falls back to the full frame.
        var valid = [Bool](repeating: true, count: n)
        var validCount = n
        var masked = false
        if lensCircle, let disc = LensCircle.detect(lum: lum, w: w, h: h) {
            let inner = disc.mask(w: w, h: h, margin: 0.07)
            let count = inner.reduce(0) { $0 + ($1 ? 1 : 0) }
            if count >= max(1000, n / 10) { valid = inner; validCount = count; masked = true }
        }

        let f = Frame(w: w, h: h, lum: lum, peak: peak, valid: valid, validCount: validCount)
        let sortedPeak = f.sortedValid(peak)
        guard let top = percentile(sortedPeak, 0.99), top >= blackFrameLevel else { return nil }

        let ev: Float?
        switch mode {
        case .matrix: ev = matrix(f, sortedPeak: sortedPeak)
        case .hybrid: ev = hybrid(f, sortedPeak: sortedPeak)
        case .average: ev = logMean(f) { _ in 1 }.map { log2(midGrey) - $0 }
        case .centerWeighted: ev = centerWeighted(f)
        case .highlightSafe: ev = highlightSafe(sortedPeak: sortedPeak)
        }
        guard var ev, ev.isFinite else { return nil }
        // Safety net for every mode: never push the brightest 1 % more than 3 stops past clipping. A flash
        // portrait on a black night background would otherwise get a wild boost from the background alone.
        ev = min(ev, log2(8 / top))
        let snapped = ((ev / evStep).rounded() * evStep).clamped(to: evRange)
        return Result(ev: snapped, circleMasked: masked)
    }

    /// Weighted mean of log2 luminance over the valid pixels (the scene's "key"). Log averaging keeps a few
    /// very bright pixels from dominating. Pixels far below the highlights are floored there, so deep black
    /// shadows cannot pull the reading down without limit; the floor is relative, so the result shifts by
    /// exactly the exposure change when the RAW is brighter or darker.
    private static func logMean(_ f: Frame, weight: (Int) -> Float) -> Float? {
        let sortedLum = f.sortedValid(f.lum)
        guard let bright = percentile(sortedLum, 0.98) else { return nil }
        let floor = max(bright / 1024, 1e-7)
        var sum: Double = 0, total: Double = 0
        for i in 0..<f.lum.count where f.valid[i] {
            let wt = Double(weight(i))
            guard wt > 0 else { continue }
            sum += wt * Double(log2(max(f.lum[i], floor)))
            total += wt
        }
        guard total > 0 else { return nil }
        return Float(sum / total)
    }

    /// How far (in stops) the given percentile of the brightest channel would sit above `ceiling`
    /// after adding `ev`. Positive means it would clip.
    private static func overshoot(_ sortedPeak: [Float], at p: Float, ev: Float, ceiling: Float) -> Float {
        guard let v = percentile(sortedPeak, p), v > 0 else { return 0 }
        return log2(v) + ev - log2(ceiling)
    }

    // MARK: - Modes

    /// Evaluative: the frame is split into zones and the main subject is taken to be what the central zones
    /// show (weighted towards the middle and a little below it, where subjects usually sit). Zones far brighter
    /// than the subject (sky, lamps, windows) or far darker (a night background) fade out, so neither drags the
    /// exposure. Severe highlight clipping is then held back, within limits.
    private static func matrix(_ f: Frame, sortedPeak: [Float]) -> Float? {
        let cols = 8, rows = 6
        let sortedLum = f.sortedValid(f.lum)
        guard let bright = percentile(sortedLum, 0.98) else { return nil }
        let floor = max(bright / 1024, 1e-7)

        var sum = [Double](repeating: 0, count: cols * rows)
        var count = [Int](repeating: 0, count: cols * rows)
        var area = [Int](repeating: 0, count: cols * rows)
        for i in 0..<f.lum.count {
            let z = min((i / f.w) * rows / f.h, rows - 1) * cols + min((i % f.w) * cols / f.w, cols - 1)
            area[z] += 1
            guard f.valid[i] else { continue }
            sum[z] += Double(log2(max(f.lum[i], floor)))
            count[z] += 1
        }

        // Zones mostly outside the lens disc are skipped rather than judged on a sliver.
        var zones: [(level: Float, place: Float)] = []
        for z in 0..<(cols * rows) where count[z] > 0 && count[z] * 10 >= area[z] * 3 {
            let x = (Float(z % cols) + 0.5) / Float(cols) * 2 - 1
            let y = (Float(z / cols) + 0.5) / Float(rows) * 2 - 1 - 0.1
            // A broad bump centred a little below the middle, never quite zero at the edges.
            let place = 0.15 + exp(-(x * x + y * y) / (2 * 0.5 * 0.5))
            zones.append((Float(sum[z] / Double(count[z])), place))
        }
        guard !zones.isEmpty else { return nil }
        // The subject's level: a median that leans hard on the central zones.
        let subject = weightedMedian(zones.map { ($0.level, $0.place * $0.place) })

        var acc: Float = 0, total: Float = 0
        for z in zones {
            let d = z.level - subject
            let tone: Float = d > 2 ? exp2(-1.5 * (d - 2)) : d < -2 ? exp2(d + 2) : 1
            acc += z.place * tone * z.level
            total += z.place * tone
        }
        guard total > 0 else { return nil }
        let ev = log2(midGrey) - acc / total

        // Protect highlights from severe clipping: the top 0.5 % may go half a stop over; the pull-back is
        // limited so a sun or a lamp in the frame cannot sink the whole picture.
        let over = overshoot(sortedPeak, at: 0.995, ev: ev, ceiling: 1.41)
        return ev - min(max(over, 0), 2)
    }

    /// Plain whole-frame average, held back when it would push the brightest 1 % far (> 1.5 stops) past clipping.
    private static func hybrid(_ f: Frame, sortedPeak: [Float]) -> Float? {
        guard let key = logMean(f, weight: { _ in 1 }) else { return nil }
        let ev = log2(midGrey) - key
        let over = overshoot(sortedPeak, at: 0.99, ev: ev, ceiling: 2.83)
        return ev - min(max(over, 0), 3)
    }

    /// The middle counts most; influence falls off as a smooth Gaussian towards the edges, which keep a small share.
    private static func centerWeighted(_ f: Frame) -> Float? {
        let aspect = Float(f.w) / Float(f.h)
        let norm = 1 + aspect * aspect   // squared half-diagonal in these units
        let key = logMean(f) { i in
            let p = f.position(i)
            let r2 = (p.x * p.x * aspect * aspect + p.y * p.y) / norm   // 0 centre ... 1 corner
            return 0.05 + exp(-r2 / (2 * 0.3 * 0.3))
        }
        return key.map { log2(midGrey) - $0 }
    }

    /// Expose to the right: lift until the brightest meaningful highlights (the top 0.2 % of pixels are taken
    /// as specular and ignored) sit just below clipping in their brightest channel.
    private static func highlightSafe(sortedPeak: [Float]) -> Float? {
        guard let hi = percentile(sortedPeak, 0.998), hi > 0 else { return nil }
        return log2(0.97 / hi)
    }

    // MARK: - Helpers

    private static func percentile(_ sorted: [Float], _ p: Float) -> Float? {
        guard !sorted.isEmpty else { return nil }
        let i = Int((Float(sorted.count - 1) * p).rounded())
        return sorted[min(max(i, 0), sorted.count - 1)]
    }

    /// The value where the cumulative weight reaches half.
    private static func weightedMedian(_ v: [(value: Float, weight: Float)]) -> Float {
        let s = v.sorted { $0.value < $1.value }
        let half = s.reduce(0) { $0 + $1.weight } / 2
        var run: Float = 0
        for e in s { run += e.weight; if run >= half { return e.value } }
        return s.last?.value ?? 0
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

// MARK: - Lens circle

/// The Sony E PZ 16-50mm is an APS-C lens; on a full-frame body shooting uncropped it draws a lit disc with
/// black corners whose size changes with focal length. The disc is found from the pixels, not the metadata.
enum LensCircle {
    /// A centred disc, in bitmap pixels.
    struct Disc {
        let cx: Float, cy: Float, radius: Float

        /// True inside the disc shrunk by `margin` (a fraction of the radius), which leaves out its soft rim.
        func mask(w: Int, h: Int, margin: Float) -> [Bool] {
            let r = radius * (1 - margin), r2 = r * r
            var m = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                let dy = Float(y) + 0.5 - cy
                for x in 0..<w {
                    let dx = Float(x) + 0.5 - cx
                    m[y * w + x] = dx * dx + dy * dy <= r2
                }
            }
            return m
        }
    }

    /// Only this lens on a full-frame body (A7C: 6000 px wide) can show the circle; APS-C crop mode (~3936 px) can't.
    static func applies(to url: URL) -> Bool {
        let info = ExifInfo.lensAndWidth(url)
        let lens = info.lens.uppercased()
        return lens.contains("PZ") && lens.contains("16-50") && info.width >= 5000
    }

    /// Row-major, true for pixels inside the lit disc; nil when there are no black corners or they can't be told apart.
    static func discMask(lum: [Float], w: Int, h: Int) -> [Bool]? {
        detect(lum: lum, w: w, h: h)?.mask(w: w, h: h, margin: 0.015)
    }

    /// Rec.709 luminance of an interleaved RGBA float bitmap; negative components count as 0.
    static func luminance(_ px: [Float], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<min(count, px.count / 4) {
            out[i] = 0.2126 * max(px[4 * i], 0) + 0.7152 * max(px[4 * i + 1], 0) + 0.0722 * max(px[4 * i + 2], 0)
        }
        return out
    }

    /// Finds the image circle. The optical axis is the frame centre, so the black outside is purely radial:
    /// every pixel beyond some radius is near sensor black, at all angles. The radial profile of "dark" pixels
    /// gives that radius. Black here means 6 stops under the centre, which vignetting never reaches, and the
    /// band just inside the edge must still be lit, which a dark surround in a night scene usually isn't.
    static func detect(lum: [Float], w: Int, h: Int) -> Disc? {
        guard w >= 32, h >= 32, lum.count >= w * h else { return nil }
        let cx = Float(w) / 2, cy = Float(h) / 2
        let halfDiag = (cx * cx + cy * cy).squareRoot()

        // Reference level: the median of the middle ninth of the frame, which is always inside the disc.
        var centre: [Float] = []
        centre.reserveCapacity(w * h / 9 + w)
        for y in (h / 3)..<(2 * h / 3) { for x in (w / 3)..<(2 * w / 3) { centre.append(lum[y * w + x]) } }
        centre.sort()
        let level = centre[centre.count / 2]
        guard level >= 1.0 / 256 else { return nil }       // too dark to tell black corners from a night scene
        let black = level / 64

        // Radial profile in 1 px rings: how many pixels per ring, how many of them black.
        let rings = Int(halfDiag) + 2
        var total = [Int](repeating: 0, count: rings), dark = [Int](repeating: 0, count: rings)
        var ringLum = [[Float]](repeating: [], count: rings)
        for y in 0..<h {
            let dy = Float(y) + 0.5 - cy
            for x in 0..<w {
                let dx = Float(x) + 0.5 - cx
                let r = Int((dx * dx + dy * dy).squareRoot())
                let v = lum[y * w + x]
                total[r] += 1
                if v < black { dark[r] += 1 }
                ringLum[r].append(v)
            }
        }

        // Walk in from the corners while rings are (almost) all black; the first lit ring is the disc edge.
        var edge = rings
        while edge > 0 {
            let r = edge - 1
            if total[r] > 0, dark[r] * 10 < total[r] * 9 { break }
            edge -= 1
        }
        let radius = Float(edge)
        guard radius < 0.97 * halfDiag, radius > 0.5 * min(cx, cy) else { return nil }   // no corners / not a lens disc
        let outside = total[edge...].reduce(0, +)
        guard outside * 50 >= w * h else { return nil }     // the disc would cover almost the whole frame

        // The edge must be abrupt: a band 5-12 % inside it is still lit (vignetting or a dark surround fade instead).
        var band: [Float] = []
        for r in Int(radius * 0.88)..<max(Int(radius * 0.95), Int(radius * 0.88) + 1) where r < rings { band += ringLum[r] }
        guard !band.isEmpty else { return nil }
        band.sort()
        guard band[band.count / 2] >= level / 16 else { return nil }

        return Disc(cx: cx, cy: cy, radius: radius)
    }
}
