import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Data for the panels

/// Embedded-preview thumbnails for the filmstrip and the grid, at most four being read at a time.
@MainActor
final class ThumbStore: ObservableObject {
    @Published var images: [URL: NSImage] = [:]
    @Published var hovered: URL?                       // advanced selection: shows the checkbox under the mouse
    private var requested: Set<URL> = []
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 6
        q.qualityOfService = .utility
        return q
    }()

    private var ops: [URL: Operation] = [:]

    func ensure(_ url: URL) {
        guard images[url] == nil, requested.insert(url).inserted else { return }
        let op = BlockOperation { [weak self] in
            let img = ThumbStore.makeThumb(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ops[url] = nil
                    if let img { self?.arrived(url, img) } else { self?.requested.remove(url) }
                }
            }
        }
        op.queuePriority = .high                     // the cells that just came into view go first
        ops.values.forEach { $0.queuePriority = .normal }
        ops[url] = op
        queue.addOperation(op)
    }

    /// The cell scrolled away before its thumbnail was read: don't read it (it is asked for again if it comes back).
    func forget(_ url: URL) {
        guard let op = ops.removeValue(forKey: url), !op.isExecuting, !op.isFinished else { return }
        op.cancel()
        requested.remove(url)
    }

    /// Arrivals are published together every 50 ms: one redraw of the visible cells instead of one per thumbnail.
    private var pending: [URL: NSImage] = [:]
    private func arrived(_ url: URL, _ img: NSImage) {
        let first = pending.isEmpty
        pending[url] = img
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.images.merge(self.pending) { _, new in new }
                self.pending = [:]
            }
        }
    }

    nonisolated static func makeThumb(_ url: URL) -> NSImage? {
        let slow = Storage.isSlow(url)
        if slow {
            if let c = LocalCache.thumb(url) { return c }
            RenderScheduler.shared.yieldToPreview()      // the photo on screen is read first
            Storage.warmHead(url)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if slow { LocalCache.storeThumb(cg, for: url) }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// A directory in the folder tree. Children are listed in the background the first time a row shows the folder:
/// listing Desktop, Documents or a cloud folder can wait on a macOS privacy prompt, and that must not freeze the window.

extension Model {
    /// After any develop change: re-render everything that shows the picture.
    func developChanged() { refreshAll() }
}

func labelColor(_ name: String?) -> Color {
    switch name {
    case "Red": return .red
    case "Yellow": return .yellow
    case "Green": return .green
    case "Blue": return .blue
    case "Purple": return .purple
    default: return .clear
    }
}

// MARK: - Badges shared by filmstrip and grid cells

struct PhotoBadges: View {
    let photo: Photo
    let isSelected: Bool

    var body: some View {
        ZStack {
            if photo.isRejected {
                Color.black.opacity(0.45)
                Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.red.opacity(0.9))
            }
            VStack {
                HStack {
                    if photo.kind != "ARW" { badge(photo.kind) }
                    Spacer()
                    if photo.unreadable { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).background(Circle().fill(.white).padding(2)) }
                }
                Spacer()
                HStack(spacing: 3) {
                    if photo.rating > 0 { badge(String(repeating: "★", count: photo.rating), color: .orange) }
                    Spacer()
                }
            }
            .padding(3)
            if photo.label != nil {
                VStack { Spacer(); Rectangle().fill(labelColor(photo.label)).frame(height: 4) }
            }
        }
    }

    func badge(_ text: String, color: Color = .white) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 3).background(Color.black.opacity(0.55)).clipShape(Capsule())
    }
}

/// Advanced selection mode's checkbox in a thumbnail's top-right corner: always shown on marked photos,
/// on the others while the mouse is over them.
struct MarkBox: View {
    let photo: Photo
    let isSelected: Bool
    let enabled: Bool
    let onToggle: () -> Void
    let hovered: Bool

    var body: some View {
        if enabled && (isSelected || hovered) {
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14)).foregroundStyle(isSelected ? Color.accentColor : .white)
                    .background(Color.black.opacity(0.35).clipShape(RoundedRectangle(cornerRadius: 3)))
            }
            .buttonStyle(.plain).padding(3)
            .help(isSelected ? "Unmark" : "Mark for group operations")
        }
    }
}

