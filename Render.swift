import Foundation
import CoreImage
import ImageIO
import AppKit

// The per-photo render pipeline behind the single view.
//
// A RAW is decoded ONCE per (file, adjustments) at preview scale and "baked" into a bitmap; the preview, the
// 38 look thumbnails, the histogram and the clipping overlay are all derived from that bitmap instead of running
// the RAW decoder again for each of them (which is what made a photo cost ~2 s of GPU time before).
//
// Rendering runs on two serial dispatch queues: `preview` (user-interactive: the big picture, zoom) and `aux`
// (utility: histogram, thumbnails, overlay, EXIF, prefetch of the neighbours). Aux work waits whenever a preview is
// pending, so the picture always wins. Nothing blocking runs on Swift's cooperative thread pool any more.
// Every job carries a generation number: stale jobs are skipped the moment they are dequeued, so after a burst of
// arrow keys the queue drains to the newest request in microseconds.

/// A small thread-safe least-recently-used cache.
final class LRU<Key: Hashable, Value> {
    private var dict: [Key: Value] = [:]
    private var order: [Key] = []
    private let limit: Int
    private let lock = NSLock()

    init(limit: Int) { self.limit = limit }

    subscript(key: Key) -> Value? {
        get {
            lock.lock(); defer { lock.unlock() }
            guard let v = dict[key] else { return nil }
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
            return v
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            guard let newValue else { dict[key] = nil; return }
            dict[key] = newValue
            order.append(key)
            while order.count > limit, let old = order.first { order.removeFirst(); dict[old] = nil }
        }
    }

    func contains(_ key: Key) -> Bool { lock.lock(); defer { lock.unlock() }; return dict[key] != nil }
    func removeAll() { lock.lock(); dict = [:]; order = []; lock.unlock() }
}

/// One CIRAWFilter per photo, kept alive and re-parameterised for every adjustment instead of being created
/// again (creating one costs 40–50 ms before any pixel is decoded). Display and scene-linear renders come from
/// the same filter by toggling boost and gamut mapping. Every parameter is set before each render, under the lock.
final class RAWSource {
    let url: URL
    private let lock = NSLock()
    private var filter: CIRAWFilter?
    private var base: (exposure: Float, boost: Float, gamut: Bool, temp: Float, tint: Float)?
    private static let cache = LRU<URL, RAWSource>(limit: 4)
    private static let cacheLock = NSLock()

    private init(url: URL) { self.url = url }

    static func `for`(_ url: URL) -> RAWSource {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let s = cache[url] { return s }
        let s = RAWSource(url: url)
        cache[url] = s
        return s
    }

    /// Camera as-shot white balance (read before any custom WB is applied).
    var asShot: (temp: Float, tint: Float)? {
        if BitmapPhoto.isBitmap(url) { return BitmapPhoto.asShot }
        lock.lock(); defer { lock.unlock() }
        guard prepare() else { return nil }
        return base.map { ($0.temp, $0.tint) }
    }

    /// The picture's long side at full size, in pixels.
    var nativeLongSide: Int? {
        lock.lock(); defer { lock.unlock() }
        guard prepare(), let f = filter else { return nil }
        return Int(max(f.nativeSize.width, f.nativeSize.height))
    }

    private func prepare() -> Bool {
        if filter != nil { return true }
        Storage.warmWholeFile(url)                       // slow storage: one big read, not thousands of small ones
        guard let f = CIRAWFilter(imageURL: url) else { return false }
        filter = f
        base = (f.exposure, f.boostAmount, f.isGamutMappingEnabled, f.neutralTemperature, f.neutralTint)
        return true
    }

    /// Decodes with `adj` at `scale` and bakes the result to a flat bitmap while the parameters still hold.
    func bake(_ adj: Adjust, scale: Float, scene: Bool) -> CIImage? {
        if BitmapPhoto.isBitmap(url) { return BitmapPhoto.decode(url, adj: adj, scale: scale).flatMap(BakedPhoto.bake) }
        lock.lock(); defer { lock.unlock() }
        guard prepare(), let f = filter, let b = base else { return nil }
        f.scaleFactor = scale
        f.exposure = b.exposure + adj.ev
        f.extendedDynamicRangeAmount = 0
        f.boostAmount = scene ? 0 : b.boost
        f.isGamutMappingEnabled = scene ? false : b.gamut
        f.neutralTemperature = adj.temp ?? b.temp
        f.neutralTint = adj.tint ?? b.tint
        if #available(macOS 26, *), f.isHighlightRecoverySupported { f.isHighlightRecoveryEnabled = adj.highlightRecovery }
        guard let out = f.outputImage else { return nil }
        return BakedPhoto.bake(out)
    }
}