/// Re-evaluates `content` when `object` changes — for state the enclosing view doesn't observe itself
/// (the column widths, so a splitter drag doesn't redraw everything that watches the model).
/// A ⋯ button that slides its tools out over the title while the pointer is on it (a click opens it too), and
/// tucks them away a moment after the pointer leaves — not while one of their menus is open.
struct HoverOverflow<Content: View>: View {
    var active = false                       // something behind it is switched on: tint the ⋯
    @ViewBuilder let content: Content
    final class Box: ObservableObject { @Published var open = false; var work: DispatchWorkItem? }
    @StateObject private var box = Box()            // (plain swiftc build: no @State macro)
    private var open: Bool { box.open }

    var body: some View {
        Button { set(true) } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Name filter, sort, refresh, options")
        .opacity(open ? 0 : 1)
        .overlay(alignment: .trailing) {
            if open {
                HStack(spacing: 10) { content }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .fixedSize()
                    .onHover { hover($0) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onHover { hover($0) }
    }

    private func hover(_ inside: Bool) {
        box.work?.cancel()
        if inside { let w = DispatchWorkItem { set(true) }; box.work = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w); return }
        let w = DispatchWorkItem { close() }
        box.work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    private func close() {
        // a menu from the strip is open (its event-tracking loop is running): check again once it has closed
        if RunLoop.current.currentMode == .eventTracking {
            let w = DispatchWorkItem { close() }; box.work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w); return
        }
        set(false)
    }

    private func set(_ v: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { box.open = v }
    }
}

/// A slider's value as text: click it and type a number (the unit is optional), Return or clicking away applies
/// it, Esc cancels. Out-of-range numbers are clamped. Press on it and drag up (or right) to raise it, down (or
/// left) to lower it, a `dragStep` every few points; ⌥ is ten times finer, ⇧ ten times coarser. Double-click resets.
struct ValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var dragStep: Double? = nil
    let format: String
    let unit: String
    var onDragBegin: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onReset: (() -> Void)? = nil
    let onCommit: () -> Void
    final class Box: ObservableObject { @Published var draft = ""; @Published var hovered = false; var dragValue = 0.0 }
    @StateObject private var box = Box()
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: Binding(get: { focused ? box.draft : String(format: format, value) + unit }, set: { box.draft = $0 }))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.caption.monospacedDigit())
            .focused($focused)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(focused ? 0.12 : (box.hovered ? 0.07 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(focused ? 0.8 : 0)))
            .frame(width: 60)
            .overlay {
                // not while typing: then clicks place the text cursor
                if !focused {
                    DragToAdjust(onBegin: { box.dragValue = value; onDragBegin() },
                                 onChange: { points, mods in drag(points, mods) },
                                 onEnd: { onDragEnd() },
                                 onClick: { focused = true },
                                 onDoubleClick: { if let onReset { focused = false; onReset() } })
                }
            }
            .onHover { box.hovered = $0 }
            .help("Drag up or down to change (⌥ finer, ⇧ faster), click to type" + (onReset != nil ? ", double-click to reset" : ""))
            .onChange(of: focused) { _, f in
                if f { box.draft = String(format: format, value).replacingOccurrences(of: "+", with: "") } else { commit() }
            }
            .onSubmit { focused = false }
            .onExitCommand { box.draft = ""; focused = false }
    }

    /// Three points of movement per step.
    private func drag(_ points: CGFloat, _ mods: NSEvent.ModifierFlags) {
        let base = dragStep ?? step
        let s = mods.contains(.option) ? base / 10 : mods.contains(.shift) ? base * 10 : base
        box.dragValue = min(max(box.dragValue + Double(points) / 3 * s, range.lowerBound), range.upperBound)
        let v = min(max((box.dragValue / s).rounded() * s, range.lowerBound), range.upperBound) + 0   // + 0: no "−0.00"
        if v != value { value = v }
    }

    private func commit() {
        // accept "−1,5", "+0.3 EV", "6500K" …
        let cleaned = box.draft.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
            .filter { "0123456789.-+".contains($0) }
        box.draft = ""
        guard let v = Double(cleaned) else { return }
        let c = min(max((v / step).rounded() * step, range.lowerBound), range.upperBound)
        if c != value { value = c; onCommit() }
    }
}

/// Catches a press on a value field: a drag reports its movement (up and right positive), a press that does not move
/// is a click, two quick ones a double-click. Mouse, trackpad and the Pencil on a Sidecar iPad arrive as mouse events.
/// Fingers on a Sidecar iPad (and two fingers on a trackpad) arrive as scrolling instead: that adjusts too, in the
/// direction the fingers move, one gesture being one drag. A mouse wheel is left to scroll what is around.
/// Shows the resize pointer over the field.
struct DragToAdjust: NSViewRepresentable {
    var cursor: NSCursor = .resizeUpDown
    var onBegin: () -> Void
    var onChange: (CGFloat, NSEvent.ModifierFlags) -> Void
    var onEnd: () -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> V { let v = V(); update(v); return v }
    func updateNSView(_ v: V, context: Context) { update(v) }
    private func update(_ v: V) {
        v.onBegin = onBegin; v.onChange = onChange; v.onEnd = onEnd; v.onClick = onClick; v.onDoubleClick = onDoubleClick
        if v.cursor !== cursor { v.cursor = cursor; v.window?.invalidateCursorRects(for: v) }
    }

    final class V: NSView {
        var onBegin: () -> Void = {}
        var onChange: (CGFloat, NSEvent.ModifierFlags) -> Void = { _, _ in }
        var onEnd: () -> Void = {}
        var onClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var cursor: NSCursor = .resizeUpDown
        private var start: NSPoint?, last = NSPoint.zero, dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

        override func mouseDown(with e: NSEvent) {
            if e.clickCount >= 2 { start = nil; onDoubleClick(); return }
            start = e.locationInWindow; last = start!; dragging = false
        }

        override func mouseDragged(with e: NSEvent) {
            guard let s = start else { return }
            let p = e.locationInWindow
            if !dragging {
                guard hypot(p.x - s.x, p.y - s.y) >= 3 else { return }      // a wobbly click is still a click
                dragging = true
                onBegin()
            }
            onChange((p.y - last.y) + (p.x - last.x), e.modifierFlags)       // window coordinates: y grows upwards
            last = p
        }

        override func mouseUp(with e: NSEvent) {
            guard start != nil else { return }
            start = nil
            if dragging { dragging = false; onEnd() } else { onClick() }
        }

        private var scrolling = false
        private var scrollEnd: DispatchWorkItem?

        override func scrollWheel(with e: NSEvent) {
            // a wheel notch, or the fling after the fingers lift: not an adjustment
            guard e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else {
                if e.momentumPhase.isEmpty { super.scrollWheel(with: e) }
                return
            }
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { finishScroll(); return }
            if !scrolling { scrolling = true; onBegin() }
            // with natural scrolling the deltas follow the content, not the fingers
            let k: CGFloat = e.isDirectionInvertedFromDevice ? -1 : 1
            onChange((e.scrollingDeltaY + e.scrollingDeltaX) * k, e.modifierFlags)
            if e.phase.isEmpty {                 // no gesture phases (some touch input): end after a pause
                scrollEnd?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.finishScroll() }
                scrollEnd = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        }

        private func finishScroll() {
            scrollEnd?.cancel(); scrollEnd = nil
            guard scrolling else { return }
            scrolling = false
            onEnd()
        }
    }
}

/// The zoomed picture. It observes only the zoom state, so pinching and panning redraw this view alone.
/// The zoomed picture. Drawn by a Core Animation layer, not a SwiftUI Image: at 150–400 % the image is a view of
/// many thousand points, and SwiftUI animated the zoom back to fit by redrawing it on the CPU every frame (the window
/// froze for seconds). A layer is scaled and moved by the GPU, animated or not.
struct ZoomedPicture: View {
    @ObservedObject var zoom: ZoomState
    let image: NSImage
    let overlay: NSImage?
    let fullSize: CGSize                     // points at 100 %
    let sharp: Bool
    let busy: Bool

    var body: some View {
        // Sized from the long side and the image's own shape: right after a photo change the shown image (the
        // previous render or a preview) may not match the new photo's EXIF size yet, and must never be stretched.
        let long = max(fullSize.width, fullSize.height) * zoom.scale
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.5
        let w = aspect >= 1 ? long : long * aspect, h = aspect >= 1 ? long / aspect : long
        // past 100 % the pixels show as squares; a stand-in preview is smoothed
        ZoomLayer(image: image, overlay: overlay, size: CGSize(width: w, height: h), offset: zoom.offset,
                  pixels: sharp && zoom.scale > 1.01)
            .overlay(alignment: .topTrailing) {
                if busy { ProgressView().controlSize(.small).padding(10).glassCapsule().padding(8) }
            }
    }
}