struct PhotoKey: Hashable {
    let url: URL
    let adj: Adjust
    /// The long side, in screen pixels, the fitted picture needs (0: the old fixed quarter size). Part of the key:
    /// a bigger window or another screen is a new render; the picture's own size is only known when it is decoded.
    var target: Int = 0
}

struct PreviewKey: Hashable {
    let photo: PhotoKey
    let lookID: Int
    let looksVersion: Int
    let over: Bool
    let under: Bool
}

/// One photo decoded at `scale` and baked to bitmaps, shared by everything that shows it.
final class BakedPhoto {
    let key: PhotoKey
    /// Decode scale: set from the picture's real size at the first decode (see `key.target`).
    private(set) var scale: Float
    private var scaleChosen = false
    /// Slider-drag frames: half the size, so dragging stays fluid on a big screen.
    private let draft: Bool
    private(set) var asShot: (temp: Float, tint: Float)?
    private var display: CIImage?
    private var scene: CIImage?
    private var smallDisplay: CIImage?
    private var smallScene: CIImage?
    private var histogram: HistogramData??
    private let lock = NSLock()
    static let thumbScale: Float = 0.06        // 360 px wide: the LUT panel's widest cell at 2x
    static let histScale: Float = 0.1

    init(key: PhotoKey, scale: Float = 0.25, draft: Bool = false) { self.key = key; self.scale = scale; self.draft = draft }

    /// The smallest decode that still fills `key.target` pixels (never below a quarter, never above full size).
    /// Called under the lock, off the main thread: finding the size opens the file.
    private func chooseScale() {
        guard !scaleChosen else { return }
        scaleChosen = true
        guard key.target > 0 else { return }
        let native = BitmapPhoto.isBitmap(key.url) ? BitmapPhoto.longSide(key.url) : RAWSource.for(key.url).nativeLongSide
        guard let n = native, n > 0 else { return }
        let want = Float(key.target) / Float(n) * (draft ? 0.5 : 1)
        scale = min(1, max(0.25, want))
    }

    /// Renders a Core Image graph to a half-float linear bitmap and wraps it as a new, flat image.
    static func bake(_ img: CIImage) -> CIImage? {
        guard let cg = Engine.ctx.createCGImage(img, from: img.extent, format: .RGBAh, colorSpace: Engine.linear) else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: Engine.linear])
    }

    private func decode(scene wantScene: Bool) -> CIImage? {
        chooseScale()
        let src = RAWSource.for(key.url)
        if asShot == nil { asShot = src.asShot }
        return src.bake(key.adj, scale: scale, scene: wantScene)
    }

    /// Display-referred (boost and gamut mapping on): the source of the PP display looks. Nil when the file cannot be decoded.
    func displayImage() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if display == nil { display = decode(scene: false) }
        return display
    }

    /// Scene-linear (no tone curve): the source of the log / LUT looks, the histogram and the clipping overlay.
    func sceneImage() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if scene == nil { scene = decode(scene: true) }
        return scene
    }

    func source(for look: PPLook) -> CIImage? { look.needsSceneLinear ? sceneImage() : displayImage() }

    private func shrink(_ img: CIImage, to target: Float) -> CIImage? {
        let s = CGFloat(target / scale)
        guard s < 1 else { return img }
        let small = img.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1.0])
        return BakedPhoto.bake(small.cropped(to: CGRect(x: 0, y: 0, width: (img.extent.width * s).rounded(.down), height: (img.extent.height * s).rounded(.down))))
    }

    /// Thumbnail-sized source for `look` (about 480 px wide), baked once per photo.
    func thumbSource(for look: PPLook) -> CIImage? {
        if look.needsSceneLinear {
            guard let full = sceneImage() else { return nil }
            lock.lock(); defer { lock.unlock() }
            if smallScene == nil { smallScene = shrink(full, to: BakedPhoto.thumbScale) }
            return smallScene
        } else {
            guard let full = displayImage() else { return nil }
            lock.lock(); defer { lock.unlock() }
            if smallDisplay == nil { smallDisplay = shrink(full, to: BakedPhoto.thumbScale) }
            return smallDisplay
        }
    }

    /// The look applied to the baked source (contrast grade first, as `Decoded.render` does).
    func render(_ look: PPLook, thumbnail: Bool = false) -> CGImage? {
        guard let src = thumbnail ? thumbSource(for: look) : source(for: look),
              let ci = Engine.apply(look, to: Engine.contrast(src, grade: key.adj.contrast)) else { return nil }
        return Engine.cgImage(ci, look)
    }

    func makeHistogram() -> HistogramData? {
        if let h = histogram { return h }
        guard let full = sceneImage() else { histogram = .some(nil); return nil }
        let s = CGFloat(BakedPhoto.histScale / scale)
        let small = s < 1 ? full.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": s, "inputAspectRatio": 1.0])
            .cropped(to: CGRect(x: 0, y: 0, width: (full.extent.width * s).rounded(.down), height: (full.extent.height * s).rounded(.down))) : full
        let h = HistogramData.make(sceneLinear: small, url: key.url)
        histogram = .some(h)
        return h
    }

    func makeOverlay(over: Bool, under: Bool) -> NSImage? {
        guard let full = sceneImage() else { return nil }
        return ClippingOverlay.make(sceneLinear: full, url: key.url, over: over, under: under)
    }
}

/// The camera's embedded JPEG, shown the instant a photo is selected while the real render runs.
enum EmbeddedPreview {
    static func load(_ url: URL, maxPixels: Int = 1600) -> NSImage? {
        Storage.warmHead(url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Two serial render queues with generation numbers; aux work yields to pending previews.
final class RenderScheduler {
    static let shared = RenderScheduler()

    private let previewQueue = DispatchQueue(label: "arwexport.render.preview", qos: .userInteractive)
    private let auxQueue = DispatchQueue(label: "arwexport.render.aux", qos: .utility)
    private let placeholderQueue = DispatchQueue(label: "arwexport.render.placeholder", qos: .userInteractive)
    private let cond = NSCondition()
    private var pendingPreviews = 0
    private var _previewGen = 0
    private var _photoGen = 0
    private var _zoomGen = 0
    private var neighbours: Set<URL> = []

    /// The photos worth prefetching right now (previous / next of the current one).
    func setNeighbours(_ urls: Set<URL>) { cond.lock(); neighbours = urls; cond.unlock() }
    func isNeighbour(_ url: URL) -> Bool { cond.lock(); defer { cond.unlock() }; return neighbours.contains(url) }

    /// The photo on screen, so a long read of a file nobody looks at any more can stop.
    private var onScreen: URL?
    func setOnScreen(_ url: URL?) { cond.lock(); onScreen = url; cond.unlock() }
    func isWanted(_ url: URL) -> Bool { cond.lock(); defer { cond.unlock() }; return url == onScreen || neighbours.contains(url) }

    @discardableResult func bumpZoom() -> Int { cond.lock(); defer { cond.unlock() }; _zoomGen += 1; return _zoomGen }

    /// A zoom render: preview priority, superseded by any newer zoom request.
    func zoom(gen: Int, _ work: @escaping () -> Void) {
        cond.lock(); pendingPreviews += 1; cond.unlock()
        previewQueue.async { [self] in
            defer { cond.lock(); pendingPreviews -= 1; cond.broadcast(); cond.unlock() }
            cond.lock(); let cur = _zoomGen; cond.unlock()
            if cur != gen { return }
            autoreleasepool(invoking: work)
        }
    }

    /// Bumped by every request for the big picture (new photo, new look, new adjustment, overlay toggle).
    var previewGen: Int { cond.lock(); defer { cond.unlock() }; return _previewGen }
    /// Bumped when the photo or its adjustments change (what the histogram and thumbnails depend on).
    var photoGen: Int { cond.lock(); defer { cond.unlock() }; return _photoGen }

    @discardableResult func bumpPreview() -> Int { cond.lock(); defer { cond.unlock() }; _previewGen += 1; return _previewGen }
    @discardableResult func bumpPhoto() -> (preview: Int, photo: Int) {
        cond.lock(); defer { cond.unlock() }
        _previewGen += 1; _photoGen += 1
        return (_previewGen, _photoGen)
    }

    /// Runs `work` on the preview queue unless a newer preview was requested meanwhile.
    func preview(gen: Int, _ work: @escaping () -> Void) {
        cond.lock(); pendingPreviews += 1; cond.unlock()
        previewQueue.async { [self] in
            defer { cond.lock(); pendingPreviews -= 1; cond.broadcast(); cond.unlock() }
            if previewGen != gen { return }
            autoreleasepool(invoking: work)
        }
    }

    /// Runs `work` on the aux queue after any pending preview, unless `stillWanted` says no by then.
    func aux(stillWanted: @escaping () -> Bool, _ work: @escaping () -> Void) {
        auxQueue.async { [self] in
            cond.lock()
            while pendingPreviews > 0 { cond.wait() }
            cond.unlock()
            guard stillWanted() else { return }
            autoreleasepool(invoking: work)
        }
    }

    func aux(photoGen gen: Int, _ work: @escaping () -> Void) { aux(stillWanted: { [self] in photoGen == gen }, work) }

    /// Waits for pending previews (called between the items of a long aux job).
    func yieldToPreview() {
        cond.lock()
        while pendingPreviews > 0 { cond.wait() }
        cond.unlock()
    }

    /// The embedded JPEG placeholder: its own queue, never behind a render.
    func placeholder(_ work: @escaping () -> Void) { placeholderQueue.async { autoreleasepool(invoking: work) } }
}