struct ZoomLayer: NSViewRepresentable {
    let image: NSImage
    let overlay: NSImage?
    let size: CGSize
    let offset: CGSize
    let pixels: Bool

    func makeNSView(context: Context) -> ZoomLayerView { ZoomLayerView() }

    func updateNSView(_ v: ZoomLayerView, context: Context) {
        // a SwiftUI animation (smart zoom, back to fit) becomes the same spring in Core Animation
        let animated = context.transaction.animation != nil && !context.transaction.disablesAnimations
        v.update(image: image, overlay: overlay, size: size, offset: offset, pixels: pixels, animated: animated)
    }
}

final class ZoomLayerView: NSView {
    private let picture = CALayer(), over = CALayer()
    private var image: NSImage?, overlayImage: NSImage?
    private var size = CGSize.zero, offset = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let still: [String: CAAction] = ["contents": NSNull(), "magnificationFilter": NSNull()]   // swap, never cross-fade
        // linear, not trilinear: trilinear makes Core Animation build mipmaps of the full-size render the moment the
        // picture shrinks below 1:1, which dropped frames at the start of every zoom back to fit
        for l in [picture, over] { l.contentsGravity = .resize; l.minificationFilter = .linear; l.actions = still }
        over.magnificationFilter = .nearest
        layer?.addSublayer(picture)
        picture.addSublayer(over)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // clicks, drags and wheel go to the views around it

    func update(image: NSImage, overlay: NSImage?, size: CGSize, offset: CGSize, pixels: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if image !== self.image { self.image = image; picture.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if overlay !== overlayImage { overlayImage = overlay; over.contents = overlay?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        picture.magnificationFilter = pixels ? .nearest : .linear
        CATransaction.commit()
        // an update that moves nothing (a redraw, an empty scroll event) must not cut a running spring short
        let changed = size != self.size || offset != self.offset
        self.size = size; self.offset = offset
        if changed || animated { place(animated: animated) }
    }

    private var laidOut = CGRect.null
    override func layout() { super.layout(); if bounds != laidOut { laidOut = bounds; place(animated: false) } }

    /// Back to fit: a softer spring than zooming in, with a little more bounce, settled after this long.
    static let unzoomDuration = 0.55

    /// 0 → 1 progress of a spring (SwiftUI / CASpringAnimation response + bounce), sampled at 120 Hz.
    private static func springCurve(response r: Double, bounce b: Double, duration d: Double) -> [Double] {
        let z = 1 - b, w = 2 * Double.pi / r, wd = w * (1 - z * z).squareRoot(), n = max(Int(d * 120), 2)
        var p = (0...n).map { i -> Double in
            let t = d * Double(i) / Double(n)
            return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
        }
        p[n] = 1
        return p
    }

    private func place(animated: Bool) {
        // where it is on screen right now, so an animation that interrupts another starts from there
        let fromPos = picture.presentation()?.position ?? picture.position
        let fromSize = picture.presentation()?.bounds.size ?? picture.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = CGPoint(x: bounds.midX + offset.width, y: bounds.midY + offset.height)
        picture.frame = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        over.frame = picture.bounds
        CATransaction.commit()
        guard animated, fromSize.width > 0, abs(size.width - fromSize.width) > 0.5 else {
            for l in [picture, over] { l.removeAnimation(forKey: "zoom.position"); l.removeAnimation(forKey: "zoom.size") }
            return
        }
        // A spring, but in log-size space: zoom is perceived as ratios, so 400 % → fit shrinks by the same factor
        // every frame instead of collapsing in the last few (which felt rushed). In: Model.zoomAnimation's spring
        // (response 0.3, damping 0.9); back to fit a softer one. The position follows the size, keeping the anchor.
        let k = size.width / fromSize.width, shrinking = k < 1
        let d = shrinking ? Self.unzoomDuration : 0.35
        let p = Self.springCurve(response: shrinking ? 0.45 : 0.3, bounce: shrinking ? 0.15 : 0.1, duration: d)
        let f = p.map { pow(k, $0) }                         // size factor from the start size
        let u = f.map { ($0 - 1) / (k - 1) }                 // 0 → 1 (with the overshoot), proportional to the size
        let toPos = picture.position
        func key(_ l: CALayer, _ path: String, _ values: [NSValue], _ name: String) {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values; a.calculationMode = .linear; a.duration = d
            l.add(a, forKey: "zoom." + name)
        }
        let sizes = f.map { NSValue(size: CGSize(width: fromSize.width * $0, height: fromSize.height * $0)) }
        key(picture, "bounds.size", sizes, "size")
        key(picture, "position", u.map { NSValue(point: CGPoint(x: fromPos.x + (toPos.x - fromPos.x) * $0,
                                                                y: fromPos.y + (toPos.y - fromPos.y) * $0)) }, "position")
        key(over, "bounds.size", sizes, "size")
        key(over, "position", f.map { NSValue(point: CGPoint(x: fromSize.width * $0 / 2, y: fromSize.height * $0 / 2)) }, "position")
    }
}

struct Observing<O: ObservableObject, Content: View>: View {
    @ObservedObject var object: O
    let content: (O) -> Content
    init(_ object: O, @ViewBuilder content: @escaping (O) -> Content) { self.object = object; self.content = content }
    var body: some View { content(object) }
}

/// Gets its thumbnail and hover state from the parent and is compared by value (`.equatable()`), so a batch of
/// arriving thumbnails or a hover change redraws only the cells it concerns.
struct FilmCell: View, Equatable {
    let photo: Photo
    let isCurrent: Bool
    let isSelected: Bool
    let image: NSImage?
    var hovered = false
    let store: ThumbStore                       // only to request the thumbnail and report the hover
    var markBox = false
    var onMark: () -> Void = {}

    static func == (a: Self, b: Self) -> Bool {
        a.photo == b.photo && a.isCurrent == b.isCurrent && a.isSelected == b.isSelected && a.image === b.image
            && a.hovered == b.hovered && a.markBox == b.markBox
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Group {
                    if let t = image {
                        Image(nsImage: t).resizable().scaledToFit()
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 112, height: 80)
                PhotoBadges(photo: photo, isSelected: isSelected).frame(width: 112, height: 80)
                MarkBox(photo: photo, isSelected: isSelected, enabled: markBox, onToggle: onMark, hovered: hovered)
                    .frame(width: 112, height: 80, alignment: .topTrailing)
            }
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2))   // current = border
            Text(photo.name).font(.system(size: 10, design: .monospaced)).lineLimit(1)
        }
        .frame(width: 116)
        .padding(2)
        .background(isSelected ? Color.accentColor.opacity(0.28) : (isCurrent ? Color.primary.opacity(0.10) : .clear))   // selected = background
        .onHover { inside in if markBox { if inside { store.hovered = photo.url } else if store.hovered == photo.url { store.hovered = nil } } }
        .task { store.ensure(photo.url) }
        .onDisappear { store.forget(photo.url) }
    }
}

/// Gets its thumbnail and hover state from the parent and is compared by value (`.equatable()`), so a batch of
/// arriving thumbnails or a hover change redraws only the cells it concerns.
struct GridCell: View, Equatable {
    let photo: Photo
    let isCurrent: Bool
    let isSelected: Bool
    let size: Double
    let image: NSImage?
    var hovered = false
    let store: ThumbStore                       // only to request the thumbnail and report the hover
    var markBox = false
    var onMark: () -> Void = {}

    static func == (a: Self, b: Self) -> Bool {
        a.photo == b.photo && a.isCurrent == b.isCurrent && a.isSelected == b.isSelected && a.size == b.size && a.image === b.image
            && a.hovered == b.hovered && a.markBox == b.markBox
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Group {
                    if let t = image {
                        Image(nsImage: t).resizable().scaledToFit()
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: size, height: size * 0.72)
                PhotoBadges(photo: photo, isSelected: isSelected).frame(width: size, height: size * 0.72)
                MarkBox(photo: photo, isSelected: isSelected, enabled: markBox, onToggle: onMark, hovered: hovered)
                    .frame(width: size, height: size * 0.72, alignment: .topTrailing)
            }
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3))
            Text(photo.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .padding(3)
        .background(isSelected ? Color.accentColor.opacity(0.28) : (isCurrent ? Color.primary.opacity(0.10) : .clear))   // selected = background
        .onHover { inside in if markBox { if inside { store.hovered = photo.url } else if store.hovered == photo.url { store.hovered = nil } } }
        .task { store.ensure(photo.url) }
        .onDisappear { store.forget(photo.url) }
    }
}
